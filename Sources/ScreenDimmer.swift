import AppKit
import CoreGraphics
import Observation

/// Black overlay windows that dim individual displays in software.
@MainActor
@Observable
final class ScreenDimmer {
    private(set) var levels: [String: Double] = [:]
    @ObservationIgnored private var windows: [String: NSWindow] = [:]

    func set(_ amount: Double, for identity: String) {
        levels[identity] = min(0.8, max(0, amount))
    }

    func sync(_ screens: [Display]) {
        let ids = Set(screens.filter { (levels[$0.identity] ?? 0) > 0 && $0.mirrors == kCGNullDirectDisplay }.map(\.identity))
        for key in windows.keys.filter({ !ids.contains($0) }) { windows.removeValue(forKey: key)?.orderOut(nil) }
        for display in screens where ids.contains(display.identity) {
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id
            }) else { continue }
            let window = windows[display.identity] ?? makeWindow()
            windows[display.identity] = window
            window.setFrame(screen.frame, display: true)
            window.alphaValue = levels[display.identity] ?? 0
            if !window.isVisible { window.orderFrontRegardless() }
        }
    }

    private func makeWindow() -> NSWindow {
        let overlay = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        overlay.isReleasedWhenClosed = false
        overlay.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
        overlay.backgroundColor = .black
        overlay.ignoresMouseEvents = true
        overlay.hasShadow = false
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        overlay.sharingType = .none
        return overlay
    }
}
