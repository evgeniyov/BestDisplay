import AppKit
import CoreGraphics
import Darwin
import IOKit

extension ModeKey {
    init(_ raw: CGDisplayMode) {
        self.init(desktop: Dimensions(width: raw.width, height: raw.height),
                  rendering: Dimensions(width: raw.pixelWidth, height: raw.pixelHeight),
                  millihertz: Int((raw.refreshRate * 1000).rounded()))
    }
}

struct ScreenMode: Identifiable {
    let raw: CGDisplayMode?
    let key: ModeKey
    let modeID: Int32
    var id: ModeKey { key }

    init(_ raw: CGDisplayMode) {
        self.raw = raw
        self.key = ModeKey(raw)
        modeID = raw.ioDisplayModeID
    }

    init(hidden key: ModeKey, modeID: Int32) {
        raw = nil
        self.key = key
        self.modeID = modeID
    }
}

struct Display: Identifiable {
    let id: CGDirectDisplayID
    let identity: String
    let title: String
    let builtIn: Bool
    let isVirtual: Bool
    let isInMirrorSet: Bool
    let isMain: Bool
    let mirrors: CGDirectDisplayID
    let bounds: CGRect
    let current: ScreenMode
    let modes: [ScreenMode]
    let panel: Dimensions?
    let location: String?
    let edr: CGFloat?
    let color: DisplayColor?

    var category: String {
        if builtIn { return "Встроенный" }
        if location != nil { return "Внешний" }
        return "Подключённый"
    }

    var recommendations: [(String, ScreenMode)] {
        var result: [(String, ScreenMode)] = []
        let aspect = (panel ?? current.key.desktop).aspect
        let relevant = modes.filter { abs($0.key.desktop.aspect / aspect - 1) < 0.035 }
        func choose(_ options: [ScreenMode], nearestWidth width: Int? = nil) -> ScreenMode? {
            options.min { a, b in
                if let width {
                    let aDistance = abs(a.key.desktop.width - width)
                    let bDistance = abs(b.key.desktop.width - width)
                    if aDistance != bDistance { return aDistance < bDistance }
                }
                let aDistance = abs(a.key.millihertz - current.key.millihertz)
                let bDistance = abs(b.key.millihertz - current.key.millihertz)
                return aDistance == bDistance
                    ? a.key.millihertz > b.key.millihertz
                    : aDistance < bDistance
            }
        }
        if let panel, let pixelPerfect = choose(relevant.filter({ $0.key.rendering == panel && $0.key.isHiDPI == builtIn })) {
            result.append(("Пиксель в пиксель", pixelPerfect))
        }
        let hiDPI = relevant.filter(\.key.isHiDPI)
        let comparisonSize = builtIn ? current.key.desktop : panel ?? current.key.desktop
        if let currentScale = choose(hiDPI.filter({ $0.key.desktop == comparisonSize })) {
            result.append(("Тот же размер в HiDPI", currentScale))
        }
        let reference = panel.map { builtIn ? $0.width / 2 : $0.width } ?? current.key.desktop.width
        let larger = relevant.filter { mode in
            (Double(reference) * 0.68...Double(reference) * 0.9).contains(Double(mode.key.desktop.width))
        }
        let largerHiDPI = larger.filter(\.key.isHiDPI)
        if let bigText = choose(largerHiDPI.isEmpty ? larger : largerHiDPI, nearestWidth: Int(Double(reference) * 0.83)) {
            result.append(("Крупнее текст", bigText))
        }
        var seen = Set<ModeKey>()
        return result.filter { seen.insert($0.1.key).inserted }
    }
}

func loadSymbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as type: T.Type) -> T? {
    guard let handle, let address = dlsym(handle, name) else { return nil }
    return unsafeBitCast(address, to: type)
}

// CoreDisplay supplies read-only panel metadata that Core Graphics omits.
private enum DisplayMetadata {
    typealias CopyInfo = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
    static let copyInfo = loadSymbol(
        dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY | RTLD_LOCAL),
        "CoreDisplay_DisplayCreateInfoDictionary", as: CopyInfo.self
    )

    static func info(_ id: CGDirectDisplayID) -> [String: Any] {
        copyInfo?(id)?.takeRetainedValue() as? [String: Any] ?? [:]
    }

    static func nativeSize(edid: Data) -> Dimensions? {
        let bytes = [UInt8](edid.prefix(128))
        guard bytes.count == 128, bytes.prefix(8).elementsEqual([0, 255, 255, 255, 255, 255, 255, 0]),
              bytes.reduce(UInt8(0), &+) == 0, bytes[24] & 0x02 != 0, bytes[54] != 0 || bytes[55] != 0 else { return nil }
        let width = Int(bytes[56]) | (Int(bytes[58] & 0xf0) << 4)
        let height = Int(bytes[59]) | (Int(bytes[61] & 0xf0) << 4)
        guard width > 0, height > 0 else { return nil }
        return Dimensions(width: width, height: height)
    }
}

@MainActor
func displays(among ids: [CGDirectDisplayID] = onlineDisplayIDs()) -> [Display] {
    let screens = Dictionary(NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, NSScreen)? in
        guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return (n.uint32Value, screen)
    }, uniquingKeysWith: { first, _ in first })
    return ids.compactMap { id -> Display? in
        guard let raw = CGDisplayCopyDisplayMode(id) else { return nil }
        let current = ScreenMode(raw)
        let info = DisplayMetadata.info(id)
        let identity = displayIdentity(id, among: ids) ?? "session-\(id)"
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        let offered = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
        let location = info["IODisplayLocation"] as? String
        let builtIn = CGDisplayIsBuiltin(id) != 0
        let publicModes = offered.filter { $0.isUsableForDesktopGUI() }.map(ScreenMode.init)
        let hiddenModes = (!builtIn && location != nil)
            ? HiddenDisplayModes.read(display: id, current: current, publicModes: publicModes)
            : []
        let sorted = ([current] + publicModes + hiddenModes).sorted {
            if $0.key.desktop.area != $1.key.desktop.area { return $0.key.desktop.area > $1.key.desktop.area }
            if $0.key.isHiDPI != $1.key.isHiDPI { return $0.key.isHiDPI }
            if $0.key.millihertz != $1.key.millihertz { return $0.key.millihertz > $1.key.millihertz }
            if ($0.raw == nil) != ($1.raw == nil) { return $0.raw != nil }
            return $0.modeID < $1.modeID
        }
        var unique = Set<ModeKey>()
        let modes = sorted.filter { unique.insert($0.key).inserted }
        let screen = screens[id]
        let productNames = info["DisplayProductName"] as? [String: String]
        let name = screen?.localizedName ?? productNames?["en_US"] ?? "Дисплей \(id)"
        let edid = (info["IODisplayEDID"] as? Data).flatMap(DisplayMetadata.nativeSize)
        // IOGraphics kDisplayModeNativeFlag identifies modes using native output timings.
        let native = publicModes.filter { ($0.raw?.ioFlags ?? 0) & 0x0200_0000 != 0 }
            .max { $0.key.rendering.area < $1.key.rendering.area }?.key.rendering
        let rotation = Int(CGDisplayRotation(id).rounded()) % 180
        let attributes = location.flatMap { path -> Dimensions? in
            let framebuffer = IORegistryEntryCopyFromPath(kIOMainPortDefault, path as CFString)
            guard framebuffer != 0 else { return nil }
            defer { IOObjectRelease(framebuffer) }
            guard let attrs = registryProperty(framebuffer, "DisplayAttributes") as? [String: Any],
                  let width = attrs["NativeFormatHorizontalPixels"] as? Int,
                  let height = attrs["NativeFormatVerticalPixels"] as? Int,
                  width > 0, height > 0 else { return nil }
            return Dimensions(width: width, height: height)
        }
        let panel = (edid ?? attributes).map {
            rotation == 0 ? $0 : Dimensions(width: $0.height, height: $0.width)
        } ?? native
        return Display(id: id, identity: identity, title: name, builtIn: builtIn,
                       isVirtual: info["kCGDisplayIsVirtualDevice"] as? Bool == true,
                       isInMirrorSet: CGDisplayIsInMirrorSet(id) != 0,
                       isMain: CGDisplayIsMain(id) != 0, mirrors: CGDisplayMirrorsDisplay(id),
                       bounds: CGDisplayBounds(id), current: current, modes: modes,
                       panel: panel, location: location,
                       edr: screen?.maximumPotentialExtendedDynamicRangeColorComponentValue, color: DisplayColor.read(id))
    }
}

struct DisplayFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
func configureDisplays(_ operation: (CGDisplayConfigRef) throws -> Void) throws {
    var configuration: CGDisplayConfigRef?
    let begin = CGBeginDisplayConfiguration(&configuration)
    guard begin == .success, let configuration else {
        throw DisplayFailure("Не удалось открыть конфигурацию дисплеев (\(begin.rawValue)).")
    }
    do {
        try operation(configuration)
    } catch {
        CGCancelDisplayConfiguration(configuration)
        throw error
    }
    try checkDisplayError(CGCompleteDisplayConfiguration(configuration, .forSession))
}

func checkDisplayError(_ result: CGError) throws {
    guard result == .success else { throw DisplayFailure("macOS отклонила изменение (\(result.rawValue)).") }
}

// Quartz filters part of the display mode table on Apple Silicon. Use its
// regular modes first and supplement them with eligible HiDPI entries.
enum HiddenDisplayModes {
    typealias Configure = @convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Int32) -> CGError
    private typealias Count = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>) -> Void
    private typealias Describe = @convention(c) (CGDirectDisplayID, Int32, UnsafeMutableRawPointer, Int32) -> Void

    nonisolated(unsafe) private static let framework = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL
    )
    static let configure = loadSymbol(framework, "CGSConfigureDisplayMode", as: Configure.self)
        ?? loadSymbol(framework, "SLSConfigureDisplayMode", as: Configure.self)
    private static let count = loadSymbol(framework, "CGSGetNumberOfDisplayModes", as: Count.self)
        ?? loadSymbol(framework, "SLSGetNumberOfDisplayModes", as: Count.self)
    private static let describe = loadSymbol(framework, "CGSGetDisplayModeDescriptionOfLength", as: Describe.self)
        ?? loadSymbol(framework, "SLSGetDisplayModeDescriptionOfLength", as: Describe.self)

    private struct Entry {
        let mode: ScreenMode
        let flags: UInt32

        init?(_ data: UnsafeRawBufferPointer) {
            let modeID = data.loadUnaligned(fromByteOffset: 0x00, as: Int32.self)
            let width = Int(data.loadUnaligned(fromByteOffset: 0x08, as: UInt32.self))
            let height = Int(data.loadUnaligned(fromByteOffset: 0x0c, as: UInt32.self))
            // The refresh rate is 16.16 fixed point, including fractional timings.
            let rate = data.loadUnaligned(fromByteOffset: 0xbc, as: UInt32.self)
            let backingWidth = Int(data.loadUnaligned(fromByteOffset: 0xc8, as: UInt32.self))
            let backingHeight = Int(data.loadUnaligned(fromByteOffset: 0xcc, as: UInt32.self))
            let scale = data.loadUnaligned(fromByteOffset: 0xd0, as: Float.self)
            flags = data.loadUnaligned(fromByteOffset: 0xc0, as: UInt32.self)
            guard modeID >= 0, (320...16384).contains(width), (200...16384).contains(height),
                  (scale == 1 || scale == 2), backingWidth == width * Int(scale),
                  backingHeight == height * Int(scale), rate <= 1000 << 16 else { return nil }
            let key = ModeKey(desktop: Dimensions(width: width, height: height),
                              rendering: Dimensions(width: backingWidth, height: backingHeight),
                              millihertz: Int((Double(rate) * 1000 / 65536).rounded()))
            mode = ScreenMode(hidden: key, modeID: modeID)
        }

        var isSafeDesktopHiDPI: Bool { flags & 3 == 3 && mode.key.isHiDPI }
    }

    static func read(display: CGDirectDisplayID, current: ScreenMode, publicModes: [ScreenMode]) -> [ScreenMode] {
        guard let count, let describe, configure != nil else { return [] }
        var total: Int32 = 0
        count(display, &total)
        guard (1...1024).contains(total) else { return [] }
        // WindowServer's 0xd4-byte mode description is private. Cross-check
        // its layout against the public current mode before trusting the table.
        let descriptionSize: Int32 = 0xd4
        let entries = (0..<total).compactMap { index -> Entry? in
            var data = [UInt8](repeating: 0, count: Int(descriptionSize))
            data.withUnsafeMutableBytes { buffer in
                describe(display, index, buffer.baseAddress!, descriptionSize)
            }
            return data.withUnsafeBytes(Entry.init)
        }
        guard entries.contains(where: { $0.mode.modeID == current.modeID && $0.mode.key == current.key }) else {
            return []
        }

        let publicIDs = Set(publicModes.map(\.modeID))
        return entries.filter { $0.isSafeDesktopHiDPI && !publicIDs.contains($0.mode.modeID) }.map(\.mode)
    }
}

func setMode(_ config: CGDisplayConfigRef, display: CGDirectDisplayID, mode: ScreenMode) throws {
    if let raw = mode.raw {
        try checkDisplayError(CGConfigureDisplayWithDisplayMode(config, display, raw, nil))
    } else {
        guard let configure = HiddenDisplayModes.configure else {
            throw DisplayFailure("Этот режим сейчас недоступен.")
        }
        try checkDisplayError(configure(config, display, mode.modeID))
    }
}
