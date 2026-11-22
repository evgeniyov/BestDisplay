import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DisplayExtrasView<MonitorControls: View, DimmingControls: View>: View {
    let manager: DisplayManager
    let display: Display
    @ViewBuilder let monitor: () -> MonitorControls
    @ViewBuilder let dimming: () -> DimmingControls
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
        VStack(alignment: .leading, spacing: 16) {
            let external = !display.builtIn && !display.isVirtual
            PanelCard(
                title: external ? "Монитор" : "Яркость дисплея",
                detail: external
                    ? "Меняй настройки монитора по DDC. Поддержка зависит от модели и подключения."
                    : "Меняй яркость дисплея средствами macOS."
            ) {
                monitor()
                if !display.builtIn, display.location != nil {
                    Divider()
                    hardware.disabled(!manager.canChangeDisplayConfiguration)
                }
            }
            PanelCard(title: "Затемнение", detail: "Приглушает изображение, пока BestDisplay открыт.") {
                dimming()
            }
            if let color = display.color {
                PanelCard(title: "Цвет и ICC", detail: "Выбери цветовой профиль или настрой цвет рабочего стола.") {
                    Text(color.title).font(.callout).foregroundStyle(.secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { colorButtons(showReset: color.customProfile != nil) }
                        VStack(alignment: .leading, spacing: 8) { colorButtons(showReset: color.customProfile != nil) }
                    }
                    if !display.isInMirrorSet {
                        DisclosureGroup("Настроить цвет вручную", isExpanded: $showsCalibration) {
                            VStack(alignment: .leading, spacing: 8) {
                                calibrationSlider("Контраст", value: $calibration.contrast, range: 0.75...1.3)
                                calibrationSlider("Гамма", value: $calibration.gamma, range: 0.7...1.5)
                                    .help("Меняй яркость полутонов. Нажми «Применить цвет», чтобы увидеть результат.")
                                calibrationSlider("Красный", value: $calibration.red, range: 0.5...1)
                                calibrationSlider("Зелёный", value: $calibration.green, range: 0.5...1)
                                calibrationSlider("Синий", value: $calibration.blue, range: 0.5...1)
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 8) { calibrationButtons }
                                    VStack(alignment: .leading, spacing: 8) { calibrationButtons }
                                }
                            }
                            .padding(.top, 8)
                        }
                        .help("Измени контраст, яркость полутонов и баланс красного, зелёного и синего.")
                    }
                }
                .disabled(!manager.canChangeDisplayConfiguration)
            }
            PanelCard(title: "HDR", detail: "Проверь, насколько яркие детали может показать дисплей.") {
                DisplayHDRView(manager: manager, display: display)
            }
            .disabled(!manager.canChangeDisplayConfiguration)
            PanelCard(title: "Звук", detail: "Меняй громкость выбранного в macOS аудиовыхода.") {
                if let audio {
                    Text(audio.name).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Slider(value: $volume, in: 0...1, step: 0.01, label: { Text("Громкость аудиовыхода") })
                            .labelsHidden()
                            .help("Выбери громкость и нажми «Применить громкость».")
                        Text(volume.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                        Button("Применить громкость") { applyAudio(audio) }
                            .disabled(abs(audio.value - volume) < 0.005)
                    }
                }
                if #available(macOS 14.2, *) {
                    if audio != nil { Divider() }
                    softwareAudio
                }
                Divider()
                HDMICECView()
            }
            .disabled(!manager.canChangeDisplayConfiguration)
        }
        .onAppear {
            readAudio()
            calibration = manager.calibrations[display.identity] ?? Calibration()
        }
        .onChange(of: display.color) {
            calibration = manager.calibrations[display.identity] ?? Calibration()
        }
    }

    private var softwareAudio: some View {
        let control = manager.softwareVolume
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Программная громкость", systemImage: "waveform").font(.callout.weight(.semibold))
                Spacer()
                if control.waiting || control.active {
                    Button("Выключить") { control.stop() }
                        .help("Верни обычное управление громкостью.")
                } else {
                    Button("Включить") { control.start() }
                        .help("Используй эту регулировку, если macOS не даёт менять громкость аудиовыхода.")
                }
            }
            if let output = control.outputName {
                Text(output).font(.caption).foregroundStyle(.secondary)
            }
            if control.active {
                HStack {
                    Slider(value: Binding(get: { control.level }, set: { control.setLevel($0) }),
                           in: 0...1, step: 0.01, label: { Text("Программная громкость") }).labelsHidden()
                        .help("Меняй громкость звука, который воспроизводит macOS.")
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
        Button("Применить цвет") { manager.applyCalibration(calibration, to: display) }
            .help("Примени выбранные настройки цвета к рабочему столу.")
        Button("Вернуть цвет") {
            manager.removeCalibration(from: display)
            calibration = Calibration()
        }
        .help("Убери ручные настройки цвета рабочего стола.")
        .disabled(manager.calibrations[display.identity] == nil)
        Button("Сохранить ICC…") { saveICC() }
            .help("Запиши текущие настройки цвета в файл ICC.")
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
                manager.message = "Профиль «\(url.lastPathComponent)» сохранён."
            } catch {
                manager.message = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func colorButtons(showReset: Bool) -> some View {
        Button("Выбрать ICC…") { chooseICC() }
            .help("Открой файл .icc или .icm с цветовым профилем для этого дисплея.")
            .fixedSize(horizontal: true, vertical: false)
        if showReset {
            Button("Вернуть заводской профиль") { manager.setColorProfile(DisplayColor(customProfile: nil), for: display.id) }
                .help("Убери выбранный файл ICC и верни профиль дисплея по умолчанию.")
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var hardware: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Видеовход и питание").font(.callout.weight(.semibold))
                Spacer()
                Button("Прочитать входы и питание") { loadHardware() }
                    .help("Запроси через DDC список видеовходов и режимов питания монитора.")
                    .disabled(busy)
            }
            if busy { ProgressView().controlSize(.small).accessibilityLabel("Обмен данными с монитором") }
            if loadedOptions, (options?.inputs.isEmpty ?? true) && (options?.powerModes.isEmpty ?? true) {
                Text("Монитор не сообщил доступные видеовходы или режимы питания.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let options {
                let choices = options.inputs
                if !choices.isEmpty {
                    Menu(options.currentInput.map { "Вход: \(HardwareOptions.inputLabel($0))" } ?? "Видеовход") {
                        ForEach(choices) { choice in
                            Button(choice.name) { pending = PendingOption(choice: choice, feature: .input) }
                                .disabled(choice.id == options.currentInput)
                        }
                    }
                    .help("Выбери другой видеовход монитора. Для этого нужен второй активный дисплей.")
                    .disabled(busy || manager.screens.count < 2)
                }
                if !options.powerModes.isEmpty {
                    Menu("Питание монитора") {
                        ForEach(options.powerModes) { choice in
                            Button(choice.name) { pending = PendingOption(choice: choice, feature: .power) }
                                .disabled(choice.id == options.currentPower)
                        }
                    }
                    .help("Измени режим питания монитора. Для этого нужен второй активный дисплей.")
                    .disabled(busy || manager.screens.count < 2)
                }
            }
            if let pending, let options {
                Text("Отправить команду «\(pending.choice.name)» монитору \(display.title)? Изображение может пропасть.")
                    .font(.caption).foregroundStyle(.secondary)
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
