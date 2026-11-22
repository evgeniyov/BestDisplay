import Darwin
import Foundation
import os

struct CECClient: Sendable {
    enum TVCommand: String, CaseIterable, Identifiable, Sendable {
        case wake = "on 0"
        case standby = "standby 0"
        case activeSource = "as"

        var id: Self { self }

        var title: String {
            switch self {
            case .wake: "Включить телевизор"
            case .standby: "Перевести телевизор в режим ожидания"
            case .activeSource: "Выбрать HDMI-вход Mac"
            }
        }
    }

    let executable: URL

    static var installed: Self? {
        ["/opt/homebrew/bin/cec-client", "/usr/local/bin/cec-client"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { Self(executable: URL(fileURLWithPath: $0)) }
    }

    /// Adapters confirmed by `cec-client -l`, keyed by port with the uptime of the last check.
    private static let verified = OSAllocatedUnfairLock<[String: TimeInterval]>(initialState: [:])
    private static let verificationLifetime: TimeInterval = 15

    static func parseAdapters(_ output: String) -> [String] {
        let prefix = "com port:"
        return output.components(separatedBy: .newlines).compactMap { line in
            let clean = line.trimmingCharacters(in: .whitespaces)
            guard clean.lowercased().hasPrefix(prefix) else { return nil }
            let port = clean.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return port.hasPrefix("/dev/cu.") || port.hasPrefix("/dev/tty.") ? port : nil
        }
    }

    func adapters() async throws -> [String] {
        let found = Self.parseAdapters(try await run(["-l"]))
        let now = ProcessInfo.processInfo.systemUptime
        Self.verified.withLock { $0 = Dictionary(uniqueKeysWithValues: found.map { ($0, now) }) }
        return found
    }

    private func isRecentlyVerified(_ adapter: String) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        return Self.verified.withLock { $0[adapter].map { now - $0 < Self.verificationLifetime } ?? false }
    }

    func powerStatus(on adapter: String) async throws -> String {
        try Self.parsePowerStatus(try await runCommand("pow 0", adapter: adapter))
    }

    static func parsePowerStatus(_ output: String) throws -> String {
        guard let line = output.components(separatedBy: .newlines).first(where: {
            $0.lowercased().contains("power status:")
        }), let value = line.split(separator: ":", maxSplits: 1).last?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            throw DisplayFailure("Телевизор не ответил на запрос HDMI-CEC.")
        }
        switch value {
        case "on": return "Телевизор включён"
        case "standby": return "Телевизор в режиме ожидания"
        case "in transition standby to on", "in transition from standby to on": return "Телевизор включается"
        case "in transition on to standby", "in transition from on to standby": return "Телевизор выключается"
        default: throw DisplayFailure("Телевизор не подтвердил состояние питания.")
        }
    }

    func send(_ command: TVCommand, on adapter: String, hdmiPort: Int? = nil) async throws {
        _ = try await runCommand(command.rawValue, adapter: adapter,
                                 hdmiPort: command == .activeSource ? hdmiPort : nil)
    }

    private func runCommand(_ command: String, adapter: String, hdmiPort: Int? = nil) async throws -> String {
        guard adapter.hasPrefix("/dev/cu.") || adapter.hasPrefix("/dev/tty.") else {
            throw DisplayFailure("Адаптер HDMI-CEC больше недоступен.")
        }
        // Re-check the adapter list only when the last check is stale.
        if !isRecentlyVerified(adapter), try await !adapters().contains(adapter) {
            throw DisplayFailure("Адаптер HDMI-CEC больше недоступен.")
        }
        return try await execute(command, adapter: adapter, hdmiPort: hdmiPort)
    }

    private func execute(_ command: String, adapter: String, hdmiPort: Int?) async throws -> String {
        var arguments = ["-s", "-t", "p", "-d", "1", "-aw", "0"]
        if let hdmiPort {
            guard (1...15).contains(hdmiPort) else { throw DisplayFailure("Укажи номер HDMI-входа от 1 до 15.") }
            arguments += ["-p", String(hdmiPort)]
        }
        arguments.append(adapter)
        let output = try await run(arguments, input: command + "\n")
        let failure = output.lowercased()
        guard !failure.contains("unable to open"), !failure.contains("failed to open"),
              !failure.contains("connection lost"), !failure.contains("command not sent"),
              !failure.contains("cannot open"), !failure.contains("failed to transmit") else {
            throw DisplayFailure("Адаптер CEC не подтвердил отправку команды по HDMI.")
        }
        return output
    }

    private func run(_ args: [String], input: String? = nil) async throws -> String {
        try await Task.detached(priority: .utility) {
            let files = FileManager.default
            let directory = files.temporaryDirectory.appendingPathComponent("BestDisplay-CEC-\(UUID())")
            try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? files.removeItem(at: directory) }
            let output = directory.appendingPathComponent("output")
            try Data().write(to: output)
            let outputHandle = try FileHandle(forWritingTo: output)
            defer { try? outputHandle.close() }

            let task = Process()
            task.executableURL = executable
            task.arguments = args
            task.environment = ["LANG": "C", "LC_ALL": "C", "PATH": "/usr/bin:/bin"]
            task.standardOutput = outputHandle
            task.standardError = outputHandle
            if let input {
                let command = directory.appendingPathComponent("command")
                try Data(input.utf8).write(to: command)
                task.standardInput = try FileHandle(forReadingFrom: command)
            } else {
                task.standardInput = FileHandle.nullDevice
            }
            let exit = OSAllocatedUnfairLock<Int32?>(initialState: nil)
            task.terminationHandler = { task in exit.withLock { $0 = task.terminationStatus } }
            try task.run()
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while exit.withLock({ $0 == nil }) && ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            guard let status = exit.withLock({ $0 }) else {
                if task.isRunning {
                    task.terminate()
                    try await Task.sleep(for: .milliseconds(100))
                    if task.isRunning { kill(task.processIdentifier, SIGKILL) }
                }
                throw DisplayFailure("Адаптер CEC не ответил вовремя.")
            }
            let response = try FileHandle(forReadingFrom: output)
            defer { try? response.close() }
            let data = try response.read(upToCount: 65_536) ?? Data()
            let text = String(decoding: data, as: UTF8.self)
            if args == ["-l"] && text.lowercased().contains("found devices: none") { return text }
            guard status == 0 else { throw DisplayFailure("cec-client завершился с ошибкой \(status).") }
            return text
        }.value
    }
}
