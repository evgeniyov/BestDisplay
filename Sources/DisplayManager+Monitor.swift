import CoreGraphics
import Foundation

// DDC/CI, hardware brightness and brightness-group logic.
extension DisplayManager {
    func clearMonitor() {
        monitorScanNumber += 1
        monitorValues = [:]
        isReadingMonitor = false
    }

    func scanMonitor() {
        guard let display = selected, !isReadingMonitor, !isWritingMonitor else { return }
        let target = MonitorTarget(id: display.id, identity: display.identity, location: display.location)
        monitorScanNumber += 1
        let request = monitorScanNumber
        isReadingMonitor = true
        Task {
            let values = await monitorControls.scan(target)
            guard monitorScanNumber == request else { return }
            isReadingMonitor = false
            monitorValues = values
        }
    }

    func setMonitor(_ control: MonitorControl, value: Double) {
        guard let display = selected, let current = monitorValues[control], !isWritingMonitor else { return }
        let target = MonitorTarget(id: display.id, identity: display.identity, location: display.location)
        let request = monitorScanNumber
        isWritingMonitor = true
        Task {
            defer { isWritingMonitor = false }
            do {
                let updated = try await monitorControls.set(value, for: control, current: current, target: target)
                if monitorScanNumber == request { monitorValues[control] = updated }
                if control == .brightness, brightnessGroup.contains(display.identity) {
                    let peers = screens.filter { $0.id != display.id && brightnessGroup.contains($0.identity) }
                    if !peers.isEmpty { await applyBrightness(updated.value, to: peers) }
                }
            } catch {
                if monitorScanNumber == request { message = error.localizedDescription }
            }
        }
    }

    func loadHardwareOptions(for id: CGDirectDisplayID) async -> HardwareOptions? {
        guard let display = screens.first(where: { $0.id == id }) else { return nil }
        let target = MonitorTarget(id: id, identity: display.identity, location: display.location)
        return await monitorControls.hardwareOptions(for: target)
    }

    func setHardwareOption(
        _ value: UInt16, feature: HardwareOptions.Feature, options: HardwareOptions, for id: CGDirectDisplayID
    ) async {
        guard canChangeDisplayConfiguration else { return }
        guard screens.count > 1, let display = screens.first(where: { $0.id == id }) else {
            message = "Для этой команды нужен второй активный дисплей."
            return
        }
        let target = MonitorTarget(id: id, identity: display.identity, location: display.location)
        do {
            try await changeDisplaySettings {
                try await monitorControls.setHardwareOption(value, for: feature, options: options, target: target)
                message = "Команда отправлена на \(display.title)."
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func setBrightnessGroupMember(_ display: Display, enabled: Bool) {
        guard !display.isVirtual, !display.identity.hasPrefix("session-") else { return }
        if enabled { brightnessGroup.insert(display.identity) }
        else { brightnessGroup.remove(display.identity) }
        storage.set(brightnessGroup.sorted(), forKey: brightnessGroupKey)
    }

    func syncBrightness(from id: CGDirectDisplayID) async {
        guard let source = screens.first(where: { $0.id == id }), !isWritingMonitor else { return }
        let sourceTarget = MonitorTarget(id: id, identity: source.identity, location: source.location)
        let targets = screens.filter { $0.id != id && !$0.isVirtual }
        isWritingMonitor = true
        defer { isWritingMonitor = false }
        guard let brightness = await monitorControls.brightness(of: sourceTarget) else {
            message = "Не удалось прочитать аппаратную яркость \(source.title)."
            return
        }
        await applyBrightness(brightness.value, to: targets)
    }

    private func applyBrightness(_ brightness: Double, to displays: [Display]) async {
        var applied = 0
        var failed = 0
        for display in displays {
            let target = MonitorTarget(id: display.id, identity: display.identity, location: display.location)
            guard let current = await monitorControls.brightness(of: target) else {
                failed += 1
                continue
            }
            do {
                if abs(current.value - brightness) >= 0.005 {
                    let updated = try await monitorControls.set(brightness, for: .brightness, current: current, target: target)
                    if selected?.identity == display.identity { monitorValues[.brightness] = updated }
                }
                applied += 1
            } catch {
                failed += 1
            }
        }
        if applied > 0 {
            let result = "Яркость передана на дисплеи: \(applied)."
            message = failed == 0 ? result : "\(result) Не подтвердили изменение: \(failed)."
        } else {
            message = "Других дисплеев с доступной регулировкой яркости не найдено."
        }
    }
}
