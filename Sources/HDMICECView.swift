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
                Label("HDMI-CEC", systemImage: "tv").font(.headline)
                Spacer()
                Button("Найти адаптеры") { scan() }.disabled(busy)
            }
            if client == nil {
                Text("Для управления ТВ нужен USB–CEC адаптер и утилита cec-client.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !adapters.isEmpty {
                Picker("Адаптер", selection: $selected) {
                    ForEach(adapters, id: \.self) { port in Text(port).tag(Optional(port)) }
                }
                Picker("HDMI-вход ТВ", selection: $hdmiPort) {
                    Text("Автоматически").tag(0)
                    ForEach(1...15, id: \.self) { port in Text("HDMI \(port)").tag(port) }
                }
                .disabled(busy)
                HStack {
                    Button("Состояние ТВ") { checkPower() }
                    Menu("Управление ТВ") {
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
            result = adapters.isEmpty ? "USB–CEC адаптеры не найдены." : nil
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
            result = "Команда отправлена. Можно запросить состояние ТВ."
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
