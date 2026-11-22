import SwiftUI

struct DisplayProfilesView: View {
    let manager: DisplayManager
    @State private var editing = false
    @State private var name = ""

    private var isBusy: Bool { !manager.canChangeDisplayConfiguration }
    private var topology: [String] { manager.screens.map(\.identity).sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Профили подключения").font(.headline)
                Spacer()
                if !editing {
                    Button(manager.currentProfile == nil ? "Сохранить…" : "Обновить…",
                           systemImage: manager.currentProfile == nil ? "plus" : "arrow.clockwise") {
                        name = manager.currentProfile?.name ?? defaultName
                        editing = true
                    }
                    .disabled(isBusy || !manager.canCaptureProfile)
                }
            }

            if editing {
                HStack {
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
                Text("Профили доступны для физических дисплеев с отдельными рабочими столами.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if manager.profiles.isEmpty {
                Text("Сохрани текущий масштаб, частоту, расположение и основной экран для этой связки дисплеев.")
                    .font(.callout).foregroundStyle(.secondary)
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
        return VStack(alignment: .leading, spacing: 9) {
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
                    Button("Применить") { manager.tryProfile(profile.id) }
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
                    Text(screen.isMain ? "\(screen.name) · основной" : screen.name)
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
            .help("При запуске, изменении набора дисплеев и пробуждении")
            .disabled(isBusy)
            Toggle("Защищать настройки во время работы", isOn: Binding(
                get: { profile.protectsConfiguration == true },
                set: { manager.setProfileProtection(profile.id, enabled: $0) }
            ))
            .toggleStyle(.checkbox)
            .help("Восстанавливать масштаб, частоту, расположение и ICC-профиль после внешнего изменения")
            .disabled(isBusy)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct DisplayHistoryView: View {
    let manager: DisplayManager
    @State private var confirmingClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("История дисплеев").font(.headline)
                Spacer()
                if confirmingClear {
                    Button("Отмена") { confirmingClear = false }
                    Button("Удалить записи", role: .destructive) {
                        manager.clearHistory()
                        confirmingClear = false
                    }
                } else if !manager.history.isEmpty {
                    Button("Очистить…") { confirmingClear = true }
                }
            }

            if manager.history.isEmpty {
                Text("Здесь появятся подключения дисплеев, пробуждения и результаты восстановления настроек.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(manager.history) { entry in
                    eventCard(entry)
                }
            }
        }
    }

    private func eventCard(_ entry: DisplayHistoryEntry) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(entry.screens) { screen in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(manager.historyDisplayName(for: screen)).font(.caption.weight(.semibold))
                        if let after = screen.after, screen.before == after,
                           screen.requested == nil || screen.requested == after {
                            Text(after.label)
                        } else {
                            if let before = screen.before { Text("До · \(before.label)") }
                            if let requested = screen.requested, requested != screen.after {
                                Text("Запрошен · \(requested.label)")
                            }
                            if let after = screen.after {
                                Text(screen.requested == after ? "Применён · \(after.label)" : "После · \(after.label)")
                            } else {
                                Text("Дисплей отключён")
                            }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 5)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.triggers.map(\.title).joined(separator: " · "))
                    .font(.callout.weight(.semibold))
                Text(entry.date.formatted(.dateTime.day().month().year().hour().minute().second()))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if let name = entry.profileName { Text(name).font(.caption.weight(.medium)) }
                Text(entry.result).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.leading, 2)
        }
        .padding(10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
    }
}
