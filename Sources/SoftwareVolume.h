#import <CoreAudio/CoreAudio.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

API_AVAILABLE(macos(14.2))
@interface BDSoftwareVolume : NSObject
@property (nonatomic, readonly) AudioDeviceID output;
@property (nonatomic, readonly) BOOL hasSignal;
@property (nonatomic, readonly) BOOL hasFormatError;
@property (nonatomic, readonly) float observedInputPeak;
@property (nonatomic, readonly) float observedOutputPeak;

- (instancetype)init NS_UNAVAILABLE;
- (nullable instancetype)initWithOutput:(AudioDeviceID)output status:(OSStatus *)status;
- (OSStatus)engage;
- (void)setGain:(float)gain;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
