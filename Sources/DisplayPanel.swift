import AppKit
import SwiftUI

private enum PanelPage: String, CaseIterable {
    case scale = "Масштаб"
    case controls = "Управление"
    case arrangement = "Расположение"
    case profiles = "Профили"
    case history = "История"

    var usesSelectedDisplay: Bool { self != .profiles && self != .history }
}

struct DisplayPanel: View {
    let manager: DisplayManager
    let dismiss: () -> Void
    let startLivePreview: () -> Void
    @State private var page: PanelPage = .scale
    @State private var allModes = false
    @State private var showHiDPIOnly = false
    @State private var filterText = ""
    @State private var virtualEditor = false
    @State private var virtualWidth = "1600"
    @State private var virtualHeight = "900"
    @State private var virtualHiDPI = true

    var body: some View {
        GeometryReader { viewport in
            content.frame(width: viewport.size.width, height: viewport.size.height)
        }
        .onChange(of: manager.selectedID) {
            allModes = false
            filterText = ""
        }
        .onChange(of: page) {
            allModes = false
            filterText = ""
            manager.message = nil
            if page == .controls { manager.scanMonitor() }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if page.usesSelectedDisplay && manager.selected != nil { displayPicker }
            if let preview = manager.preview {
                previewBanner(preview)
                    .padding(.top, page.usesSelectedDisplay ? 0 : 12)
                Divider()
            }
            navigation
                .padding(.top, page.usesSelectedDisplay && manager.selected != nil && manager.preview == nil ? 0 : 12)
                .padding(.bottom, 12)
            if page == .scale, allModes, let display = manager.selected {
                modes(for: display)
            } else if page.usesSelectedDisplay && manager.selected == nil {
                ContentUnavailableView("Ожидание дисплеев", systemImage: "display",
                                       description: Text("Подключи монитор или открой BestDisplay в графическом сеансе macOS."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        switch page {
                        case .scale: if let display = manager.selected { scale(for: display) }
                        case .controls: if let display = manager.selected { controls(for: display) }
                        case .arrangement: if let display = manager.selected { arrangement(for: display) }
                        case .profiles: DisplayProfilesView(manager: manager)
                        case .history: DisplayHistoryView(manager: manager)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.top)
            }
            Divider()
            footer
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
    }

    private var navigation: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 2) {
                ForEach(PanelPage.allCases, id: \.self) { section in
                    Button {
                        page = section
                    } label: {
                        Text(section.rawValue)
                            .font(.callout)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity)
                            .background(page == section ? Color.primary.opacity(0.16) : .clear,
                                        in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(page == section ? .isSelected : [])
                }
            }
            .padding(3)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Разделы")

            Picker("Раздел", selection: $page) {
                ForEach(PanelPage.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "display")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("BestDisplay")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
            Menu {
                Button("Скопировать диагностику", systemImage: "doc.on.doc") {
                    manager.refresh()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(displayReport(manager.screens), forType: .string)
                    manager.message = "Диагностика скопирована."
                }
                Button("Картинка в картинке…", systemImage: "pip", action: startLivePreview)
                if let disconnected = manager.disconnectedDisplayName {
                    Button("Подключить \(disconnected)", systemImage: "display") {
                        Task { await manager.reconnectDisplay() }
                    }
                    .disabled(!manager.canChangeDisplayConfiguration)
                }
                Toggle("Запускать при входе", isOn: Binding(get: { manager.launchAtLogin }, set: { manager.setLogin($0) }))
                Button("Настройки дисплеев macOS", systemImage: "gear") { openDisplaySettings() }
                Divider()
                Button("Выйти из BestDisplay", systemImage: "power") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17))
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Настройки BestDisplay")
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Закрыть панель")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
    }

    private var displayPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(manager.screens) { screen in
                    let isSelected = screen.id == manager.selectedID
                    Button {
                        manager.select(screen.id)
                        if page == .controls { manager.scanMonitor() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: screen.builtIn ? "laptopcomputer" : "display")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(screen.title)
                                    .font(.callout.weight(.semibold))
                                    .lineLimit(1)
                                Text(screen.isMain ? "Основной" : screen.category)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(isSelected ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.035),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(isSelected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
        .padding(.vertical, 12)
    }

    private func previewBanner(_ preview: DisplayPreview) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "timer").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Откат через \(manager.secondsLeft) с")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                Text(preview.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 5)
            Button("Вернуть") { manager.revertPreview() }
                .keyboardShortcut(.cancelAction)
            Button("Оставить") { manager.keepPreview() }
                .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func scale(for display: Display) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(display.current.key.label, systemImage: "viewfinder")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    metrics(for: display)
                }
                VStack(alignment: .leading, spacing: 8) {
                    metrics(for: display)
                }
            }
            if let panel = display.panel, panel != display.current.key.rendering {
                Text("Рендер и панель имеют разное разрешение. Сравни читаемость текста в разных режимах.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        if !display.recommendations.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("Сравнить масштаб").font(.headline)
                ForEach(display.recommendations, id: \.1.id) { label, mode in
                    modeRow(mode, for: display, label: label)
                }
                Text("Aa · Тонкие линии, цифры и мелкий текст")
                    .font(.caption2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.background, in: RoundedRectangle(cornerRadius: 5))
                    .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.18), lineWidth: 0.5) }
                    .accessibilityLabel("Образец мелкого текста")
            }
        }
        ViewThatFits(in: .horizontal) {
            HStack {
                modeListButton(for: display)
                Spacer(minLength: 8)
                rememberedModeButton(for: display)
            }
            VStack(alignment: .leading, spacing: 8) {
                modeListButton(for: display)
                rememberedModeButton(for: display)
            }
        }
        .buttonStyle(.bordered)
        .disabled(!manager.canChangeDisplayConfiguration)
        if let profile = manager.currentProfile, profile.automaticallyApplies {
            Text("При подключении применяется профиль «\(profile.name)».")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let saved = manager.remembered[display.identity] {
            HStack {
                Text("При подключении · \(saved.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if saved != display.current.key {
                    Button("Забыть") { manager.setRemembered(false, for: display.identity) }
                        .buttonStyle(.link)
                        .disabled(!manager.canChangeDisplayConfiguration)
                }
            }
        }
    }

    private func modeListButton(for display: Display) -> some View {
        Button("Все режимы (\(display.modes.count))", systemImage: "list.bullet") { allModes = true }
            .fixedSize(horizontal: true, vertical: false)
    }

    private func rememberedModeButton(for display: Display) -> some View {
        let saved = manager.remembered[display.identity]
        let isRemembered = saved == display.current.key
        let title = isRemembered ? "Забыть выбранный" : (saved == nil ? "Запомнить режим" : "Обновить сохранённый")
        return Button(title, systemImage: isRemembered ? "pin.slash" : "pin") {
            manager.setRemembered(!isRemembered, for: display.identity)
        }
        .help(isRemembered ? "Перестать восстанавливать режим при подключении"
            : "Восстанавливать этот режим при запуске, подключении и пробуждении")
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func metrics(for display: Display) -> some View {
        if display.panelSizeOptions.isEmpty {
            metric("Панель", display.panel?.label ?? "Нет данных")
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text("Панель").font(.caption).foregroundStyle(.secondary)
                Menu {
                    Picker("Панель", selection: Binding(
                        get: { display.panelOverride },
                        set: { manager.setPanelSize($0, for: display.identity) }
                    )) {
                        ForEach(display.panelSizeOptions, id: \.self) { size in
                            Text(size.label).tag(Optional(size))
                        }
                        Text("Автоматически").tag(nil as Dimensions?)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Text(display.panel?.label ?? "Нет данных")
                        .font(.callout.monospacedDigit().weight(.medium))
                }
                .menuStyle(.borderlessButton)
                .menuOrder(.fixed)
                .controlSize(.small)
                .accessibilityLabel("Панель, \(display.panel?.label ?? "Нет данных")")
                if display.panelIsInferred {
                    Text("по частоте обновления").font(.caption).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        metric("Рендер macOS", display.current.key.rendering.label)
        if let edr = display.edr {
            metric("Динамический диапазон", edr > 1 ? "EDR" : "SDR")
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().weight(.medium))
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func modeRow(_ mode: ScreenMode, for display: Display, label: String? = nil) -> some View {
        let active = mode.key == display.current.key
        return HStack(spacing: 9) {
            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let label { Text(label).font(.callout.weight(.medium)) }
                Text(mode.key.label)
                    .foregroundStyle(label == nil ? .primary : .secondary)
                    .font(label == nil ? .callout : .caption)
                    .monospacedDigit()
            }
            Spacer()
            if active {
                Text("Активен").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Проверить") { manager.tryMode(mode.key, display: display.identity) }
                    .disabled(!manager.canChangeDisplayConfiguration || display.mirrors != 0)
                    .accessibilityLabel("Проверить \(mode.key.label)")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
    }

    private func modes(for display: Display) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Назад", systemImage: "chevron.backward") { allModes = false }
                TextField("Разрешение или частота", text: $filterText)
                    .textFieldStyle(.roundedBorder)
                Toggle("HiDPI", isOn: $showHiDPIOnly)
                    .toggleStyle(.checkbox)
            }
            .padding(.horizontal, 20)
            let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "x", with: "×").replacingOccurrences(of: "х", with: "×")
            let available = display.modes.filter {
                (!showHiDPIOnly || $0.key.isHiDPI) && (query.isEmpty || $0.key.label.localizedCaseInsensitiveContains(query))
            }
            if available.isEmpty {
                ContentUnavailableView("Режимы не найдены", systemImage: "magnifyingglass")
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(available) { mode in
                            modeRow(mode, for: display)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    @ViewBuilder
    private func controls(for display: Display) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Настройки монитора").font(.headline)
                Spacer()
                if manager.isReadingMonitor {
                    ProgressView().controlSize(.small).accessibilityLabel("Чтение настроек")
                }
                Button("Обновить", systemImage: "arrow.clockwise") { manager.scanMonitor() }
                    .disabled(manager.isReadingMonitor || manager.isWritingMonitor)
            }
            if !manager.isReadingMonitor && manager.monitorValues.isEmpty {
                Text("Доступные аппаратные настройки не обнаружены. Проверь DDC/CI в меню монитора и способ подключения.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(MonitorControl.allCases, id: \.self) { control in
                if let current = manager.monitorValues[control] {
                    HardwareSlider(control: control, current: current, isWriting: manager.isWritingMonitor) { value in
                        manager.setMonitor(control, value: value)
                    }
                    .id("\(display.identity)-\(control.rawValue)")
                }
            }
        }
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            Label("Программное затемнение", systemImage: "moon")
                .font(.headline)
            let amount = manager.dimming[display.identity] ?? 0
            HStack {
                Slider(value: Binding(get: { manager.dimming[display.identity] ?? 0 }, set: { manager.dim(display.identity, by: $0) }),
                       in: 0...0.8, label: { Text("Программное затемнение") })
                    .labelsHidden()
                    .disabled(display.mirrors != 0)
                Text(amount.formatted(.percent.precision(.fractionLength(0))))
                    .font(.callout.monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
                Button("Сбросить") { manager.dim(display.identity, by: 0) }
                    .disabled(amount == 0)
            }
            Text("Затемнение действует, пока BestDisplay открыт.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if !display.isVirtual, !display.identity.hasPrefix("session-"),
           manager.screens.count > 1 || manager.brightnessGroup.contains(display.identity) {
            Toggle("В группе яркости", isOn: Binding(
                get: { manager.brightnessGroup.contains(display.identity) },
                set: { manager.setBrightnessGroupMember(display, enabled: $0) }
            ))
            .disabled(manager.isWritingMonitor)
            if manager.brightnessGroup.contains(display.identity) {
                Text("Изменения яркости в BestDisplay передаются другим дисплеям группы.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if manager.screens.count > 1, manager.monitorValues[.brightness] != nil {
            Button("Передать яркость другим дисплеям", systemImage: "sun.max") {
                Task { await manager.syncBrightness(from: display.id) }
            }
            .disabled(manager.isWritingMonitor || manager.preview != nil)
        }
        DisplayExtrasView(manager: manager, display: display).id(display.identity)
    }

    @ViewBuilder
    private func arrangement(for display: Display) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Схема дисплеев").font(.headline)
            layoutMap
            HStack {
                if !display.isMain {
                    Menu("Относительно основного") {
                        ForEach(Placement.allCases, id: \.self) { place in
                            Button(place.rawValue) { manager.placeSelected(place) }
                        }
                    }
                    Button("Сделать основным") { manager.makeSelectedMain() }
                } else {
                    Label("Основной дисплей", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                Spacer()
            }
            .disabled(!manager.canChangeDisplayConfiguration || display.mirrors != 0)
        }
        if !display.builtIn, !display.isVirtual, display.location != nil,
           BDCanRequestDisplayOrientation(), let orientation = DisplayOrientation.current(display.id) {
            Menu("Поворот · \(orientation.title)") {
                ForEach(DisplayOrientation.allCases, id: \.self) { angle in
                    Button(angle.title) { manager.tryOrientation(angle, on: display) }
                        .disabled(angle == orientation)
                }
            }
            .disabled(display.isInMirrorSet || !manager.canChangeDisplayConfiguration)
        }
        if manager.canProtectTopology {
            Toggle("Восстанавливать поворот и видеоповтор", isOn: Binding(
                get: { manager.protectsCurrentTopology },
                set: { manager.setTopologyProtection($0) }
            ))
            .disabled(!manager.canChangeDisplayConfiguration)
        }
        if manager.screens.count > 1 {
            if display.isInMirrorSet {
                Button("Отключить видеоповтор", systemImage: "display.2") { manager.stopMirroring(display.id) }
                    .disabled(!manager.canChangeDisplayConfiguration)
            } else {
                Menu("Показывать изображение с…") {
                    ForEach(manager.screens.filter { $0.id != display.id && !$0.isInMirrorSet }) { source in
                        Button(source.title) { manager.tryMirror(display.id, of: source.id) }
                    }
                }
                .disabled(!manager.canChangeDisplayConfiguration)
            }
        }
        if manager.canDisconnect(display) {
            Button("Отключить дисплей", systemImage: "display") { manager.disconnect(display.id) }
        }
        if let disconnected = manager.disconnectedDisplayName {
            Button("Подключить \(disconnected)", systemImage: "display") {
                Task { await manager.reconnectDisplay() }
            }
            .disabled(!manager.canChangeDisplayConfiguration)
        }
        Divider()
        HStack {
            Text("Виртуальный дисплей").font(.headline)
            Spacer()
            if manager.virtualID != nil {
                Button("Отключить") { manager.removeVirtual() }
            } else {
                Button(virtualEditor ? "Скрыть" : "Создать…") { virtualEditor.toggle() }
            }
        }
        .disabled(!manager.canChangeDisplayConfiguration)
        if virtualEditor && manager.virtualID == nil {
            HStack {
                TextField("Ширина", text: $virtualWidth).accessibilityLabel("Ширина")
                Text("×")
                TextField("Высота", text: $virtualHeight).accessibilityLabel("Высота")
                Toggle("HiDPI", isOn: $virtualHiDPI).toggleStyle(.checkbox)
                Button("Подключить") {
                    guard let width = Int(virtualWidth), let height = Int(virtualHeight) else {
                        manager.message = "Введи ширину и высоту целыми числами."
                        return
                    }
                    manager.createVirtual(width: width, height: height, hiDPI: virtualHiDPI)
                }
                .buttonStyle(.borderedProminent)
            }
            .textFieldStyle(.roundedBorder)
            .disabled(!manager.canChangeDisplayConfiguration)
            Text("Дополнительный рабочий стол, 60 Гц. HiDPI удваивает разрешение рендера.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var layoutMap: some View {
        let independent = manager.screens.filter { $0.mirrors == 0 }
        let canvas = independent.reduce(CGRect.null) { $0.union($1.bounds) }
        return GeometryReader { geometry in
            let scale = min((geometry.size.width - 24) / max(1, canvas.width),
                            (geometry.size.height - 20) / max(1, canvas.height))
            if !canvas.isNull, scale > 0 {
                ForEach(independent) { screen in
                    layoutTile(screen, canvas: canvas, scale: scale, container: geometry.size)
                }
            }
        }
        .frame(height: 127)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func layoutTile(_ screen: Display, canvas: CGRect, scale: CGFloat, container: CGSize) -> some View {
        let selected = screen.id == manager.selectedID
        let fill: Color = selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.075)
        let stroke: Color = selected ? Color.accentColor : Color.primary.opacity(0.20)
        let width: CGFloat = max(1, screen.bounds.width * scale - 2)
        let height: CGFloat = max(1, screen.bounds.height * scale - 2)
        let x: CGFloat = container.width / 2 + (screen.bounds.midX - canvas.midX) * scale
        let y: CGFloat = container.height / 2 + (screen.bounds.midY - canvas.midY) * scale
        let weight: Font.Weight = selected ? .semibold : .regular
        let traits: AccessibilityTraits = selected ? .isSelected : []
        return Button {
            manager.select(screen.id)
        } label: {
            VStack(spacing: 3) {
                if screen.isMain { Image(systemName: "menubar.rectangle") }
                Text(screen.title).lineLimit(1).truncationMode(.tail)
            }
            .font(.caption2.weight(weight))
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(fill, in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5).strokeBorder(stroke)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(screen.title)
        .accessibilityAddTraits(traits)
        .frame(width: width, height: height)
        .position(x: x, y: y)
    }

    private var footer: some View {
        HStack {
            if let message = manager.message {
                Text(message)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                Button("Настройки дисплеев macOS", systemImage: "arrow.up.right") { openDisplaySettings() }
                    .buttonStyle(.link)
                    .font(.caption)
                Spacer()
            }
        }
        .frame(minHeight: 20)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func openDisplaySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct HardwareSlider: View {
    let control: MonitorControl
    let current: ControlValue
    let isWriting: Bool
    let commit: (Double) -> Void
    @State private var value: Double
    @State private var editing = false

    init(control: MonitorControl, current: ControlValue, isWriting: Bool, commit: @escaping (Double) -> Void) {
        self.control = control
        self.current = current
        self.isWriting = isWriting
        self.commit = commit
        _value = State(initialValue: current.value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(control.label, systemImage: control.symbol)
                .font(.callout)
            HStack {
                Slider(value: $value, in: 0...1, step: 0.01, label: { Text(control.label) },
                       onEditingChanged: { changed in
                    editing = changed
                    if !changed && abs(current.value - value) > 0.005 { commit(value) }
                })
                .labelsHidden()
                Text(value.formatted(.percent.precision(.fractionLength(0))))
                    .font(.callout.monospacedDigit())
                    .frame(width: 42, alignment: .trailing)
                Button("Применить") { commit(value) }
                    .disabled(abs(current.value - value) <= 0.005)
            }
        }
        .disabled(isWriting)
        .onChange(of: current.value) { if !editing { value = current.value } }
        .onChange(of: isWriting) { if !isWriting && !editing { value = current.value } }
    }
}
