import Foundation

struct HardwareOptions: Sendable {
    enum Feature: UInt8, Sendable { case input = 0x60, power = 0xd6 }

    struct Choice: Identifiable, Sendable {
        let id: UInt16
        let name: String
    }

    let inputs: [Choice]
    let powerModes: [Choice]
    let currentInput: UInt16?
    let currentPower: UInt16?

    func supports(_ value: UInt16, for feature: Feature) -> Bool {
        let choices = feature == .input ? inputs : powerModes
        return choices.contains { $0.id == value }
    }

    static func codes(_ feature: Feature, in capabilities: String) -> [UInt16] {
        let code = String(format: "%02X", feature.rawValue)
        let pattern = #"(?:\s|\()"# + code + #"\s*\(\s*([0-9A-F\s]+)\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: capabilities, range: NSRange(capabilities.startIndex..., in: capabilities)),
              let range = Range(match.range(at: 1), in: capabilities) else { return [] }
        var seen = Set<UInt16>()
        return capabilities[range].split(whereSeparator: \.isWhitespace)
            .compactMap { UInt16($0, radix: 16) }.filter { seen.insert($0).inserted }
    }

    static func inputLabel(_ code: UInt16) -> String {
        switch code {
        case 0x01: "VGA 1"
        case 0x02: "VGA 2"
        case 0x03: "DVI 1"
        case 0x04: "DVI 2"
        case 0x0f: "DisplayPort 1"
        case 0x10: "DisplayPort 2"
        case 0x11: "HDMI 1"
        case 0x12: "HDMI 2"
        case 0x1b: "USB-C"
        default: "Вход 0x\(String(code, radix: 16, uppercase: true))"
        }
    }
}
