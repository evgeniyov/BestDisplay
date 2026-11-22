import CoreAudio
import AudioToolbox
import Foundation

struct SystemAudio: Equatable {
    let id: AudioDeviceID
    let name: String
    let value: Double
    private let selector: AudioObjectPropertySelector

    static func defaultOutput() -> AudioDeviceID? {
        var output = AudioDeviceID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &output) == noErr,
              output != kAudioObjectUnknown else { return nil }
        return output
    }

    static func name(of id: AudioDeviceID) -> String {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name {
            return name.takeRetainedValue() as String
        }
        return "Текущий аудиовыход"
    }

    static func current() -> SystemAudio? {
        guard let output = defaultOutput() else { return nil }
        let name = name(of: output)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        for candidate in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar] {
            address.mSelector = candidate
            var writable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(output, &address, &writable) == noErr, writable.boolValue else { continue }
            var level: Float32 = 0
            var levelSize = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(output, &address, 0, nil, &levelSize, &level) == noErr, (0...1).contains(level) {
                return SystemAudio(id: output, name: name, value: Double(level), selector: candidate)
            }
        }
        return nil
    }

    func set(_ level: Double) throws {
        guard level.isFinite, let current = Self.current(), current.id == id, current.selector == selector else {
            throw DisplayFailure("Аудиовыход изменился. Обнови список настроек.")
        }
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                                mElement: kAudioObjectPropertyElementMain)
        var volume = Float32(min(1, max(0, level)))
        guard AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume) == noErr else {
            throw DisplayFailure("macOS отклонила изменение громкости.")
        }
    }
}
