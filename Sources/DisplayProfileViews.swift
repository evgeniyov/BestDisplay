import SwiftUI

struct DisplayProfilesView: View {
    let manager: DisplayManager
    @State private var editing = false
    @State private var name = ""

    private var isBusy: Bool { !manager.canChangeDisplayConfiguration }
    private var topology: [String] { manager.screens.map(\.identity).sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PanelCard(title: "Профили подключения") {
                if !editing {
                    Button(manager.currentProfile == nil ? "Сохранить профиль…" : "Обновить профиль…",
                           systemImage: manager.currentProfile == nil ? "plus" : "arrow.clockwise") {
                        name = manager.currentProfile?.name ?? defaultName
                        editing = true
                    }
                    .help("Сохрани настройки для текущего набора дисплеев.")
                    .disabled(isBusy || !manager.canCaptureProfile)
                } else {
                    HStack(spacing: 8) {
                        TextField("Название профиля", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(save)
                        Button("Отмена") { editing = false }
                        Button("Сохранить", action: save)
                            .buttonStyle(.borderedProminent)
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
                    }
                }

                if !manager.canCaptureProfile {
                    Text("Для сохранения профиля используй физические дисплеи с отдельными рабочими столами.")
                        .font(.callout).foregroundStyle(.secondary)
                } else if manager.profiles.isEmpty {
                    Text("Сохрани масштаб, частоту, расположение и выбор основного дисплея.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            ForEach(manager.profiles) { profile in
                profileCard(profile)
            }
        }
        .onChange(of: topology) { editing = false }
    }

    private var defaultName: String {
        if manager.screens.count == 1 && manager.screens.first?.builtIn == true { return "Только ноутбук" }
        return manager.screens.map { $0.builtIn ? "Ноутбук" : $0.title }.joined(separator: " + ")
    }

    private func save() {
        guard !isBusy, manager.canCaptureProfile, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        manager.saveProfile(named: name)
        editing = false
    }

    private func profileCard(_ profile: DisplayProfile) -> some View {
        let matches = profile.matches(manager.screens) && manager.canCaptureProfile
        let applied = matches && profile.isApplied(to: manager.screens)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name).font(.callout.weight(.semibold))
                    if applied {
                        Label("Активен", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(Color.accentColor)
                    } else if !matches {
                        Text("Подключи дисплеи этого профиля")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if matches && !applied {
                    Button("Проверить профиль") { manager.tryProfile(profile.id) }
                        .help("Включи настройки профиля на время. Подтверди их, чтобы оставить.")
                        .disabled(isBusy)
                }
                Menu {
                    Button("Удалить профиль", systemImage: "trash", role: .destructive) {
                        manager.deleteProfile(profile.id)
                    }
                    .disabled(isBusy)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Действия с профилем \(profile.name)")
            }
            ForEach(profile.screens) { screen in
                VStack(alignment: .leading, spacing: 2) {
                    Text(screen.isMain ? "Основной: \(screen.name)" : screen.name)
                        .font(.caption.weight(.medium))
                    Text(screen.mode.label).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Divider()
            Toggle("Применять автоматически", isOn: Binding(
                get: { profile.automaticallyApplies },
                set: { manager.setProfileAutomatic(profile.id, enabled: $0) }
            ))
            .toggleStyle(.checkbox)
            .help("Применяй профиль при запуске, изменении набора дисплеев и пробуждении.")
            .disabled(isBusy)
            Toggle("Восстанавливать настройки во время работы", isOn: Binding(
                get: { profile.protectsConfiguration == true },
                set: { manager.setProfileProtection(profile.id, enabled: $0) }
            ))
            .toggleStyle(.checkbox)
            .help("Верни масштаб, частоту, расположение и профиль ICC после изменений в других приложениях.")
            .disabled(isBusy)
        }
        .panelCardStyle()
    }
}

struct DisplayHistoryView: View {
    let manager: DisplayManager
    @State private var confirmingClear = false

    private struct Row: Identifiable {
        let entries: [DisplayHistoryEntry]
        let isUnchanged: Bool

        var id: UUID { entries[0].id }
    }

    private var rows: [Row] {
        var rows: [Row] = []
        var unchanged: [DisplayHistoryEntry] = []
        for entry in manager.history {
            if isUnchanged(entry) {
                unchanged.append(entry)
            } else {
                if !unchanged.isEmpty {
                    rows.append(Row(entries: unchanged, isUnchanged: true))
                    unchanged.removeAll()
                }
                rows.append(Row(entries: [entry], isUnchanged: false))
            }
        }
        if !unchanged.isEmpty { rows.append(Row(entries: unchanged, isUnchanged: true)) }
        return rows
    }

    private func isUnchanged(_ entry: DisplayHistoryEntry) -> Bool {
        guard !entry.triggers.contains(.attached), !entry.triggers.contains(.detached),
              entry.screens.allSatisfy({ $0.before == $0.after && ($0.requested == nil || $0.requested == $0.after) })
        else { return false }
        // Match complete results, including the text already stored by older versions.
        return [
            "Использованы текущие настройки macOS.",
            "Сохранённые режимы уже активны.",
            "Профиль уже активен."
        ].contains(entry.result)
    }

    var body: some View {
        PanelCard(title: "История дисплеев") {
            if confirmingClear {
                HStack(spacing: 8) {
                    Button("Отмена") { confirmingClear = false }
                    Button("Удалить записи", role: .destructive) {
                        manager.clearHistory()
                        confirmingClear = false
                    }
                }
            } else if !manager.history.isEmpty {
                Button("Очистить историю…") { confirmingClear = true }
                    .help("Удали все записи истории дисплеев.")
            }

            if manager.history.isEmpty {
                Text("Здесь появятся подключения, пробуждения и результаты восстановления настроек.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { row in
                    if row.isUnchanged, row.entries.count > 1 {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(row.entries, content: eventRow)
                            }
                            .padding(.top, 8)
                        } label: {
                            Text(unchangedTitle(row.entries.count))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .help("Покажи подробности проверок, после которых настройки остались прежними.")
                    } else {
                        ForEach(row.entries, content: eventRow)
                    }
                    Divider()
                }
            }
        }
    }

    private func unchangedTitle(_ count: Int) -> String {
        let noun: String
        switch (count % 10, count % 100) {
        case (_, 11...14): noun = "проверок"
        case (1, _): noun = "проверка"
        case (2...4, _): noun = "проверки"
        default: noun = "проверок"
        }
        return "\(count) \(noun) без изменений"
    }

    private func eventRow(_ entry: DisplayHistoryEntry) -> some View {
        let titles = entry.triggers.map(\.title)
        let title = ([titles.first].compactMap { $0 } + titles.dropFirst().map { $0.lowercased() }).joined(separator: ", ")
        let time = entry.date.formatted(.dateTime.day().month().hour().minute().second())
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if let name = entry.profileName { Text("Профиль: \(name)") }
                Text(title)
                Text(entry.date.formatted(.dateTime.day().month().year().hour().minute().second()))
                Text(entry.result)
                ForEach(entry.screens) { screen in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(manager.historyDisplayName(for: screen)).font(.caption.weight(.semibold))
                        if let after = screen.after, screen.before == after,
                           screen.requested == nil || screen.requested == after {
                            Text(after.label)
                        } else {
                            if let before = screen.before { Text("До: \(before.label)") }
                            if let requested = screen.requested, requested != screen.after {
                                Text("Запрошено: \(requested.label)")
                            }
                            if let after = screen.after {
                                Text(screen.requested == after ? "Применено: \(after.label)" : "После: \(after.label)")
                            } else {
                                Text("Дисплей отключён")
                            }
                        }
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(time).font(.caption).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                }
                Text([entry.profileName, entry.result].compactMap { $0 }.joined(separator: ". "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .help("\(title). \(entry.date.formatted(.dateTime.day().month().year().hour().minute().second())). \(entry.result)")
        }
    }
}
