import AppKit
import SwiftUI

struct DisplayHDRView: View {
    let manager: DisplayManager
    let display: Display
    @State private var presets: DisplayReferencePresets?
    @State private var busy = false

    var body: some View {
        let enabled = manager.hdrModes[display.id]
        VStack(alignment: .leading, spacing: 8) {
            if let info = EDRInfo(display), info.potential > 1.001 {
                Text("Предел яркости HDR относительно белого: \(Double(info.potential).formatted(.number.precision(.fractionLength(2))))×")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Показать тест HDR") {
                    do { try manager.edrPreview.show(for: display) }
                    catch { manager.message = error.localizedDescription }
                }
                .help("Открой тестовые участки разной яркости на выбранном дисплее.")
            } else if enabled == nil {
                Text("По данным macOS, доступен только стандартный диапазон яркости (SDR).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let enabled {
                Toggle("Использовать HDR", isOn: Binding(get: { enabled }, set: { setHDR($0) }))
                    .help("Включи HDR для видео и приложений, которые его поддерживают.")
                    .disabled(busy || manager.isWritingMonitor || !manager.canChangeDisplayConfiguration)
                if manager.hasDDCBrightness {
                    Button("Настроить HDR…") { Task { await manager.tuneHDR(on: display) } }
                        .help("Подбери яркость монитора по пяти тестовым участкам.")
                        .disabled(busy || manager.isReadingMonitor || manager.isWritingMonitor || !manager.canChangeDisplayConfiguration)
                }
            }
            if let presets, let active = presets.options.first(where: { $0.id == presets.active }) {
                LabeledContent("Профиль XDR") {
                    Menu(active.name) {
                        ForEach(presets.options) { preset in
                            Button(preset.title) { setPreset(preset.id) }.disabled(preset.id == presets.active)
                        }
                    }
                    .accessibilityLabel("Профиль XDR, \(active.name)")
                    .help("Выбери набор настроек цвета и яркости дисплея.")
                    .disabled(busy || !manager.canChangeDisplayConfiguration)
                }
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: display.current.key, refresh)
        .onChange(of: manager.canChangeDisplayConfiguration, refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            if !busy { refresh() }
        }
    }

    private func refresh() {
        presets = DisplayReferencePresets.read(display)
    }

    private func setPreset(_ index: UInt32) {
        apply {
            try await manager.changeDisplaySettings {
                try await DisplayReferencePresets.set(index, on: display)
                manager.message = "Профиль XDR применён."
            }
        }
    }

    private func setHDR(_ value: Bool) {
        apply {
            try await manager.setHDR(value, on: display)
        }
    }

    private func apply(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task {
            defer {
                refresh()
                busy = false
            }
            do {
                try await operation()
            } catch {
                manager.message = error.localizedDescription
            }
        }
    }
}
