import AppKit
import CoreGraphics
import CoreImage
import Darwin
import MetalKit
import QuartzCore

@MainActor
enum DisplayHDRMode {
    private typealias Query = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias Set = @convention(c) (CGDirectDisplayID, Bool) -> Void
    fileprivate static let library = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY | RTLD_LOCAL)
    private static let supports = loadSymbol(library, "CoreDisplay_Display_SupportsHDRMode", as: Query.self)
    private static let enabled = loadSymbol(library, "CoreDisplay_Display_IsHDRModeEnabled", as: Query.self)
    private static let change = loadSymbol(library, "CoreDisplay_Display_SetHDRModeEnabled", as: Set.self)

    static func status(for display: Display) -> Bool? {
        guard !display.isVirtual, !display.isInMirrorSet, CGDisplayIsOnline(display.id) != 0,
              change != nil, supports?(display.id) == true else { return nil }
        return enabled?(display.id)
    }

    @MainActor
    static func set(_ value: Bool, on display: Display) async throws {
        guard displayIdentity(display.id) == display.identity, let original = status(for: display),
              let change else { throw DisplayFailure("Этот дисплей не предоставляет переключатель HDR.") }
        guard original != value else { return }
        change(display.id, value)
        for _ in 0..<30 {
            guard CGDisplayIsOnline(display.id) != 0, displayIdentity(display.id) == display.identity else {
                throw DisplayFailure("Дисплей отключился во время переключения HDR.")
            }
            if enabled?(display.id) == value { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        if displayIdentity(display.id) == display.identity { change(display.id, original) }
        throw DisplayFailure("macOS не подтвердила переключение режима HDR.")
    }
}

@MainActor
struct DisplayReferencePresets {
    struct Preset: Identifiable {
        let id: UInt32
        let name: String
        let luminance: Double?

        var title: String {
            guard let luminance, luminance > 0 else { return name }
            return "\(name) · \(luminance.formatted(.number.precision(.fractionLength(0)))) нит"
        }
    }

    let options: [Preset]
    let active: UInt32

    private typealias IndexQuery = @convention(c) (CGDirectDisplayID) -> UInt32
    private typealias CopyPreset = @convention(c) (CGDirectDisplayID, UInt32) -> Unmanaged<CFDictionary>?
    private typealias SetPreset = @convention(c) (CGDirectDisplayID, UInt32) -> Bool
    private static let count = loadSymbol(DisplayHDRMode.library, "CoreDisplay_Display_GetPresetCount", as: IndexQuery.self)
    private static let current = loadSymbol(DisplayHDRMode.library, "CoreDisplay_Display_GetActivePresetIndex", as: IndexQuery.self)
    private static let copy = loadSymbol(DisplayHDRMode.library, "CoreDisplay_Display_CopyPreset", as: CopyPreset.self)
    private static let change = loadSymbol(DisplayHDRMode.library, "CoreDisplay_Display_SetActivePresetIndex", as: SetPreset.self)
    private static let nameKey = stringConstant("kCDDisplayPresetNameKey")
    private static let luminanceKey = stringConstant("kCDDisplayPresetMaxHDRLuminanceKey")
    private static let validKey = stringConstant("kCDDisplayPresetValidKey")

    private static func stringConstant(_ name: String) -> String? {
        guard let handle = DisplayHDRMode.library, let symbol = dlsym(handle, name),
              let value = symbol.assumingMemoryBound(to: Unmanaged<CFString>?.self).pointee else { return nil }
        return value.takeUnretainedValue() as String
    }

    static func read(_ display: Display) -> Self? {
        guard !display.isVirtual, !display.isInMirrorSet, CGDisplayIsOnline(display.id) != 0,
              let count = count?(display.id), (2...128).contains(count),
              let active = current?(display.id), active < count, let copy, change != nil, let nameKey else { return nil }
        let options: [Preset] = (0..<count).compactMap { index in
            guard let info = copy(display.id, index)?.takeRetainedValue() as? [String: Any],
                  let name = info[nameKey] as? String, !name.isEmpty else { return nil }
            if let validKey, info[validKey] as? Bool == false { return nil }
            let luminance = luminanceKey.flatMap { (info[$0] as? NSNumber)?.doubleValue }
            return Preset(id: index, name: name, luminance: luminance)
        }
        guard options.count > 1, options.contains(where: { $0.id == active }) else { return nil }
        return Self(options: options, active: active)
    }

    @MainActor
    static func set(_ index: UInt32, on display: Display) async throws {
        guard displayIdentity(display.id) == display.identity, let before = read(display),
              before.options.contains(where: { $0.id == index }), let change else {
            throw DisplayFailure("Этот дисплей не предоставляет указанный профиль XDR.")
        }
        guard index != before.active else { return }
        guard change(display.id, index) else { throw DisplayFailure("macOS отклонила профиль XDR.") }
        for _ in 0..<30 {
            guard CGDisplayIsOnline(display.id) != 0, displayIdentity(display.id) == display.identity else {
                throw DisplayFailure("Дисплей отключился при переключении профиля XDR.")
            }
            if current?(display.id) == index { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        if displayIdentity(display.id) == display.identity { _ = change(display.id, before.active) }
        throw DisplayFailure("macOS не подтвердила переключение профиля XDR.")
    }
}

@MainActor
struct EDRInfo {
    let screen: NSScreen

    init?(_ display: Display) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id
        }) else { return nil }
        self.screen = screen
    }

    var potential: CGFloat { screen.maximumPotentialExtendedDynamicRangeColorComponentValue }
    var current: CGFloat { screen.maximumExtendedDynamicRangeColorComponentValue }
    var reference: CGFloat { screen.maximumReferenceExtendedDynamicRangeColorComponentValue }
}

@MainActor
final class EDRPreview: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private(set) var patches: EDRPatches?

    func show(for display: Display) throws {
        guard let edr = EDRInfo(display), edr.potential > 1.001, let device = MTLCreateSystemDefaultDevice(),
              let patches = EDRPatches(edrDevice: device) else {
            throw DisplayFailure("На этом дисплее macOS не сообщает доступный запас EDR.")
        }

        close()
        let frame = edr.screen.visibleFrame
        let width = min(520.0, frame.width - 24)
        let height = min(250.0, frame.height - 24)
        let rect = CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
        let window = NSWindow(contentRect: rect, styleMask: [.titled, .closable], backing: .buffered,
                              defer: false, screen: nil)
        let labels = NSStackView(views: ["SDR · 1×", "HDR · 1,5×", "HDR · 2×"].map {
            let label = NSTextField(labelWithString: $0)
            label.alignment = .center
            return label
        })
        labels.distribution = .fillEqually
        let description = NSTextField(labelWithString: "Максимальный запас EDR по данным macOS: \(Double(edr.potential).formatted(.number.precision(.fractionLength(2))))×")
        description.alignment = .center
        description.textColor = .secondaryLabelColor
        let content = NSView()
        [labels, patches, description].forEach { view in
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
                view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12)
            ])
        }
        NSLayoutConstraint.activate([
            labels.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            patches.topAnchor.constraint(equalTo: labels.bottomAnchor, constant: 8),
            description.topAnchor.constraint(equalTo: patches.bottomAnchor, constant: 8),
            description.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])

        window.title = "HDR · \(display.title)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = content
        // An NSWindow initializer's content rectangle can be screen-relative if a screen is passed.
        window.setFrameOrigin(rect.origin)
        self.window = window
        self.patches = patches
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        content.layoutSubtreeIfNeeded()
        patches.needsDisplay = true
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        patches = nil
    }
}

@MainActor
final class EDRPatches: MTKView {
    private let queue: any MTLCommandQueue
    private let context: CIContext
    private let edrSpace: CGColorSpace
    private(set) var didPresentFrame = false

    init?(edrDevice device: any MTLDevice) {
        guard let queue = device.makeCommandQueue(), let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else { return nil }
        self.queue = queue
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        edrSpace = colorSpace
        super.init(frame: .zero, device: device)
        colorPixelFormat = .rgba16Float
        framebufferOnly = false
        isPaused = true
        enableSetNeedsDisplay = true
        colorspace = colorSpace
        (layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = true
    }

    required init(coder: NSCoder) { fatalError("EDRPatches requires a Metal device") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        (layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let drawable = currentDrawable, let command = queue.makeCommandBuffer() else { return }
        let bounds = CGRect(x: 0, y: 0, width: drawable.texture.width, height: drawable.texture.height)
        let width = bounds.width / 3
        var image = CIImage(color: .black).cropped(to: bounds)
        for (index, brightness) in [CGFloat(1), 1.5, 2].enumerated() {
            let rectangle = CGRect(x: CGFloat(index) * width + 2, y: 0, width: max(0, width - 4), height: bounds.height)
            guard let color = CIColor(red: brightness, green: brightness, blue: brightness,
                                      alpha: 1, colorSpace: edrSpace) else { return }
            image = CIImage(color: color).cropped(to: rectangle).composited(over: image)
        }
        context.render(image, to: drawable.texture, commandBuffer: command, bounds: bounds, colorSpace: edrSpace)
        command.present(drawable)
        command.addCompletedHandler { [weak self] command in
            if command.status == .completed {
                Task { @MainActor [weak self] in self?.didPresentFrame = true }
            }
        }
        command.commit()
    }
}
