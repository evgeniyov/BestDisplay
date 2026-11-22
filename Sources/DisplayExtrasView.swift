import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DisplayExtrasView: View {
    let manager: DisplayManager
    let display: Display
    @State private var options: HardwareOptions?
    @State private var loadedOptions = false
    @State private var busy = false
    @State private var pending: PendingOption?
    @State private var audio: SystemAudio?
    @State private var volume = 0.0
    @State private var calibration = Calibration()
    @State private var showsCalibration = false

    private struct PendingOption {
        let choice: HardwareOptions.Choice
        let feature: HardwareOptions.Feature
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let color = display.color {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Label("Цветовой профиль", systemImage: "paintpalette").font(.headline)
                    Text(color.title).font(.callout).foregroundStyle(.secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack { colorButtons(showReset: color.customProfile != nil) }
                        VStack(alignment: .leading) { colorButtons(showReset: color.customProfile != nil) }
                    }
                }
            }
            if display.color != nil && !display.isInMirrorSet {
                DisclosureGroup("Цвет рабочего стола и ICC", isExpanded: $showsCalibration) {
                    VStack(alignment: .leading, spacing: 8) {
                        calibrationSlider("Контраст", value: $calibration.contrast, range: 0.75...1.3)
                        calibrationSlider("Гамма", value: $calibration.gamma, range: 0.7...1.5)
                        calibrationSlider("Красный", value: $calibration.red, range: 0.5...1)
                        calibrationSlider("Зелёный", value: $calibration.green, range: 0.5...1)
                        calibrationSlider("Синий", value: $calibration.blue, range: 0.5...1)
                        ViewThatFits(in: .horizontal) {
                            HStack { calibrationButtons }
                            VStack(alignment: .leading) { calibrationButtons }
                        }
                    }
                    .padding(.top, 6)
                }
            }
            Divider()
            DisplayHDRView(manager: manager, display: display)
            if !display.builtIn, display.location != nil {
                Divider()
                hardware
            }
            Divider()
            HDMICECView()
            if let audio {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Label("Системная громкость", systemImage: "speaker.wave.2").font(.headline)
                    Text(audio.name).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Slider(value: $volume, in: 0...1, step: 0.01, label: { Text("Громкость аудиовыхода") })
                            .labelsHidden()
                        Text(volume.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                        Button("Применить") { applyAudio(audio) }
                            .disabled(abs(audio.value - volume) < 0.005)
                    }
                }
            }
            if #available(macOS 14.2, *) {
                Divider()
                softwareAudio
            }
        }
        .onAppear {
            readAudio()
            calibration = manager.calibrations[display.identity] ?? Calibration()
        }
        .onChange(of: display.color) {
            calibration = manager.calibrations[display.identity] ?? Calibration()
        }
        .disabled(!manager.canChangeDisplayConfiguration)
    }

    private var softwareAudio: some View {
        let control = manager.softwareVolume
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Программная громкость", systemImage: "waveform").font(.headline)
                Spacer()
                if control.waiting || control.active {
                    Button("Выключить") { control.stop() }
                } else {
                    Button("Включить") { control.start() }
                }
            }
            if let output = control.outputName {
                Text(output).font(.caption).foregroundStyle(.secondary)
            }
            if control.active {
                HStack {
                    Slider(value: Binding(get: { control.level }, set: { control.setLevel($0) }),
                           in: 0...1, step: 0.01, label: { Text("Программный уровень аудио") }).labelsHidden()
                    Text(control.level.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                }
            }
            if let message = control.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func calibrationSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 76, alignment: .leading)
            Slider(value: value, in: range, step: 0.01, label: { Text(title) }).labelsHidden()
            Text(value.wrappedValue.formatted(.percent.precision(.fractionLength(0))))
                .monospacedDigit().frame(width: 48, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var calibrationButtons: some View {
        Button("Применить") { manager.applyCalibration(calibration, to: display) }
        Button("Снять фильтр") {
            manager.removeCalibration(from: display)
            calibration = Calibration()
        }
        .disabled(manager.calibrations[display.identity] == nil)
        Button("Сохранить ICC…") { saveICC() }
    }

    private func saveICC() {
        let dialog = NSSavePanel()
        dialog.prompt = "Сохранить"
        dialog.allowedContentTypes = [UTType(filenameExtension: "icc")].compactMap { $0 }
        dialog.nameFieldStringValue = "\(display.title) BestDisplay.icc"
        let settings = calibration
        dialog.begin { response in
            guard response == .OK, let url = dialog.url else { return }
            do {
                try settings.writeProfile(for: display, to: url)
                manager.message = "Сохранён профиль «\(url.lastPathComponent)»."
            } catch {
                manager.message = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func colorButtons(showReset: Bool) -> some View {
        Button("Выбрать ICC…") { chooseICC() }.fixedSize(horizontal: true, vertical: false)
        if showReset {
            Button("Заводской профиль") { manager.setColorProfile(DisplayColor(customProfile: nil), for: display.id) }
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var hardware: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Видеовход и питание").font(.headline)
                Spacer()
                Button(loadedOptions ? "Обновить" : "Прочитать DDC") { loadHardware() }.disabled(busy)
            }
            if busy { ProgressView().controlSize(.small) }
            if loadedOptions, (options?.inputs.isEmpty ?? true) && (options?.powerModes.isEmpty ?? true) {
                Text("Монитор не сообщил доступные видеовходы или режимы питания.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let options {
                let choices = options.inputs
                if !choices.isEmpty {
                    Menu(options.currentInput.map { "Вход · \(HardwareOptions.inputLabel($0))" } ?? "Видеовход") {
                        ForEach(choices) { choice in
                            Button(choice.name) { pending = PendingOption(choice: choice, feature: .input) }
                                .disabled(choice.id == options.currentInput)
                        }
                    }
                    .disabled(busy || manager.screens.count < 2)
                }
                if !options.powerModes.isEmpty {
                    Menu("Питание монитора") {
                        ForEach(options.powerModes) { choice in
                            Button(choice.name) { pending = PendingOption(choice: choice, feature: .power) }
                                .disabled(choice.id == options.currentPower)
                        }
                    }
                    .disabled(busy || manager.screens.count < 2)
                }
            }
            if let pending, let options {
                Text("Отправить «\(pending.choice.name)» на \(display.title)? Изображение на мониторе может пропасть.")
                    .font(.caption)
                HStack {
                    Button("Отмена") { self.pending = nil }
                    Button("Подтвердить") { applyHardware(pending, options: options) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func loadHardware() {
        busy = true
        pending = nil
        Task {
            options = await manager.loadHardwareOptions(for: display.id)
            loadedOptions = true
            busy = false
        }
    }

    private func applyHardware(_ option: PendingOption, options: HardwareOptions) {
        self.pending = nil
        busy = true
        Task {
            await manager.setHardwareOption(option.choice.id, feature: option.feature, options: options, for: display.id)
            // The link may have gone away immediately after the command.
            self.options = nil
            loadedOptions = false
            busy = false
        }
    }

    private func chooseICC() {
        let dialog = NSOpenPanel()
        dialog.prompt = "Применить"
        dialog.allowedContentTypes = ["icc", "icm"].compactMap { UTType(filenameExtension: $0) }
        dialog.canChooseDirectories = false
        dialog.begin { response in
            if response == .OK, let url = dialog.url {
                manager.setColorProfile(DisplayColor(customProfile: url), for: display.id)
            }
        }
    }

    private func readAudio() {
        audio = SystemAudio.current()
        volume = audio?.value ?? 0
    }

    private func applyAudio(_ audio: SystemAudio) {
        do {
            try audio.set(volume)
            readAudio()
        } catch {
            manager.message = error.localizedDescription
        }
    }
}
