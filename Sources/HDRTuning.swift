import AppKit
import SwiftUI

@MainActor
@Observable
final class HDRTuning {
    enum Step {
        case preparing, shadows, done
    }

    let display: Display
    var disconnected = false
    private(set) var step = Step.preparing
    var requestedBrightness = 0.0
    private(set) var confirmedBrightness = 0.0
    private(set) var headroom: CGFloat = 1
    private var keepChanges: Bool?

    init(display: Display) {
        self.display = display
    }

    func advance() {
        if step == .shadows { step = .done }
    }

    @discardableResult
    func run(in preview: EDRPreview, controls: MonitorControls) async throws -> Bool {
        let target = MonitorTarget(id: display.id, identity: display.identity, location: display.location)
        guard let edr = EDRInfo(display), let wasEnabled = DisplayHDRMode.status(for: display) else {
            throw DisplayFailure("Дисплей недоступен для настройки HDR.")
        }

        let footer = NSHostingView(rootView: HDRTuningFooter(tuning: self) { keep in
            self.keepChanges = keep
            preview.close()
        })
        try preview.showTuning(on: edr.screen, footer: footer) { [weak self] in
            if self?.keepChanges == nil { self?.keepChanges = false }
        }

        var originalBrightness: ControlValue?
        var attemptedWrite = false
        var failure: Error?
        do {
            if !wasEnabled { try await DisplayHDRMode.set(true, on: display) }
            originalBrightness = try await readBrightness(from: controls, target: target, preview: preview)
            if var current = originalBrightness, keepChanges == nil {
                requestedBrightness = current.value
                confirmedBrightness = current.value
                step = .shadows
                while keepChanges == nil {
                    try checkHDR(on: target)
                    updatePattern(in: preview)
                    let requested = requestedBrightness
                    if requested != current.value {
                        attemptedWrite = true
                        current = try await controls.set(requested, for: .brightness, current: current,
                                                         target: target, requiresHDR: true)
                        confirmedBrightness = current.value
                        if requestedBrightness == requested { requestedBrightness = current.value }
                    }
                    try await Task.sleep(for: .milliseconds(120))
                }
            }
            try checkConnection(to: target)
        } catch {
            failure = error
        }

        preview.close()
        if keepChanges != true || failure != nil, !disconnected, target.stillOnline {
            do {
                try await restore(wasEnabled: wasEnabled, brightness: attemptedWrite ? originalBrightness : nil,
                                  controls: controls, target: target)
            } catch {
                if let failure { throw DisplayFailure("\(failure.localizedDescription) \(error.localizedDescription)") }
                throw error
            }
        }
        try checkConnection(to: target)
        if let failure { throw failure }
        return keepChanges == true
    }

    private func checkConnection(to target: MonitorTarget) throws {
        guard !disconnected, target.stillOnline else {
            throw DisplayFailure("Дисплей отключился во время настройки HDR.")
        }
    }

    private func checkHDR(on target: MonitorTarget) throws {
        try checkConnection(to: target)
        guard DisplayHDRMode.status(for: display) == true else {
            throw DisplayFailure("Режим HDR выключился во время настройки.")
        }
    }

    private func readBrightness(from controls: MonitorControls, target: MonitorTarget,
                                preview: EDRPreview) async throws -> ControlValue? {
        // Allow the display and brightness backend to settle after switching HDR.
        for attempt in 0..<24 {
            if keepChanges != nil { return nil }
            try checkHDR(on: target)
            updatePattern(in: preview)
            if attempt >= 15, let brightness = await controls.brightness(of: target) {
                try checkHDR(on: target)
                return brightness
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw DisplayFailure("Не удалось прочитать яркость монитора в режиме HDR.")
    }

    private func restore(wasEnabled: Bool, brightness: ControlValue?, controls: MonitorControls,
                         target: MonitorTarget) async throws {
        var brightnessFailure: Error?
        if let brightness {
            do {
                if DisplayHDRMode.status(for: display) != true {
                    try await DisplayHDRMode.set(true, on: display)
                    try await Task.sleep(for: .seconds(3))
                }
                try checkHDR(on: target)
                try await controls.restoreHDRBrightness(brightness, target: target)
            } catch {
                brightnessFailure = error
            }
        }
        try checkConnection(to: target)
        if DisplayHDRMode.status(for: display) != wasEnabled {
            try await DisplayHDRMode.set(wasEnabled, on: display)
            if !wasEnabled { try await Task.sleep(for: .seconds(3)) }
        }
        if let brightnessFailure { throw brightnessFailure }
    }

    private func updatePattern(in preview: EDRPreview) {
        guard let edr = EDRInfo(display) else { return }
        preview.fitTuning(to: edr.screen)
        if abs(edr.current - headroom) >= 0.01 { headroom = edr.current }
        preview.patches?.update(levels: step == .done ? [] : HDRTuningPattern.shadows, background: 0, fillsHeight: false)
    }
}

private struct HDRTuningFooter: View {
    @Bindable var tuning: HDRTuning
    let close: (Bool) -> Void

    var body: some View {
        VStack(spacing: 12) {
            switch tuning.step {
            case .preparing:
                ProgressView("Подготовка HDR…")
            case .shadows:
                patternStep("Тени", "Двигай ползунок, пока не увидишь 4 из 5 квадратов. Самый тёмный должен слиться с фоном.")
            case .done:
                Text("Яркость настроена").font(.title2)
                Text("Яркость монитора в HDR: \(percent(tuning.confirmedBrightness)).")
            }
            if tuning.step != .preparing {
                Text(headroomNote).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack {
                Button("Вернуть яркость") { close(false) }
                if tuning.step == .done {
                    Button("Оставить яркость") { close(true) }.buttonStyle(.borderedProminent)
                } else if tuning.step != .preparing {
                    Button("Далее") { tuning.advance() }.buttonStyle(.borderedProminent)
                        .disabled(tuning.requestedBrightness != tuning.confirmedBrightness)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(.black)
    }

    private func patternStep(_ title: String, _ instruction: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.title2).accessibilityAddTraits(.isHeader)
            Text(instruction).multilineTextAlignment(.center)
            HStack {
                Slider(value: $tuning.requestedBrightness, in: 0...1, step: 0.01) { Text("Яркость HDR") }
                    .help("Настрой яркость так, чтобы были видны 4 из 5 квадратов.")
                Text(percent(tuning.requestedBrightness)).monospacedDigit().frame(width: 48, alignment: .trailing)
            }
            .frame(maxWidth: 440)
        }
    }

    private var headroomNote: String {
        let value = Double(tuning.headroom).formatted(.number.precision(.fractionLength(2)))
        return "Яркие детали в HDR-видео могут быть примерно в \(value) раза ярче обычного белого."
    }

    private func percent(_ brightness: Double) -> String {
        brightness.formatted(.percent.precision(.fractionLength(0)))
    }
}
