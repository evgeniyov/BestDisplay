import CoreGraphics
import ColorSync
import Darwin
import Foundation
import IOKit

func registryProperty(_ entry: io_registry_entry_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

enum MonitorControl: String, CaseIterable, Sendable {
    case brightness
    case contrast
    case volume
    case redGain, greenGain, blueGain

    var label: String {
        switch self {
        case .brightness: "Яркость"
        case .contrast: "Контраст"
        case .volume: "Громкость монитора"
        case .redGain: "Красный канал"
        case .greenGain: "Зелёный канал"
        case .blueGain: "Синий канал"
        }
    }

    var symbol: String {
        switch self {
        case .brightness: "sun.max"
        case .contrast: "circle.lefthalf.filled"
        case .volume: "speaker.wave.2"
        case .redGain, .greenGain, .blueGain: "circle.lefthalf.filled"
        }
    }

    fileprivate var vcp: UInt8 {
        switch self {
        case .brightness: 0x10
        case .contrast: 0x12
        case .volume: 0x62
        case .redGain: 0x16
        case .greenGain: 0x18
        case .blueGain: 0x1a
        }
    }
}

struct ControlValue: Sendable {
    let value: Double
    let maximum: UInt16
    let system: Bool
}

struct MonitorTarget: Sendable, Equatable {
    let id: CGDirectDisplayID
    let identity: String
    let location: String?

    var stillOnline: Bool {
        CGDisplayIsOnline(id) != 0 && displayIdentity(id) == identity
    }
}

private enum SystemBrightness {
    typealias Read = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias Write = @convention(c) (CGDirectDisplayID, Float) -> Int32
    nonisolated(unsafe) static let framework = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL
    )
    static let read = loadSymbol(framework, "DisplayServicesGetBrightness", as: Read.self)
    static let write = loadSymbol(framework, "DisplayServicesSetBrightness", as: Write.self)

    static func value(_ id: CGDirectDisplayID) -> ControlValue? {
        var brightness: Float = 0
        guard write != nil, read?(id, &brightness) == 0, (0...1).contains(brightness) else { return nil }
        return ControlValue(value: Double(brightness), maximum: 100, system: true)
    }
}

private struct DDCLink {
    typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias Read = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> kern_return_t
    typealias Write = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeRawPointer, UInt32) -> kern_return_t

    nonisolated(unsafe) static let framework = dlopen(
        "/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL
    )
    static let create = loadSymbol(framework, "IOAVServiceCreateWithService", as: Create.self)
    static let readI2C = loadSymbol(framework, "IOAVServiceReadI2C", as: Read.self)
    static let writeI2C = loadSymbol(framework, "IOAVServiceWriteI2C", as: Write.self)

    let service: CFTypeRef
    let chip: UInt32
    private let host: UInt32 = 0x51

    static func find(for target: MonitorTarget) -> DDCLink? {
        guard let location = target.location, let create,
              let controller = location.split(separator: "/").dropLast().last?.split(separator: "@").first,
              controller.hasPrefix("dispext") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var match: DDCLink?
        while case let proxy = IOIteratorNext(iterator), proxy != 0 {
            defer { IOObjectRelease(proxy) }
            guard registryProperty(proxy, "Location") as? String == "External" else { continue }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(proxy, kIOServicePlane, &parent) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(parent) }
            var name = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(parent, &name) == KERN_SUCCESS else { continue }
            let endpoint = String(decoding: name.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
            guard endpoint.hasPrefix("\(controller):") else { continue }
            // A match must identify exactly one bus. Don't guess if the OS exposes a topology we don't recognize.
            guard match == nil else { return nil }
            guard let service = create(kCFAllocatorDefault, proxy)?.takeRetainedValue() else { continue }
            let bridge = registryProperty(parent, "EPICProviderClass") as? String == "AppleDCPMCDP29XX"
            match = DDCLink(service: service, chip: bridge ? 0xb7 : 0x37)
        }
        return match
    }

    private func send(_ payload: [UInt8]) -> Bool {
        guard let write = Self.writeI2C else { return false }
        let bytes = payload + [payload.reduce(0x6e ^ UInt8(host), ^)]
        return bytes.withUnsafeBytes {
            write(service, chip, host, $0.baseAddress!, UInt32(bytes.count)) == KERN_SUCCESS
        }
    }

    func get(_ control: MonitorControl) -> ControlValue? {
        guard let (value, maximum) = readFeature(control.vcp), maximum > 0, value <= maximum else { return nil }
        return ControlValue(value: Double(value) / Double(maximum), maximum: maximum, system: false)
    }

    func readFeature(_ code: UInt8) -> (value: UInt16, maximum: UInt16)? {
        for pause in [useconds_t(30_000), 50_000] {
            guard send([0x82, 0x01, code]) else { continue }
            usleep(pause)
            guard let response = receive(length: 12), response.count == 11,
                  response[2] == 0x02, response[4] == code else { continue }
            guard response[3] == 0 else { return nil }
            return (UInt16(response[8]) << 8 | UInt16(response[9]),
                    UInt16(response[6]) << 8 | UInt16(response[7]))
        }
        return nil
    }

    private func receive(length: Int) -> [UInt8]? {
        guard let read = Self.readI2C else { return nil }
        var response = [UInt8](repeating: 0, count: length)
        let status = response.withUnsafeMutableBytes { read(service, chip, host, $0.baseAddress!, UInt32(length)) }
        guard status == KERN_SUCCESS, response[0] == 0x6e, response[1] & 0x80 != 0 else { return nil }
        let frameSize = Int(response[1] & 0x7f) + 3
        guard frameSize >= 4, frameSize <= response.count, response.prefix(frameSize).reduce(0x50, ^) == 0 else {
            return nil
        }
        return Array(response.prefix(frameSize))
    }

    func capabilities() -> String? {
        var bytes: [UInt8] = []
        for _ in 0..<96 {
            let offset = UInt16(bytes.count)
            guard send([0x83, 0xf3, UInt8(offset >> 8), UInt8(truncatingIfNeeded: offset)]) else { return nil }
            usleep(55_000)
            guard let response = receive(length: 38), response.count >= 6, response[2] == 0xe3,
                  response[3] == UInt8(offset >> 8), response[4] == UInt8(truncatingIfNeeded: offset) else { return nil }
            let payload = response.dropFirst(5).dropLast()
            if payload.isEmpty { return String(bytes: bytes, encoding: .ascii) }
            bytes += payload.prefix { $0 != 0 }
            if payload.contains(0) { return String(bytes: bytes, encoding: .ascii) }
            if bytes.count > 2048 { return nil }
        }
        return nil
    }

    func set(_ control: MonitorControl, _ value: UInt16) -> Bool { setFeature(control.vcp, value) }

    func setFeature(_ code: UInt8, _ value: UInt16) -> Bool {
        send([0x84, 0x03, code, UInt8(value >> 8), UInt8(truncatingIfNeeded: value)])
    }

}

actor MonitorControls {
    func brightness(of target: MonitorTarget) -> ControlValue? {
        guard target.stillOnline else { return nil }
        return SystemBrightness.value(target.id) ?? DDCLink.find(for: target)?.get(.brightness)
    }

    func scan(_ target: MonitorTarget) -> [MonitorControl: ControlValue] {
        guard target.stillOnline else { return [:] }
        var values: [MonitorControl: ControlValue] = [:]
        if let brightness = SystemBrightness.value(target.id) { values[.brightness] = brightness }
        if let link = DDCLink.find(for: target) {
            for control in MonitorControl.allCases where values[control] == nil {
                values[control] = link.get(control)
            }
        }
        return values
    }

    func set(_ value: Double, for control: MonitorControl, current: ControlValue, target: MonitorTarget) throws -> ControlValue {
        guard value.isFinite, target.stillOnline else { throw DisplayFailure("Дисплей отключён.") }
        let value = min(1, max(control == .brightness ? 0.01 : 0, value))
        if current.system, control == .brightness,
           SystemBrightness.write?(target.id, Float(value)) == 0 {
            return SystemBrightness.value(target.id) ?? ControlValue(value: value, maximum: current.maximum, system: true)
        }
        let raw = UInt16((Double(current.maximum) * value).rounded())
        let displayValue = control == .brightness ? max(1, raw) : raw
        if !current.system, let link = DDCLink.find(for: target), link.set(control, displayValue) {
            usleep(50_000)
            if let result = link.get(control) { return result }
        }
        throw DisplayFailure("Монитор не подтвердил изменение. Обнови список доступных настроек.")
    }
}

extension MonitorControls {
    func hardwareOptions(for target: MonitorTarget) -> HardwareOptions? {
        guard target.stillOnline, let link = DDCLink.find(for: target),
              let capabilities = link.capabilities() else { return nil }
        let input = link.readFeature(HardwareOptions.Feature.input.rawValue)?.value
        let power = link.readFeature(HardwareOptions.Feature.power.rawValue)?.value
        let inputChoices = input == nil ? [] : HardwareOptions.codes(.input, in: capabilities).map {
            HardwareOptions.Choice(id: $0, name: HardwareOptions.inputLabel($0))
        }
        let powerChoices: [HardwareOptions.Choice] = power == nil ? [] : HardwareOptions.codes(.power, in: capabilities).compactMap { value in
            switch value {
            case 1: HardwareOptions.Choice(id: value, name: "Включить")
            case 2: HardwareOptions.Choice(id: value, name: "Режим ожидания")
            default: nil
            }
        }
        return HardwareOptions(inputs: inputChoices, powerModes: powerChoices, currentInput: input, currentPower: power)
    }

    func setHardwareOption(
        _ value: UInt16, for feature: HardwareOptions.Feature, options: HardwareOptions, target: MonitorTarget
    ) throws {
        guard target.stillOnline, options.supports(value, for: feature), let link = DDCLink.find(for: target),
              link.setFeature(feature.rawValue, value) else {
            throw DisplayFailure("Монитор не принял команду DDC.")
        }
    }
}
