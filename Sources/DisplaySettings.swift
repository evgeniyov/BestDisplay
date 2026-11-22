import Foundation

struct Dimensions: Codable, Equatable, Hashable, Sendable {
    let width: Int
    let height: Int

    var label: String { "\(width)×\(height)" }
    var area: Int { width * height }
    var aspect: Double { Double(width) / Double(height) }
}

struct ModeKey: Codable, Equatable, Hashable, Sendable {
    let desktop: Dimensions
    let rendering: Dimensions
    let millihertz: Int

    init(desktop: Dimensions, rendering: Dimensions, millihertz: Int) {
        self.desktop = desktop
        self.rendering = rendering
        self.millihertz = millihertz
    }

    var isHiDPI: Bool { rendering.width > desktop.width && rendering.height > desktop.height }
    var frequency: String {
        guard millihertz > 0 else { return "Авто" }
        return "\((Double(millihertz) / 1000).formatted(.number.precision(.fractionLength(0...2)))) Гц"
    }
    var density: String { isHiDPI ? "HiDPI" : "1×" }
    var label: String { "\(desktop.label) · \(density) · \(frequency)" }
}

struct DisplayColor: Codable, Equatable {
    let customProfile: URL?
}

enum DisplayOrientation: Int32, Codable, CaseIterable {
    case normal = 0, right = 90, upsideDown = 180, left = 270

    var title: String { "\(rawValue)°" }
}

struct DisplayTopology: Codable, Equatable {
    let identities: [String]
    let orientations: [String: DisplayOrientation]
    let mirrors: [String: String]
}

struct DisplayProfile: Codable, Equatable, Identifiable {
    struct Screen: Codable, Equatable, Identifiable {
        let id: String
        let name: String
        let mode: ModeKey
        let origin: CGPoint
        let isMain: Bool
        var color: DisplayColor?
    }

    let id: UUID
    var name: String
    var automaticallyApplies: Bool
    var protectsConfiguration: Bool? = nil
    var screens: [Screen]

    var displayIDs: Set<String> { Set(screens.map(\.id)) }
    var modes: [String: ModeKey] {
        Dictionary(screens.map { ($0.id, $0.mode) }, uniquingKeysWith: { first, _ in first })
    }

    static func current(in profiles: [Self], displayIDs: Set<String>) -> Self? {
        profiles.last { $0.screens.count == displayIDs.count && $0.displayIDs == displayIDs }
    }
}

struct DisplayHistoryEntry: Codable, Identifiable {
    enum Trigger: String, Codable, CaseIterable {
        case launch, wake, attached, detached, profile, protection, verification

        var title: String {
            switch self {
            case .launch: "Запуск BestDisplay"
            case .wake: "Пробуждение экранов"
            case .attached: "Подключение дисплея"
            case .detached: "Отключение дисплея"
            case .profile: "Ручное применение профиля"
            case .protection: "Защита конфигурации"
            case .verification: "Повторная проверка настроек"
            }
        }
    }

    struct Screen: Codable, Identifiable {
        let id: String
        let name: String
        let before: ModeKey?
        let requested: ModeKey?
        let after: ModeKey?

        static func knownName(_ name: String?) -> String? {
            guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            if name.hasPrefix("Дисплей "), UInt32(name.dropFirst("Дисплей ".count)) != nil { return nil }
            return name
        }

        static func displayName(_ name: String?, lastKnown: String?, displayID: String) -> String {
            knownName(name) ?? knownName(lastKnown) ?? "Дисплей \(displayID)"
        }
    }

    let id: UUID
    let date: Date
    let triggers: [Trigger]
    let profileName: String?
    let result: String
    let screens: [Screen]
}
