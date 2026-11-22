import SwiftUI

struct HDMICECView: View {
    @State private var client = CECClient.installed
    @State private var adapters: [String] = []
    @State private var selected: String?
    @State private var result: String?
    @State private var busy = false
    @State private var pending: CECClient.TVCommand?
    @AppStorage("cecHDMIPort") private var hdmiPort = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Управление телевизором", systemImage: "tv").font(.callout.weight(.semibold))
                Spacer()
                Button("Найти адаптеры") { scan() }
                    .help("Найди подключённые адаптеры для команд HDMI-CEC.")
                    .disabled(busy)
            }
            if client == nil {
                Text("Подключи адаптер USB-CEC и установи cec-client для управления телевизором по HDMI.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !adapters.isEmpty {
                Picker("Адаптер USB-CEC", selection: $selected) {
                    ForEach(adapters, id: \.self) { port in Text(port).tag(Optional(port)) }
                }
                .help("Выбери адаптер, к которому подключён телевизор.")
                Picker("HDMI-вход телевизора", selection: $hdmiPort) {
                    Text("Автоматически").tag(0)
                    ForEach(1...15, id: \.self) { port in Text("HDMI \(port)").tag(port) }
                }
                .help("Укажи, к какому HDMI-входу телевизора подключён Mac.")
                .disabled(busy)
                HStack {
                    Button("Проверить питание") { checkPower() }
                        .help("Узнай, включён ли телевизор.")
                    Menu("Команда телевизору") {
                        ForEach(CECClient.TVCommand.allCases) { command in
                            Button(command.title) { pending = command }
                        }
                    }
                }
                .disabled(busy || selected == nil)
            }
            if let result {
                Text(result).font(.caption).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(pending?.title ?? "HDMI-CEC", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible) {
            if let command = pending {
                Button(command.title) { send(command) }
            }
            Button("Отмена", role: .cancel) { pending = nil }
        }
    }

    private func scan() {
        client = CECClient.installed
        guard let client else {
            adapters = []
            selected = nil
            result = "cec-client не найден."
            return
        }
        perform {
            adapters = try await client.adapters()
            if !adapters.contains(selected ?? "") { selected = adapters.first }
            result = adapters.isEmpty ? "Адаптеры USB-CEC не найдены." : nil
        }
    }

    private func checkPower() {
        guard let client, let selected else { return }
        perform { result = try await client.powerStatus(on: selected) }
    }

    private func send(_ command: CECClient.TVCommand) {
        pending = nil
        guard let client, let selected else { return }
        perform {
            try await client.send(command, on: selected, hdmiPort: hdmiPort == 0 ? nil : hdmiPort)
            result = "Команда отправлена. Нажми «Проверить питание», чтобы узнать состояние телевизора."
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true
        result = nil
        Task {
            defer { busy = false }
            do { try await operation() }
            catch { result = error.localizedDescription }
        }
    }
}
