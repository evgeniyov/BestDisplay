import CoreAudio
import Foundation
import Observation

private protocol VolumeTap: AnyObject {
    var output: AudioDeviceID { get }
    var hasSignal: Bool { get }
    var hasFormatError: Bool { get }
    func engage() -> OSStatus
    func setGain(_ gain: Float)
    func stop()
}

@available(macOS 14.2, *)
extension BDSoftwareVolume: VolumeTap {}

@MainActor
@Observable
final class SoftwareVolume {
    private(set) var active = false
    private(set) var waiting = false
    private(set) var level = 1.0
    private(set) var outputName: String?
    private(set) var message: String?
    @ObservationIgnored private var tap: (any VolumeTap)?
    @ObservationIgnored private var monitor: Task<Void, Never>?

    func start() {
        guard #available(macOS 14.2, *), tap == nil, let output = SystemAudio.defaultOutput() else { return }
        var status: OSStatus = 0
        guard let backend = BDSoftwareVolume(output: output, status: &status) else {
            message = status == kAudioHardwareUnsupportedOperationError
                ? "Выбери аудиовыход с одним стереопотоком. Входных каналов быть не должно."
                : "Не удалось запустить Core Audio. Код ошибки \(status)."
            return
        }
        tap = backend
        level = 1
        outputName = SystemAudio.name(of: output)
        waiting = true
        message = "Разреши запись системного звука по запросу macOS. Затем воспроизведи звук."
        let deadline = ProcessInfo.processInfo.systemUptime + 35
        monitor = Task { [weak self, weak backend] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, let backend else { return }
                if SystemAudio.defaultOutput() != backend.output || backend.hasFormatError {
                    self.stop("Изменился аудиовыход или формат звука. Программная громкость выключена.")
                    return
                }
                if self.waiting, backend.hasSignal {
                    let result = backend.engage()
                    guard result == 0 else {
                        self.stop("macOS не разрешила обработку звука. Код ошибки \(result).")
                        return
                    }
                    self.waiting = false
                    self.active = true
                    self.message = nil
                } else if self.waiting, ProcessInfo.processInfo.systemUptime >= deadline {
                    self.stop("BestDisplay не получил тестовый звук. Проверь разрешение на запись системного звука и повтори попытку.")
                    return
                }
            }
        }
    }

    func setLevel(_ value: Double) {
        guard active, value.isFinite else { return }
        level = min(1, max(0, value))
        tap?.setGain(Float(level))
    }

    func stop(_ reason: String? = nil) {
        monitor?.cancel()
        monitor = nil
        tap?.stop()
        tap = nil
        active = false
        waiting = false
        level = 1
        outputName = nil
        message = reason
    }
}
