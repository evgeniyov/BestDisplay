#import "SoftwareVolume.h"
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <AudioToolbox/AudioToolbox.h>
#import <math.h>
#import <stdatomic.h>
#import <unistd.h>

typedef struct {
    _Atomic float gain;
    _Atomic float inputPeak;
    _Atomic float outputPeak;
    _Atomic bool engaged;
    _Atomic bool badFormat;
} BDVolumeState;

static AudioObjectPropertyAddress GlobalProperty(AudioObjectPropertySelector selector) {
    return (AudioObjectPropertyAddress){selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
}

static OSStatus OwnAudioProcess(AudioObjectID *process) {
    pid_t pid = getpid();
    AudioObjectPropertyAddress property = GlobalProperty(kAudioHardwarePropertyTranslatePIDToProcessObject);
    UInt32 size = sizeof(*process);
    *process = kAudioObjectUnknown;
    return AudioObjectGetPropertyData(kAudioObjectSystemObject, &property, sizeof(pid), &pid, &size, process);
}

static BOOL IsStereoFloat(AudioStreamBasicDescription format) {
    return format.mFormatID == kAudioFormatLinearPCM &&
        (format.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsBigEndian)) == kAudioFormatFlagIsFloat &&
        format.mBitsPerChannel == 32 && format.mChannelsPerFrame == 2 &&
        format.mBytesPerFrame == ((format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 4 : 8);
}

static BOOL ReadStereoOutput(AudioDeviceID device, AudioStreamBasicDescription *format) {
    AudioObjectPropertyAddress streams = {
        kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain
    };
    AudioStreamID stream = kAudioObjectUnknown;
    UInt32 size = sizeof(stream);
    if (AudioObjectGetPropertyData(device, &streams, 0, NULL, &size, &stream) != noErr ||
        size != sizeof(stream) || stream == kAudioObjectUnknown) return NO;
    AudioObjectPropertyAddress property = GlobalProperty(kAudioStreamPropertyVirtualFormat);
    size = sizeof(*format);
    return AudioObjectGetPropertyData(stream, &property, 0, NULL, &size, format) == noErr && IsStereoFloat(*format);
}

static BOOL HasInputStream(AudioDeviceID device) {
    AudioObjectPropertyAddress streams = {
        kAudioDevicePropertyStreams, kAudioDevicePropertyScopeInput, kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    return AudioObjectGetPropertyDataSize(device, &streams, 0, NULL, &size) != noErr || size != 0;
}

static UInt32 StereoFrameCount(const AudioBufferList *list) {
    if (!list || list->mNumberBuffers == 0 || list->mNumberBuffers > 2) return 0;
    UInt32 channels = list->mNumberBuffers == 1 ? 2 : 1;
    UInt32 stride = channels * sizeof(float);
    UInt32 bytes = list->mBuffers[0].mDataByteSize;
    if (bytes == 0 || bytes % stride != 0) return 0;
    for (UInt32 i = 0; i < list->mNumberBuffers; i++) {
        AudioBuffer buffer = list->mBuffers[i];
        if (!buffer.mData || buffer.mNumberChannels != channels || buffer.mDataByteSize != bytes) return 0;
    }
    return bytes / stride;
}

static const float *Samples(const AudioBufferList *list, UInt32 channel) {
    if (list->mNumberBuffers == 2) return list->mBuffers[channel].mData;
    return (const float *)list->mBuffers[0].mData + channel;
}

static OSStatus ProcessVolume(AudioDeviceID device, const AudioTimeStamp *now, const AudioBufferList *input,
                              const AudioTimeStamp *inputTime, AudioBufferList *output,
                              const AudioTimeStamp *outputTime, void *context) {
    BDVolumeState *state = context;
    if (!output) return noErr;
    for (UInt32 i = 0; i < output->mNumberBuffers; i++) {
        AudioBuffer buffer = output->mBuffers[i];
        if (buffer.mData) memset(buffer.mData, 0, buffer.mDataByteSize);
    }

    UInt32 frames = StereoFrameCount(input);
    if (!frames || frames != StereoFrameCount(output)) {
        if (atomic_load_explicit(&state->engaged, memory_order_relaxed))
            atomic_store_explicit(&state->badFormat, true, memory_order_relaxed);
        return noErr;
    }
    bool engaged = atomic_load_explicit(&state->engaged, memory_order_relaxed);
    float gain = atomic_load_explicit(&state->gain, memory_order_relaxed);
    UInt32 inStride = input->mNumberBuffers == 1 ? 2 : 1;
    UInt32 outStride = output->mNumberBuffers == 1 ? 2 : 1;
    float inputPeak = 0;
    float outputPeak = 0;
    for (UInt32 c = 0; c < 2; c++) {
        const float *source = Samples(input, c);
        float *target = output->mNumberBuffers == 2 ? output->mBuffers[c].mData
                                                  : (float *)output->mBuffers[0].mData + c;
        for (UInt32 frame = 0; frame < frames; frame++) {
            float sample = source[frame * inStride];
            inputPeak = fmaxf(inputPeak, fabsf(sample));
            if (engaged) {
                float scaled = sample * gain;
                target[frame * outStride] = scaled;
                outputPeak = fmaxf(outputPeak, fabsf(scaled));
            }
        }
    }
    if (inputPeak > 0.0001f) {
        atomic_store_explicit(&state->inputPeak, inputPeak, memory_order_relaxed);
        atomic_store_explicit(&state->outputPeak, outputPeak, memory_order_relaxed);
    }
    return noErr;
}

@implementation BDSoftwareVolume {
    AudioObjectID _tap;
    AudioDeviceID _aggregate;
    AudioDeviceIOProcID _io;
    CATapDescription *_description;
    BDVolumeState _state;
}

- (nullable instancetype)initWithOutput:(AudioDeviceID)output status:(OSStatus *)status {
    self = [super init];
    if (!self) return nil;
    *status = kAudioHardwareUnsupportedOperationError;
    AudioStreamBasicDescription hardware = {};
    if (!ReadStereoOutput(output, &hardware) || HasInputStream(output)) return nil;
    _output = output;
    atomic_init(&_state.gain, 1);
    atomic_init(&_state.inputPeak, 0);
    atomic_init(&_state.outputPeak, 0);
    atomic_init(&_state.engaged, false);
    atomic_init(&_state.badFormat, false);

    AudioObjectPropertyAddress property = GlobalProperty(kAudioDevicePropertyDeviceUID);
    CFStringRef uid = NULL;
    UInt32 size = sizeof(uid);
    *status = AudioObjectGetPropertyData(output, &property, 0, NULL, &size, &uid);
    if (*status != noErr || !uid) return nil;
    NSString *deviceUID = CFBridgingRelease(uid);
    AudioObjectID ownAudio;
    *status = OwnAudioProcess(&ownAudio);
    if (*status != noErr) return nil;

    NSArray<NSNumber *> *excluded = ownAudio == kAudioObjectUnknown ? @[] : @[@(ownAudio)];
    _description = [[CATapDescription alloc] initExcludingProcesses:excluded andDeviceUID:deviceUID withStream:0];
    _description.name = @"BestDisplay";
    _description.private = YES;
    _description.muteBehavior = CATapUnmuted;
    *status = AudioHardwareCreateProcessTap(_description, &_tap);
    if (*status != noErr) return nil;

    AudioStreamBasicDescription tapFormat = {};
    property = GlobalProperty(kAudioTapPropertyFormat);
    size = sizeof(tapFormat);
    *status = AudioObjectGetPropertyData(_tap, &property, 0, NULL, &size, &tapFormat);
    if (*status != noErr) return nil;
    if (!IsStereoFloat(tapFormat) || tapFormat.mSampleRate != hardware.mSampleRate) {
        *status = kAudioHardwareUnsupportedOperationError;
        return nil;
    }

    NSDictionary *properties = @{
        @kAudioAggregateDeviceNameKey: @"BestDisplay Output",
        @kAudioAggregateDeviceUIDKey: NSUUID.UUID.UUIDString,
        @kAudioAggregateDeviceIsPrivateKey: @YES,
        @kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
        @kAudioAggregateDeviceSubDeviceListKey: @[@{@kAudioSubDeviceUIDKey: deviceUID}],
        @kAudioAggregateDeviceTapListKey: @[@{@kAudioSubTapUIDKey: _description.UUID.UUIDString,
                                             @kAudioSubTapDriftCompensationKey: @YES}],
        @kAudioAggregateDeviceTapAutoStartKey: @YES
    };
    *status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)properties, &_aggregate);
    if (*status != noErr) return nil;
    *status = AudioDeviceCreateIOProcID(_aggregate, ProcessVolume, &_state, &_io);
    if (*status != noErr) return nil;
    *status = AudioDeviceStart(_aggregate, _io);
    if (*status != noErr) return nil;
    return self;
}

- (BOOL)hasSignal { return self.observedInputPeak > 0.0001f; }
- (BOOL)hasFormatError { return atomic_load_explicit(&_state.badFormat, memory_order_relaxed); }
- (float)observedInputPeak { return atomic_load_explicit(&_state.inputPeak, memory_order_relaxed); }
- (float)observedOutputPeak { return atomic_load_explicit(&_state.outputPeak, memory_order_relaxed); }

- (OSStatus)engage {
    if (!_tap || !self.hasSignal) return kAudioHardwareIllegalOperationError;
    AudioObjectID ownAudio;
    OSStatus status = OwnAudioProcess(&ownAudio);
    if (status != noErr) return status;
    if (ownAudio == kAudioObjectUnknown) return kAudioHardwareIllegalOperationError;
    _description.processes = @[@(ownAudio)];
    _description.muteBehavior = CATapMutedWhenTapped;
    CFTypeRef description = (__bridge CFTypeRef)_description;
    AudioObjectPropertyAddress property = GlobalProperty(kAudioTapPropertyDescription);
    status = AudioObjectSetPropertyData(_tap, &property, 0, NULL, sizeof(description), &description);
    if (status != noErr) return status;
    atomic_store_explicit(&_state.engaged, true, memory_order_relaxed);

    CFTypeRef value = NULL;
    UInt32 size = sizeof(value);
    status = AudioObjectGetPropertyData(_tap, &property, 0, NULL, &size, &value);
    if (status != noErr) return status;
    CATapDescription *confirmed = CFBridgingRelease(value);
    if (!confirmed || confirmed.muteBehavior != CATapMutedWhenTapped ||
        ![confirmed.processes containsObject:@(ownAudio)]) return kAudioHardwareIllegalOperationError;
    return noErr;
}

- (void)setGain:(float)gain {
    if (isfinite(gain)) atomic_store_explicit(&_state.gain, fminf(1, fmaxf(0, gain)), memory_order_relaxed);
}

- (void)stop {
    if (_io) {
        AudioDeviceStop(_aggregate, _io);
        AudioDeviceDestroyIOProcID(_aggregate, _io);
        _io = NULL;
    }
    if (_aggregate != kAudioObjectUnknown) {
        AudioHardwareDestroyAggregateDevice(_aggregate);
        _aggregate = kAudioObjectUnknown;
    }
    if (_tap != kAudioObjectUnknown) {
        AudioHardwareDestroyProcessTap(_tap);
        _tap = kAudioObjectUnknown;
    }
}

- (void)dealloc { [self stop]; }
@end
