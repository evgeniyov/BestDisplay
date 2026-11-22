import AppKit
import CoreGraphics
@preconcurrency import ColorSync
import SwiftUI

@main
struct BestDisplay {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first?.hasPrefix("--") == true { exit(ProfileCommand.run(arguments)) }

        let delegate = ApplicationDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

private let connectionChanged = Notification.Name("BestDisplayConnectionChanged")
private let displayConnectionCallback: CGDisplayReconfigurationCallBack = { id, flags, _ in
    guard flags.contains(.addFlag) || flags.contains(.removeFlag) else { return }
    let added = flags.contains(.addFlag)
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: connectionChanged, object: nil, userInfo: ["id": id, "added": added])
    }
}

@MainActor
private final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private let manager = DisplayManager()
    private var panel: StatusPanel?
    private var colorObserver: NSObjectProtocol?
    private lazy var livePreview = LivePreview { [weak self] message in
        self?.showPanel()
        self?.manager.message = message
    }
    private var statusItem: NSStatusItem?
    private var notifications: [NSObjectProtocol] = []
    private var didRegisterDisplayCallback = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        manager.start()
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.autosaveName = "BestDisplay"
        status.isVisible = true
        status.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "BestDisplay")
        status.button?.toolTip = "BestDisplay"
        status.button?.setAccessibilityLabel("BestDisplay")
        status.button?.target = self
        status.button?.action = #selector(toggle)
        statusItem = status

        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.manager.scheduleRefresh()
                self?.positionPanel()
            }
        })
        notifications.append(center.addObserver(forName: connectionChanged, object: nil, queue: .main) { [weak self] notification in
            guard let id = notification.userInfo?["id"] as? CGDirectDisplayID,
                  let added = notification.userInfo?["added"] as? Bool else { return }
            MainActor.assumeIsolated { self?.manager.displayConnectionChanged(id, added: added) }
        })
        didRegisterDisplayCallback = CGDisplayRegisterReconfigurationCallback(displayConnectionCallback, nil) == .success
        if let event = kColorSyncDisplayDeviceProfilesNotification?.takeUnretainedValue() as String? {
            colorObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(event), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.manager.scheduleRefresh() }
            }
        }

        let workspace = NSWorkspace.shared.notificationCenter
        notifications.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.manager.scheduleRefresh(wake: true) }
        })
        notifications.append(workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.manager.revertPreview()
                self?.manager.clearMonitor()
                self?.manager.softwareVolume.stop()
            }
        })
        if !UserDefaults.standard.bool(forKey: "hasOpenedPanel") {
            UserDefaults.standard.set(true, forKey: "hasOpenedPanel")
            DispatchQueue.main.async { [weak self] in self?.showPanel() }
        }
    }

    @objc private func toggle() {
        if panel?.isVisible == true {
            panel?.orderOut(nil)
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        manager.refresh()
        if panel == nil {
            let newPanel = StatusPanel(contentRect: CGRect(x: 0, y: 0, width: 494, height: 616),
                                       styleMask: [.borderless], backing: .buffered, defer: false)
            newPanel.title = "BestDisplay"
            newPanel.isReleasedWhenClosed = false
            newPanel.isMovable = false
            newPanel.hidesOnDeactivate = false
            newPanel.level = .floating
            newPanel.hasShadow = true
            newPanel.backgroundColor = .windowBackgroundColor
            newPanel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
            let hosting = NSHostingController(rootView: DisplayPanel(manager: manager, dismiss: { [weak self] in
                self?.panel?.orderOut(nil)
            }, startLivePreview: { [weak self] in
                self?.livePreview.chooseSource()
            }))
            hosting.sizingOptions = []
            newPanel.contentViewController = hosting
            panel = newPanel
        }
        positionPanel(showing: true)
        NSApp.activate()
        panel?.makeKeyAndOrderFront(nil)
    }

    private func positionPanel(showing: Bool = false) {
        guard let panel, showing || panel.isVisible else { return }
        var anchor: CGRect?
        if let button = statusItem?.button, let window = button.window {
            anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        let screens = NSScreen.screens
        let anchoredScreen = anchor.flatMap { button in
            screens.first {
                $0.frame.insetBy(dx: -1, dy: -1).contains(CGPoint(x: button.midX, y: button.midY))
                    && abs($0.frame.maxY - button.maxY) <= 60
            }
        }
        let selectedScreen = anchoredScreen ?? screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = selectedScreen?.visibleFrame else { return }
        let size = CGSize(width: min(494, visible.width - 16), height: min(616, visible.height - 16))
        let rightEdge = (anchoredScreen == nil ? nil : anchor?.maxX) ?? visible.maxX
        let x = min(visible.maxX - size.width - 8, max(visible.minX + 8, rightEdge - size.width))
        let y = visible.maxY - size.height - 8
        panel.setFrame(CGRect(origin: CGPoint(x: x, y: y), size: size), display: true)
    }

    func applicationDidResignActive(_ notification: Notification) {
        if manager.preview == nil { panel?.orderOut(nil) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let name = urls.compactMap(ProfileCommand.readName).first else { return }
        showPanel()
        guard let profile = manager.currentProfile, profile.name == name else {
            manager.message = "Подключи дисплеи сохранённого профиля «\(name)»."
            return
        }
        manager.tryProfile(profile.id)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard manager.preview != nil || manager.isChangingTopology else { return .terminateNow }
        manager.revertPreview()
        guard manager.isChangingTopology else { return .terminateNow }
        Task {
            for _ in 0..<50 where manager.isChangingTopology {
                try? await Task.sleep(for: .milliseconds(100))
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.revertPreview()
        manager.restoreCalibrationsBeforeQuit()
        manager.softwareVolume.stop()
        manager.edrPreview.close()
        manager.reconnectBeforeQuit()
        livePreview.stop()
        if let colorObserver { DistributedNotificationCenter.default().removeObserver(colorObserver) }
        if didRegisterDisplayCallback {
            CGDisplayRemoveReconfigurationCallback(displayConnectionCallback, nil)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for token in notifications {
            NotificationCenter.default.removeObserver(token)
            workspace.removeObserver(token)
        }
    }
}
