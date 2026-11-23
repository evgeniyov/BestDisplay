import AppKit
import CoreGraphics
import Observation
import ServiceManagement

private struct DisplayState {
    let identity: String
    let id: CGDirectDisplayID
    let mode: ScreenMode
    let origin: CGPoint
    let observation: DisplayObservation
    let color: DisplayColor?

    init(_ display: Display) {
        identity = display.identity
        id = display.id
        mode = display.current
        origin = display.bounds.origin
        observation = DisplayObservation(display)
        color = display.color
    }
}

private func onlineDisplayIdentities(_ ids: [CGDirectDisplayID]) -> [(id: CGDirectDisplayID, identity: String)] {
    ids.map { ($0, displayIdentity($0, among: ids) ?? "session-\($0)") }
}

private struct DisconnectState {
    let display: Display
    let previous: [DisplayState]
}

private struct MirrorChange {
    let source: CGDirectDisplayID
    let target: CGDirectDisplayID

    var isApplied: Bool { CGDisplayMirrorsDisplay(target) == source }

    @MainActor func undo() throws {
        let mirrored: CGDirectDisplayID
        if isApplied {
            mirrored = target
        } else if CGDisplayMirrorsDisplay(source) == target {
            mirrored = source
        } else {
            return
        }
        try configureDisplays { config in
            try checkDisplayError(CGConfigureDisplayMirrorOfDisplay(config, mirrored, kCGNullDirectDisplay))
        }
    }
}

private struct RotationChange {
    let id: CGDirectDisplayID
    let identity: String
    let previous: DisplayOrientation
    let requested: DisplayOrientation

    var isApplied: Bool { displayIdentity(id) == identity && DisplayOrientation.current(id) == requested }
}

struct DisplayPreview {
    let title: String
    fileprivate let previous: [DisplayState]
    fileprivate let expectedModes: [String: ModeKey]
    fileprivate let expectedOrigins: [String: CGPoint]
    fileprivate let expectedMain: CGDirectDisplayID?
    fileprivate let profile: DisplayProfile?
    fileprivate let mirror: MirrorChange?
    fileprivate let rotation: RotationChange?
    fileprivate let deadline: TimeInterval
}

private extension DisplayObservation {
    init(_ display: Display) {
        self.init(displayID: display.id, name: display.title, mode: display.current.key)
    }
}

private struct LiveVirtualDisplay {
    let id: CGDirectDisplayID
    // CoreGraphics removes the display when this object is released.
    let handle: NSObject
}

@MainActor
@Observable
final class DisplayManager {
    private(set) var screens = [Display]()
    var selectedID: CGDirectDisplayID?
    var message: String?
    private(set) var preview: DisplayPreview?
    private(set) var secondsLeft = 0
    private var rememberedSettings = RememberedDisplaySettings()
    var remembered: [String: ModeKey] { rememberedSettings.modes }
    private var rememberedHDR: [String: Bool] { rememberedSettings.hdr }
    private(set) var profiles: [DisplayProfile] = []
    private(set) var history: [DisplayHistoryEntry] = []
    var monitorValues: [MonitorControl: ControlValue] = [:]
    var hasDDCBrightness = false
    var isReadingMonitor = false
    var isWritingMonitor = false
    private(set) var isChangingVirtual = false
    private(set) var isReconnecting = false
    private var softwareDisconnect: DisconnectState?
    private let dimmer = ScreenDimmer()
    private(set) var launchAtLogin = false
    private var launched = false
    private var knownDisplays: [String: DisplayObservation] = [:]
    private var wakeStarted: TimeInterval?
    private var knownPhysicalIDs = Set<CGDirectDisplayID>()
    private var pendingRestore: PendingDisplayRestore?
    private var verification = DisplayVerificationWindow()
    private var layoutVerificationDeadline: TimeInterval?
    private var lastObservedLayout: DisplayLayout?
    private var layoutRestoreSuppressed = false
    private var failedHDRRestores = Set<String>()
    private var lastDisplayNames: [String: String] = [:]
    private var nextProtectionCheck: TimeInterval = 0
    private var nextTopologyAttempt: TimeInterval = 0
    private var lastProtectionTopology: DisplayTopology?
    private var topologyProtectionFailed = false
    private var failedProfileProtection: UUID?
    private(set) var isChangingTopology = false
    private var actualTopology: DisplayTopology?
    private var protectedTopologies: [DisplayTopology] = []
    private var rememberedLayouts: [DisplayLayout] = []
    private(set) var calibrations: [String: Calibration] = [:]
    @ObservationIgnored private var calibrationTables: [String: (base: TransferTables, applied: TransferTables)] = [:]
    private var reconnected = Set<CGDirectDisplayID>()
    private var disconnected = Set<CGDirectDisplayID>()
    private var virtualDisplay: LiveVirtualDisplay?
    private var retiredVirtualIDs = Set<CGDirectDisplayID>()
    private var isChangingDisplaySettings = false
    let monitorControls = MonitorControls()
    let softwareVolume = SoftwareVolume()
    let edrPreview = EDRPreview()
    private var hdrTuning: HDRTuning?
    private(set) var hdrModes: [CGDirectDisplayID: Bool] = [:]
    let storage: UserDefaults
    private let rememberedKey = "preferredDisplayModes"
    private let rememberedHDRKey = "preferredDisplayHDR"
    private static let panelOverridesKey = "displayPanelSizeOverrides"
    private var panelOverrides: [String: Dimensions]
    private let profilesKey = "displayProfiles"
    private let historyKey = "displayHistory"
    private let topologyKey = "protectedDisplayTopologies"
    private let layoutsKey = "rememberedDisplayLayouts"
    private let migratedHardwareIDsKey = "migratedDisplayHardwareIdentities"
    let brightnessGroupKey = "brightnessGroup"
    var brightnessGroup = Set<String>()
    private static let historyLimit = 100
    private static let virtualSerial: UInt32 = 0x4244_0001
    var monitorScanNumber = 0
    @ObservationIgnored private var previewTimer: Timer?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var recheckTask: Task<Void, Never>?
    @ObservationIgnored private var persistedModes: [String: ModeKey] = [:]
    private var recheckDeadline: TimeInterval?

    private var isConfiguringDisplays: Bool {
        isChangingVirtual || isChangingTopology || isReconnecting || isChangingDisplaySettings
    }

    var canChangeDisplayConfiguration: Bool { preview == nil && !isConfiguringDisplays }
    var isTuningHDR: Bool { hdrTuning != nil }

    var selected: Display? { screens.first { $0.id == selectedID } }
    var virtualID: CGDirectDisplayID? { virtualDisplay?.id }
    var disconnectedDisplayName: String? { softwareDisconnect?.display.title }

    var canProtectTopology: Bool { actualTopology != nil }

    var protectedTopology: DisplayTopology? {
        protectedTopologies.first { $0.identities == actualTopology?.identities }
    }

    var protectsCurrentTopology: Bool { protectedTopology != nil }

    var canCaptureProfile: Bool {
        virtualID == nil && DisplayProfile.canCapture(screens)
            && Set(onlineDisplayIDs()) == Set(screens.map(\.id))
    }
    var currentProfile: DisplayProfile? {
        guard canCaptureProfile else { return nil }
        return DisplayProfile.current(in: profiles, displayIDs: Set(screens.map(\.identity)))
    }

    private var currentLayout: DisplayLayout? {
        guard canCaptureProfile, let main = screens.first(where: \.isMain) else { return nil }
        return DisplayLayout(main: main.identity,
                             origins: Dictionary(uniqueKeysWithValues: screens.map { ($0.identity, $0.bounds.origin) }))
    }

    private func rememberedLayout(for layout: DisplayLayout) -> DisplayLayout? {
        rememberedLayouts.last { $0.identities == layout.identities }
    }

    var remembersCurrentLayout: Bool {
        currentLayout.flatMap(rememberedLayout(for:)) != nil
    }

    func forgetCurrentLayout() {
        guard canChangeDisplayConfiguration, let current = currentLayout else { return }
        rememberedLayouts.removeAll { $0.identities == current.identities }
        persist(rememberedLayouts, for: layoutsKey)
        lastObservedLayout = current
    }

    private func rememberLayout(_ layout: DisplayLayout) {
        guard rememberedLayout(for: layout) != layout else { return }
        rememberedLayouts.removeAll { $0.identities == layout.identities }
        rememberedLayouts.append(layout)
        persist(rememberedLayouts, for: layoutsKey)
    }

    init(storage: UserDefaults = .standard) {
        self.storage = storage
        panelOverrides = Self.storedPanelSizes(in: storage)
        brightnessGroup = Set(storage.stringArray(forKey: brightnessGroupKey) ?? [])
        if let data = storage.data(forKey: topologyKey),
           let stored = try? JSONDecoder().decode([DisplayTopology].self, from: data) {
            protectedTopologies = stored
        }
        if let data = storage.data(forKey: layoutsKey),
           let stored = try? JSONDecoder().decode([DisplayLayout].self, from: data) {
            rememberedLayouts = stored
        }
        if let encoded = storage.data(forKey: rememberedKey),
           let stored = try? JSONDecoder().decode([String: ModeKey].self, from: encoded) {
            rememberedSettings.modes = stored
        }
        if let encoded = storage.data(forKey: rememberedHDRKey),
           let stored = try? JSONDecoder().decode([String: Bool].self, from: encoded) {
            rememberedSettings.hdr = stored
        }
        if let encoded = storage.data(forKey: profilesKey),
           let stored = try? JSONDecoder().decode([DisplayProfile].self, from: encoded) {
            profiles = stored
        }
        if let encoded = storage.data(forKey: historyKey),
           let stored = try? JSONDecoder().decode([DisplayHistoryEntry].self, from: encoded) {
            history = Array(stored.prefix(Self.historyLimit))
        }
    }

    func start() {
        refresh()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        scheduleRefresh()
    }

    func scheduleRefresh(wake: Bool = false) {
        if wake && wakeStarted == nil { wakeStarted = ProcessInfo.processInfo.systemUptime }
        guard !isConfiguringDisplays else { return }
        debounceRefresh(for: .milliseconds(800))
    }

    private func debounceRefresh(for delay: Duration) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.refreshTask = nil
            await self?.refreshAfterChange()
        }
    }

    func displayConnectionChanged(_ id: CGDirectDisplayID, added: Bool) {
        if id == virtualID { return }
        if retiredVirtualIDs.contains(id) {
            guard added, CGDisplayIsOnline(id) != 0,
                  CGDisplayVendorNumber(id) != 0x4244 || CGDisplayModelNumber(id) != 1
                    || CGDisplaySerialNumber(id) != Self.virtualSerial else { return }
            retiredVirtualIDs.remove(id)
        }
        if added {
            reconnected.insert(id)
        } else {
            reconnected.remove(id)
            disconnected.insert(id)
            if let hdrTuning, hdrTuning.display.id == id {
                hdrTuning.disconnected = true
                edrPreview.close()
            }
        }
        if selectedID == id { clearMonitor() }
        scheduleRefresh()
    }

    func refresh() {
        let previousIdentity = selected?.identity
        let onlineIDs = onlineDisplayIDs()
        screens = displays(among: onlineIDs, panelOverrides: panelOverrides)
        refreshHDRModes()
        for display in screens {
            if let name = DisplayHistoryEntry.Screen.knownName(display.title) {
                lastDisplayNames[display.identity] = name
            }
        }
        migrateDisplaySettings(onlineIDs)
        actualTopology = virtualID == nil ? DisplayTopology.read(among: screens) : nil
        if let actualTopology, actualTopology.orientations.isEmpty && actualTopology.identities.count < 2 {
            self.actualTopology = nil
        }
        if let previousIdentity, let sameDisplay = screens.first(where: { $0.identity == previousIdentity }) {
            selectedID = sameDisplay.id
        } else {
            selectedID = screens.first(where: \.isMain)?.id ?? screens.first?.id
        }
        if selected?.identity != previousIdentity {
            clearMonitor()
        }
        if let currentPreview = preview {
            let sameDisplays = if currentPreview.mirror != nil {
                Set(onlineDisplayIDs()) == Set(currentPreview.previous.map(\.id))
            } else {
                Set(currentPreview.previous.map(\.identity))
                    == Set(screens.filter { $0.mirrors == kCGNullDirectDisplay }.map(\.identity))
            }
            if !sameDisplays { revertPreview(reason: "Набор дисплеев изменился.") }
        }
        dimmer.sync(screens)
    }

    private func migrateDisplaySettings(_ onlineIDs: [CGDirectDisplayID]) {
        let migratedHardwareIDs = Set(storage.stringArray(forKey: migratedHardwareIDsKey) ?? [])
        func canMigrate(_ display: Display) -> Bool {
            display.identity.hasPrefix("hw-") && !migratedHardwareIDs.contains(display.identity)
                && DisplayHistoryEntry.Screen.knownName(display.title) != nil
        }
        let byID = Dictionary(uniqueKeysWithValues: screens.map { ($0.id, $0) })
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        let online = onlineIDs.map { id in
            let display = byID[id]
            var modes = Set<ModeKey>()
            // The live model includes the current mode even before macOS can enumerate the catalog.
            if let display, canMigrate(display),
               let catalog = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode], !catalog.isEmpty {
                modes = Set(catalog.filter { $0.isUsableForDesktopGUI() }.map(ModeKey.init))
                modes.formUnion(display.modes.map(\.key))
            }
            return DisplayIdentityMigration.OnlineDisplay(
                identity: display?.identity ?? displayIdentity(id, among: onlineIDs) ?? "session-\(id)",
                legacyUUID: legacyDisplayIdentity(id), name: display?.title, modes: modes)
        }
        let stored = DisplayIdentityMigration(remembered: remembered, rememberedHDR: rememberedHDR, profiles: profiles,
                                              topologies: protectedTopologies, layouts: rememberedLayouts,
                                              brightnessGroup: brightnessGroup,
                                              migratedHardwareIDs: migratedHardwareIDs)
        let migrated = stored.migrated(online: online, history: history)
        if migrated.remembered != remembered {
            rememberedSettings.modes = migrated.remembered
            persist(remembered, for: rememberedKey)
        }
        if migrated.rememberedHDR != rememberedHDR {
            rememberedSettings.hdr = migrated.rememberedHDR
            persist(rememberedHDR, for: rememberedHDRKey)
        }
        if migrated.profiles != profiles {
            profiles = migrated.profiles
            persist(profiles, for: profilesKey)
        }
        if migrated.topologies != protectedTopologies {
            protectedTopologies = migrated.topologies
            persist(protectedTopologies, for: topologyKey)
        }
        if migrated.layouts != rememberedLayouts {
            rememberedLayouts = migrated.layouts
            persist(rememberedLayouts, for: layoutsKey)
        }
        if migrated.brightnessGroup != brightnessGroup {
            brightnessGroup = migrated.brightnessGroup
            storage.set(brightnessGroup.sorted(), forKey: brightnessGroupKey)
        }
        if migrated.migratedHardwareIDs != stored.migratedHardwareIDs {
            storage.set(migrated.migratedHardwareIDs.sorted(), forKey: migratedHardwareIDsKey)
        }
    }

    private func cancelVerification() {
        verification.cancel()
        // Keep the layout deadline so automatic changes still cannot become the saved layout.
        layoutRestoreSuppressed = true
        lastObservedLayout = nil
    }

    private func scheduleRecheck(at deadline: TimeInterval) {
        if let recheckDeadline, recheckDeadline <= deadline { return }
        recheckTask?.cancel()
        recheckDeadline = deadline
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        recheckTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.recheckDeadline = nil
            self?.recheckTask = nil
            await self?.refreshAfterChange()
        }
    }

    private func refreshAfterChange() async {
        guard !isConfiguringDisplays else { return }
        refresh()
        await processDisplayChanges()
    }

    private func collectDisplayEvents(among displays: [Display], now: TimeInterval)
        -> (before: [String: DisplayObservation], online: Set<String>) {
        let ownVirtualIDs = retiredVirtualIDs.union([virtualID].compactMap { $0 })
        let ids = onlineDisplayIDs()
        let online = Set(ids).subtracting(ownVirtualIDs)
        let physical = onlineDisplayIdentities(ids).filter { online.contains($0.id) }
        let identities = Set(physical.map(\.identity))
        let observed = observations(among: displays.filter { !ownVirtualIDs.contains($0.id) })
        let before = observed.merging(knownDisplays) { current, _ in current }
        guard launched || !online.isEmpty else { return (before, identities) }

        let added = online.subtracting(knownPhysicalIDs).union(reconnected)
        let missing = knownPhysicalIDs.subtracting(online)
        let removed = missing.union(disconnected)
        let available = Set(observed.values.map(\.displayID))
        var triggers = Set<DisplayHistoryEntry.Trigger>()
        if !launched { triggers.insert(.launch) }
        if wakeStarted != nil { triggers.insert(.wake) }
        if launched && !added.isEmpty { triggers.insert(.attached) }
        if !removed.isEmpty { triggers.insert(.detached) }

        if !triggers.isEmpty || actualTopology != lastProtectionTopology {
            topologyProtectionFailed = false
            failedProfileProtection = nil
        }
        lastProtectionTopology = actualTopology

        if !triggers.isEmpty {
            lastObservedLayout = nil
            layoutVerificationDeadline = nil
            if !triggers.isDisjoint(with: [.launch, .wake, .attached]) {
                layoutRestoreSuppressed = false
            }
            var pending = pendingRestore ?? PendingDisplayRestore()
            var targets = !launched || wakeStarted != nil
                ? identities : Set(physical.lazy.filter { added.contains($0.id) }.map(\.identity))
            if wakeStarted != nil {
                targets.formUnion(knownDisplays.filter {
                    missing.contains($0.value.displayID) && !disconnected.contains($0.value.displayID)
                }.keys)
            }
            failedHDRRestores.subtract(targets)
            pending.targets.formUnion(targets)
            pending.triggers.formUnion(triggers)
            pending.before.merge(before) { original, _ in original }
            if pending.waitUntil == 0, !pending.targets.isSubset(of: Set(observed.keys).intersection(identities)) {
                pending.waitUntil = (wakeStarted ?? now) + 3.5
            }
            pendingRestore = pending
        }

        knownDisplays = observed.merging(knownDisplays.filter {
            online.contains($0.value.displayID) && !available.contains($0.value.displayID)
        }) { current, _ in current }
        knownPhysicalIDs = online
        reconnected.removeAll()
        disconnected.removeAll()
        wakeStarted = nil
        launched = true
        return (before, identities)
    }

    private func processDisplayChanges() async {
        guard !isConfiguringDisplays else { return }
        recheckTask?.cancel()
        recheckTask = nil
        recheckDeadline = nil
        let now = ProcessInfo.processInfo.systemUptime
        let (before, online) = collectDisplayEvents(among: screens, now: now)
        guard preview == nil else { return }

        if !topologyProtectionFailed, let protectedTopology, actualTopology != protectedTopology {
            if now >= nextTopologyAttempt {
                lastObservedLayout = nil
                restoreProtectedTopology(protectedTopology, before: before)
                return
            }
            scheduleRecheck(at: nextTopologyAttempt)
        }

        let layoutBeforeRestore = currentLayout
        let (restored, restoreTriggers) = await restorePendingDisplays(online: online, now: now)
        await verifyDisplayModes(now: ProcessInfo.processInfo.systemUptime, excluding: restored)
        guard pendingRestore == nil, wakeStarted == nil, reconnected.isEmpty, disconnected.isEmpty else {
            lastObservedLayout = nil
            return
        }
        let layout = currentLayout
        let isVerifyingLayout = layoutVerificationDeadline != nil || verification.deadline != nil
        if let deadline = layoutVerificationDeadline {
            if let layout {
                restoreRememberedLayout(over: layout, triggers: restoreTriggers)
            }
            if ProcessInfo.processInfo.systemUptime < deadline {
                scheduleRecheck(at: deadline)
            } else {
                layoutVerificationDeadline = nil
            }
        }
        if let layout, layout == layoutBeforeRestore,
           layout.shouldLearn(after: lastObservedLayout, isVerifying: isVerifyingLayout) {
            rememberLayout(layout)
        }
        lastObservedLayout = currentLayout
    }

    private func restoreRememberedLayout(over current: DisplayLayout, triggers: [DisplayHistoryEntry.Trigger]) {
        let profile = currentProfile
        let profileTakesPriority = profile?.automaticallyApplies == true || profile?.protectsConfiguration == true
        guard let layout = rememberedLayout(for: current),
              layout.shouldRestore(over: current, profileTakesPriority: profileTakesPriority,
                                   suppressed: layoutRestoreSuppressed) else { return }
        let before = observations()
        let result: String
        do {
            let previous = screens.map(DisplayState.init)
            try applyConfiguration(previous, restoreLayout: true, operation: { config in
                let online = onlineDisplayIDs()
                guard Set(online) == Set(previous.map(\.id)) else {
                    throw DisplayFailure("Набор дисплеев изменился.")
                }
                for display in previous {
                    guard displayIdentity(display.id, among: online) == display.identity,
                          let origin = layout.origins[display.identity],
                          (origin == .zero) == (display.identity == layout.main) else {
                        throw DisplayFailure("Не удалось применить сохранённое расположение.")
                    }
                    try setOrigin(config, display.id, origin)
                }
            }, verify: { observed in
                currentLayout == layout && observed.allSatisfy { $0.bounds.origin == layout.origins[$0.identity] }
            })
            result = "Восстановлен основной дисплей и расположение."
        } catch {
            layoutRestoreSuppressed = true
            result = "Не удалось восстановить расположение. \(error.localizedDescription)"
            message = result
        }
        addHistory(triggers, before: before, result: result)
    }

    private func restoreProtectedTopology(_ topology: DisplayTopology, before: [String: DisplayObservation]) {
        isChangingTopology = true
        let previous = screens
        Task {
            let failure: String?
            do {
                try await topology.apply(among: previous)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            refresh()
            topologyProtectionFailed = failure != nil || actualTopology != topology
            if topologyProtectionFailed { lastProtectionTopology = actualTopology }
            let result = failure ?? (actualTopology == topology
                ? "Поворот и видеоповтор восстановлены."
                : "macOS не подтвердила восстановление поворота и видеоповтора.")
            addHistory([.protection], before: before, result: result)
            nextTopologyAttempt = ProcessInfo.processInfo.systemUptime + 5
            isChangingTopology = false
            await processDisplayChanges()
        }
    }

    private func restorePendingDisplays(online: Set<String>, now: TimeInterval) async
        -> (Set<String>, [DisplayHistoryEntry.Trigger]) {
        guard var pending = pendingRestore else { return ([], [.verification]) }
        let available = Set(screens.filter { knownPhysicalIDs.contains($0.id) }.map(\.identity))
        let candidates: Set<String>
        switch pending.takeReady(online: online, available: available, at: now) {
        case .waiting(let deadline):
            pendingRestore = pending
            if let deadline { scheduleRecheck(at: deadline) }
            return ([], [.verification])
        case .ready(let ready):
            candidates = ready
        }
        pendingRestore = nil
        let triggers = DisplayHistoryEntry.Trigger.allCases.filter(pending.triggers.contains)
        let restored: Set<String>
        if pending.targets.isEmpty, pending.allowsProfile, let profile = currentProfile, profile.automaticallyApplies,
           failedProfileProtection != profile.id {
            await restoreProfile(profile, triggers: triggers, before: pending.before, hdrCandidates: candidates)
            restored = profile.displayIDs
        } else {
            await restoreRememberedModes(candidates, triggers: triggers, before: pending.before)
            restored = candidates
        }
        if !pending.targets.isEmpty {
            pending.before = observations()
            pendingRestore = pending
        }
        if !pending.triggers.isDisjoint(with: [.launch, .wake, .attached]) {
            let now = ProcessInfo.processInfo.systemUptime
            verification.start(for: restored, now: now, allowsProfile: pending.allowsProfile)
            if pending.targets.isEmpty { layoutVerificationDeadline = now + DisplayVerificationWindow.duration }
        }
        return (restored, triggers)
    }

    private func verifyDisplayModes(now: TimeInterval, excluding restored: Set<String>) async {
        let candidates = verification.identities.subtracting(restored)
        let profileCandidates = verification.profileIdentities.subtracting(restored)
        verification.expire(at: now)
        if let deadline = verification.deadline { scheduleRecheck(at: deadline) }
        if let profile = currentProfile {
            if !candidates.isEmpty, profile.automaticallyApplies, profile.displayIDs.isSubset(of: profileCandidates),
               failedProfileProtection != profile.id,
               profile.protectsConfiguration != true || now >= nextProtectionCheck {
                await restoreProfile(profile, triggers: [.verification], before: observations(), hdrCandidates: candidates)
                return
            }
            if profile.protectsConfiguration == true {
                let before = observations()
                if failedProfileProtection != profile.id, !profile.isApplied(to: screens) {
                    if now >= nextProtectionCheck {
                        await restoreProfile(profile, triggers: [.protection], before: before, hdrCandidates: candidates)
                        return
                    }
                    scheduleRecheck(at: nextProtectionCheck)
                }
                let hdrResults = await restoreHDR(candidates)
                if !hdrResults.isEmpty {
                    addHistory([.verification], before: before, result: hdrResults.joined(separator: " "))
                }
                return
            }
        }
        guard !candidates.isEmpty else { return }
        await restoreRememberedModes(candidates, triggers: [.verification], before: observations())
    }

    private func restoreRememberedModes(
        _ candidates: Set<String>, triggers: [DisplayHistoryEntry.Trigger], before: [String: DisplayObservation]
    ) async {
        let requested = remembered.filter { candidates.contains($0.key) }
        var unavailable: [String] = []
        let changes: [(Display, ScreenMode)] = screens.compactMap { display in
            guard let saved = requested[display.identity], display.current.key != saved else { return nil }
            guard !display.isInMirrorSet,
                  let mode = display.modes.first(where: { $0.key == saved }) else {
                unavailable.append(display.title)
                return nil
            }
            return (display, mode)
        }
        var corrected = false
        var result = requested.isEmpty ? "Использованы текущие настройки macOS." : "Сохранённые режимы уже активны."
        if !changes.isEmpty {
            let previous = screens.filter { $0.mirrors == kCGNullDirectDisplay }.map(DisplayState.init)
            do {
                try applyConfiguration(previous, restoreLayout: false, operation: { config in
                    for (display, mode) in changes {
                        try setMode(config, display: display.id, mode: mode)
                    }
                }, verify: { observed in
                    changes.allSatisfy { original, expected in
                        observed.contains { $0.identity == original.identity && $0.current.key == expected.key }
                    }
                })
                corrected = true
                result = "Сохранённые режимы восстановлены."
            } catch {
                result = error.localizedDescription
                message = result
            }
        }
        if !unavailable.isEmpty {
            let warning = "Сохранённый режим недоступен для следующих дисплеев: \(unavailable.joined(separator: ", "))."
            message = warning
            result = changes.isEmpty ? warning : "\(result) \(warning)"
        }
        for display in screens where requested[display.identity] == display.current.key {
            persistActiveMode(of: display)
        }
        let hdrResults = await restoreHDR(candidates)
        if corrected || !hdrResults.isEmpty || triggers != [.verification] {
            let results = requested.isEmpty && !hdrResults.isEmpty ? hdrResults : [result] + hdrResults
            addHistory(triggers, before: before, requested: requested,
                       result: results.joined(separator: " "))
        }
    }

    private func restoreHDR(_ candidates: Set<String>) async -> [String] {
        guard canChangeDisplayConfiguration else { return [] }
        var results: [String] = []
        defer {
            if !results.isEmpty {
                refresh()
                isChangingDisplaySettings = false
                scheduleRefresh()
            }
        }
        for display in screens where candidates.contains(display.identity)
            && rememberedHDR[display.identity] != nil && !failedHDRRestores.contains(display.identity) {
            guard let desired = rememberedSettings.hdrChange(for: display.identity,
                                                            current: DisplayHDRMode.status(for: display)) else { continue }
            isChangingDisplaySettings = true
            let result: String
            do {
                try await DisplayHDRMode.set(desired, on: display)
                result = desired ? "HDR включён." : "HDR выключен."
            } catch {
                failedHDRRestores.insert(display.identity)
                result = error.localizedDescription
            }
            results.append("«\(display.title)»: \(result)")
        }
        return results
    }

    private func persistActiveMode(of display: Display) {
        let systemID = legacyDisplayIdentity(display.id) ?? display.identity
        guard persistedModes[systemID] != display.current.key, display.currentModeIsPublic,
              !display.isVirtual, display.id != virtualID, !display.isInMirrorSet else { return }
        persistedModes[systemID] = display.current.key
        try? configureDisplays(option: .permanently) { config in
            try setMode(config, display: display.id, mode: display.current)
        }
    }

    private func observations() -> [String: DisplayObservation] { observations(among: screens) }

    private func observations(among displays: [Display]) -> [String: DisplayObservation] {
        Dictionary(displays.map { ($0.identity, DisplayObservation($0)) }, uniquingKeysWith: { first, _ in first })
    }

    private func lastName(for identity: String) -> String? {
        lastDisplayNames[identity] ?? history.lazy.flatMap(\.screens)
            .first { $0.id == identity && DisplayHistoryEntry.Screen.knownName($0.name) != nil }?.name
    }

    func historyDisplayName(for screen: DisplayHistoryEntry.Screen) -> String {
        DisplayHistoryEntry.Screen.displayName(screen.name, lastKnown: lastName(for: screen.id), displayID: screen.id)
    }

    private func addHistory(
        _ triggers: [DisplayHistoryEntry.Trigger], profileName: String? = nil,
        before: [String: DisplayObservation], requested: [String: ModeKey] = [:], result: String
    ) {
        let after = observations()
        let rows = Set(before.keys).union(after.keys).compactMap { id -> DisplayHistoryEntry.Screen? in
            guard let display = after[id] ?? before[id] else { return nil }
            let displayID = String(display.displayID)
            let lastKnown = lastName(for: id) ?? before[id].flatMap {
                DisplayHistoryEntry.Screen.knownName($0.name)
            }
            let name = DisplayHistoryEntry.Screen.displayName(display.name, lastKnown: lastKnown, displayID: displayID)
            return DisplayHistoryEntry.Screen(id: id, name: name, before: before[id]?.mode,
                                              requested: requested[id], after: after[id]?.mode)
        }.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let event = DisplayHistoryEntry(id: UUID(), date: Date(), triggers: triggers, profileName: profileName,
                                       result: result, screens: rows)
        history = [event] + Array(history.prefix(Self.historyLimit - 1))
        persist(history, for: historyKey)
    }

    func clearHistory() {
        history = []
        storage.removeObject(forKey: historyKey)
    }

    private func persist(_ value: some Encodable, for key: String) {
        if let data = try? JSONEncoder().encode(value) { storage.set(data, forKey: key) }
    }

    static func storedPanelSizes(in storage: UserDefaults = .standard) -> [String: Dimensions] {
        guard let data = storage.data(forKey: panelOverridesKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Dimensions].self, from: data)) ?? [:]
    }

    func setPanelSize(_ size: Dimensions?, for identity: String) {
        guard let index = screens.firstIndex(where: { $0.identity == identity }),
              !screens[index].panelSizeOptions.isEmpty else { return }
        if let size, !screens[index].panelSizeOptions.contains(size) { return }
        screens[index].panelOverride = size
        guard !identity.hasPrefix("session-") else { return }
        panelOverrides[identity] = size?.rotated(ifQuarterTurn: screens[index].panelIsRotated)
        persist(panelOverrides, for: Self.panelOverridesKey)
    }

    func saveProfile(named input: String) {
        guard canChangeDisplayConfiguration else { return }
        refresh()
        guard canCaptureProfile else {
            message = "Для сохранения профиля используй физические дисплеи с отдельными рабочими столами."
            return
        }
        let name = String(input.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !name.isEmpty else { return }
        let saved = currentProfile
        let profile = DisplayProfile(id: saved?.id ?? UUID(), name: name,
                                     automaticallyApplies: saved?.automaticallyApplies ?? true,
                                     protectsConfiguration: saved?.protectsConfiguration,
                                     screens: screens.sorted { $0.isMain && !$1.isMain }.map(DisplayProfile.Screen.init))
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        persist(profiles, for: profilesKey)
        message = "Профиль «\(name)» сохранён."
    }

    func setProfileAutomatic(_ id: UUID, enabled: Bool) {
        guard canChangeDisplayConfiguration, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].automaticallyApplies = enabled
        persist(profiles, for: profilesKey)
    }

    func setProfileProtection(_ id: UUID, enabled: Bool) {
        guard canChangeDisplayConfiguration, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].protectsConfiguration = enabled
        if failedProfileProtection == id { failedProfileProtection = nil }
        persist(profiles, for: profilesKey)
    }

    func setColorProfile(_ color: DisplayColor, for id: CGDirectDisplayID) {
        guard canChangeDisplayConfiguration, let display = screens.first(where: { $0.id == id }) else { return }
        cancelVerification()
        do {
            try color.validate()
            try resetCalibration(for: display)
            try color.apply(to: display)
            refresh()
            updateProtectedProfile()
            message = "Профиль «\(color.title)» применён."
        } catch {
            message = error.localizedDescription
        }
    }

    func applyCalibration(_ settings: Calibration, to display: Display) {
        guard canChangeDisplayConfiguration, displayIdentity(display.id) == display.identity else { return }
        cancelVerification()
        do {
            let current = try TransferTables.read(display.id)
            let base = calibrationTables[display.identity].flatMap { current.matches($0.applied) ? $0.base : nil } ?? current
            let requested = settings.apply(to: base)
            do {
                try requested.write(display.id)
                guard try TransferTables.read(display.id).matches(requested) else {
                    throw DisplayFailure("macOS не подтвердила ручные настройки цвета.")
                }
            } catch {
                try? current.write(display.id)
                throw error
            }
            calibrationTables[display.identity] = (base, requested)
            calibrations[display.identity] = settings
            message = "Настройки цвета рабочего стола применены."
        } catch {
            message = error.localizedDescription
        }
    }

    func removeCalibration(from display: Display) {
        guard canChangeDisplayConfiguration else { return }
        cancelVerification()
        do {
            try resetCalibration(for: display)
            message = "Ручные настройки цвета рабочего стола отключены."
        } catch {
            message = error.localizedDescription
        }
    }

    private func resetCalibration(for display: Display) throws {
        guard let previous = calibrationTables[display.identity] else { return }
        if CGDisplayIsOnline(display.id) != 0, displayIdentity(display.id) == display.identity,
           try TransferTables.read(display.id).matches(previous.applied) {
            try previous.base.write(display.id)
        }
        calibrations[display.identity] = nil
        calibrationTables[display.identity] = nil
    }

    func restoreCalibrationsBeforeQuit() {
        for display in screens { try? resetCalibration(for: display) }
    }

    func setTopologyProtection(_ enabled: Bool) {
        guard canChangeDisplayConfiguration else { return }
        guard let actual = actualTopology else { return }
        protectedTopologies.removeAll { $0.identities == actual.identities }
        if enabled { protectedTopologies.append(actual) }
        nextTopologyAttempt = 0
        topologyProtectionFailed = false
        persist(protectedTopologies, for: topologyKey)
    }

    private func updateProtectedTopology() {
        if protectsCurrentTopology { setTopologyProtection(true) }
    }

    private func updateProtectedProfile() {
        guard let matching = currentProfile, matching.protectsConfiguration == true,
              let index = profiles.firstIndex(where: { $0.id == matching.id }) else { return }
        profiles[index].screens = screens.sorted { $0.isMain && !$1.isMain }.map(DisplayProfile.Screen.init)
        persist(profiles, for: profilesKey)
    }

    func deleteProfile(_ id: UUID) {
        guard canChangeDisplayConfiguration else { return }
        profiles.removeAll { $0.id == id }
        persist(profiles, for: profilesKey)
        message = "Профиль удалён."
    }

    func tryProfile(_ id: UUID) {
        guard canChangeDisplayConfiguration, let profile = profiles.first(where: { $0.id == id }) else { return }
        refresh()
        let before = observations()
        do {
            guard !profile.isApplied(to: screens) else {
                message = "Профиль «\(profile.name)» уже активен."
                return
            }
            let operation = try profileOperation(profile)
            if let problem = beginPreview("Профиль «\(profile.name)»", expectedModes: profile.modes, profile: profile,
                                          operation) {
                addHistory([.profile], profileName: profile.name, before: before, requested: profile.modes, result: problem)
            }
        } catch {
            message = error.localizedDescription
            addHistory([.profile], profileName: profile.name, before: before, requested: profile.modes,
                       result: error.localizedDescription)
        }
    }

    private func restoreProfile(
        _ profile: DisplayProfile, triggers: [DisplayHistoryEntry.Trigger], before: [String: DisplayObservation],
        hdrCandidates: Set<String>
    ) async {
        var corrected = false
        var result = "Профиль уже активен."
        if !profile.isApplied(to: screens) {
            nextProtectionCheck = ProcessInfo.processInfo.systemUptime + 3
            do {
                let operation = try profileOperation(profile)
                let previous = screens.map(DisplayState.init)
                try applyConfiguration(previous, restoreLayout: true, operation: operation,
                                       afterConfiguration: { try self.applyProfileColors(profile) }) { profile.isApplied(to: $0) }
                corrected = true
                result = "Профиль восстановлен."
                message = "Профиль «\(profile.name)» восстановлен."
            } catch {
                if profile.protectsConfiguration == true {
                    failedProfileProtection = profile.id
                    lastProtectionTopology = actualTopology
                }
                result = error.localizedDescription
                message = "Профиль «\(profile.name)»: \(result)"
            }
        }
        let hdrResults = await restoreHDR(hdrCandidates)
        if corrected || !hdrResults.isEmpty || triggers != [.verification] {
            addHistory(triggers, profileName: profile.name, before: before, requested: profile.modes,
                       result: ([result] + hdrResults).joined(separator: " "))
        }
    }

    private func profileOperation(_ profile: DisplayProfile) throws -> (CGDisplayConfigRef) throws -> Void {
        guard canCaptureProfile, profile.matches(screens) else {
            throw DisplayFailure("Подключи дисплеи из этого профиля.")
        }
        guard profile.screens.filter(\.isMain).count == 1,
              profile.screens.allSatisfy({ $0.isMain == ($0.origin == .zero) }) else {
            throw DisplayFailure("В профиле указано недопустимое расположение дисплеев.")
        }
        let assignments = try profile.screens.map { saved -> (DisplayProfile.Screen, Display, ScreenMode?) in
            guard let display = screens.first(where: { $0.identity == saved.id }) else {
                throw DisplayFailure("Дисплей «\(saved.name)» отключён.")
            }
            if display.color != saved.color { try saved.color?.validate() }
            guard display.current.key != saved.mode else { return (saved, display, nil) }
            guard let mode = display.modes.first(where: { $0.key == saved.mode }) else {
                throw DisplayFailure("Для «\(display.title)» недоступен режим \(saved.mode.label).")
            }
            return (saved, display, mode)
        }
        return { config in
            for (_, display, mode) in assignments {
                if let mode { try setMode(config, display: display.id, mode: mode) }
            }
            for (saved, display, _) in assignments {
                try self.setOrigin(config, display.id, saved.origin)
            }
        }
    }

    private func applyProfileColors(_ profile: DisplayProfile) throws {
        for saved in profile.screens {
            guard let color = saved.color, let display = screens.first(where: { $0.identity == saved.id }),
                  color != display.color else { continue }
            try color.apply(to: display)
        }
    }

    private func applyConfiguration(
        _ previous: [DisplayState], restoreLayout: Bool, operation: (CGDisplayConfigRef) throws -> Void,
        afterConfiguration: () throws -> Void = {}, verify: ([Display]) -> Bool
    ) throws {
        try configureDisplays(operation)
        do {
            try afterConfiguration()
            refresh()
            guard verify(screens) else { throw DisplayFailure("macOS отклонила запрошенные настройки.") }
        } catch {
            let originalError = error.localizedDescription
            refresh()
            let stable = Set(previous.map(\.identity)) == Set(screens.map(\.identity))
            try restore(previous, among: screens, restoreLayout: restoreLayout && stable)
            refresh()
            throw DisplayFailure("\(originalError) Предыдущие настройки восстановлены.")
        }
    }

    func changeDisplaySettings(_ operation: () async throws -> Void) async throws {
        guard canChangeDisplayConfiguration else { return }
        cancelVerification()
        isChangingDisplaySettings = true
        defer {
            refreshHDRModes()
            isChangingDisplaySettings = false
            scheduleRefresh()
        }
        try await operation()
    }

    func setHDR(_ enabled: Bool, on display: Display) async throws {
        guard !isWritingMonitor else { throw DisplayFailure("Дождись записи настроек монитора.") }
        try await changeDisplaySettings {
            try await DisplayHDRMode.set(enabled, on: display)
            rememberHDR(enabled, for: display.identity)
            message = enabled ? "Режим HDR включён." : "Режим HDR выключен."
        }
    }

    func refreshHDRModes() {
        let modes = Dictionary(uniqueKeysWithValues: screens.compactMap { display in
            DisplayHDRMode.status(for: display).map { (display.id, $0) }
        })
        if modes != hdrModes { hdrModes = modes }
    }

    func tuneHDR(on display: Display) async {
        guard canChangeDisplayConfiguration, !isReadingMonitor, !isWritingMonitor,
              selected?.id == display.id, selected?.identity == display.identity, hasDDCBrightness else { return }
        let tuning = HDRTuning(display: display)
        do {
            try await changeDisplaySettings {
                hdrTuning = tuning
                defer {
                    hdrTuning = nil
                    if selected?.id == display.id, selected?.identity == display.identity {
                        clearMonitor()
                        scanMonitor()
                    }
                }
                if try await tuning.run(in: edrPreview, controls: monitorControls),
                   let enabled = DisplayHDRMode.status(for: display) {
                    rememberHDR(enabled, for: display.identity)
                }
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private func rememberHDR(_ enabled: Bool, for identity: String) {
        guard !identity.hasPrefix("session-") else { return }
        rememberedSettings.hdr[identity] = enabled
        persist(rememberedHDR, for: rememberedHDRKey)
    }

    func select(_ id: CGDirectDisplayID) {
        guard id != selectedID else { return }
        selectedID = id
        message = nil
        clearMonitor()
    }

    func tryMode(_ key: ModeKey, display identity: String) {
        guard canChangeDisplayConfiguration else { return }
        refresh()
        guard let display = screens.first(where: { $0.identity == identity }), display.current.key != key,
              let mode = display.modes.first(where: { $0.key == key }) else { return }
        guard display.mirrors == kCGNullDirectDisplay else {
            message = "Выключи видеоповтор в настройках macOS, чтобы выбрать режим для этого дисплея."
            return
        }
        beginPreview("\(display.title): \(mode.key.label)", expectedModes: [identity: key]) { config in
            try setMode(config, display: display.id, mode: mode)
        }
    }

    func placeSelected(_ placement: Placement) {
        guard canChangeDisplayConfiguration else { return }
        refresh()
        guard let display = selected, let main = screens.first(where: \.isMain), display.id != main.id,
              display.mirrors == kCGNullDirectDisplay else { return }
        let point = placement.origin(for: display.bounds, relativeTo: main.bounds)
        let proposed = CGRect(origin: point, size: display.bounds.size)
        guard !screens.contains(where: { $0.id != display.id && proposed.intersects($0.bounds) }) else {
            message = "Это место занято другим дисплеем."
            return
        }
        guard display.bounds.origin != point else { return }
        beginPreview("\(display.title) \(placement.rawValue.lowercased()) от основного",
                     expectedOrigins: [display.identity: point]) { config in
            try setOrigin(config, display.id, point)
        }
    }

    func makeSelectedMain() {
        guard canChangeDisplayConfiguration else { return }
        refresh()
        guard let display = selected, !display.isMain,
              screens.allSatisfy({ $0.mirrors == kCGNullDirectDisplay }) else { return }
        let positions = screens.map { screen in
            (screen, CGPoint(x: screen.bounds.minX - display.bounds.minX, y: screen.bounds.minY - display.bounds.minY))
        }
        let expected = Dictionary(positions.map { ($0.0.identity, $0.1) }, uniquingKeysWith: { first, _ in first })
        beginPreview("Основной дисплей: \(display.title)", expectedOrigins: expected, expectedMain: display.id) { config in
            for (screen, point) in positions { try setOrigin(config, screen.id, point) }
        }
    }

    func canDisconnect(_ display: Display) -> Bool {
        DisplayConnection.isAvailable && softwareDisconnect == nil && canChangeDisplayConfiguration
            && !display.isMain && !display.builtIn && !display.isVirtual && !display.isInMirrorSet
            && screens.contains { $0.builtIn && $0.isMain && CGDisplayIsActive($0.id) != 0 }
    }

    func disconnect(_ displayID: CGDirectDisplayID) {
        guard canChangeDisplayConfiguration else { return }
        refresh()
        guard let display = screens.first(where: { $0.id == displayID }), canDisconnect(display) else { return }
        cancelVerification()
        let state = DisconnectState(display: display, previous: screens.map(DisplayState.init))
        do {
            try DisplayConnection.setEnabled(false, display: display.id, identity: display.identity)
            softwareDisconnect = state
            refresh()
            message = "Дисплей «\(display.title)» отключён до повторного подключения."
        } catch {
            message = error.localizedDescription
        }
    }

    func reconnectDisplay() async {
        guard canChangeDisplayConfiguration, let state = softwareDisconnect else { return }
        cancelVerification()
        isReconnecting = true
        defer {
            isReconnecting = false
            scheduleRefresh()
        }
        do {
            try DisplayConnection.setEnabled(true, display: state.display.id, identity: state.display.identity)
            let ids = try await waitForReconnect(state.display.identity)
            softwareDisconnect = nil
            let identities = Set(ids.map { displayIdentity($0, among: ids) ?? "session-\($0)" })
            let sameTopology = Set(state.previous.map(\.identity)) == identities && identities.count == ids.count
                && ids.allSatisfy { CGDisplayCopyDisplayMode($0) != nil }
            if reconnectNeedsRestore(state.previous, among: ids, restoreLayout: sameTopology) {
                try restore(state.previous, among: displays(among: ids), restoreLayout: sameTopology)
            }
            message = "Дисплей «\(state.display.title)» подключён."
        } catch {
            message = error.localizedDescription
        }
    }

    private func waitForReconnect(_ identity: String) async throws -> [CGDirectDisplayID] {
        for attempt in 0...20 {
            let ids = onlineDisplayIDs()
            if ids.contains(where: { displayIdentity($0, among: ids) == identity && CGDisplayCopyDisplayMode($0) != nil }) {
                return ids
            }
            if attempt < 20 { try await Task.sleep(for: .milliseconds(150)) }
        }
        throw DisplayFailure("Дисплей ещё не появился. Проверь подключение и повтори команду.")
    }

    private func reconnectNeedsRestore(_ snapshot: [DisplayState], among ids: [CGDirectDisplayID], restoreLayout: Bool) -> Bool {
        let online = onlineDisplayIdentities(ids).filter { CGDisplayMirrorsDisplay($0.id) == kCGNullDirectDisplay }
        return snapshot.contains { state in
            guard let id = matchSnapshotDisplay(identity: state.identity, fallbackID: state.id,
                                                among: online, identityOf: \.identity, idOf: \.id)?.id,
                  let mode = CGDisplayCopyDisplayMode(id) else { return false }
            return ModeKey(mode) != state.mode.key
                || (restoreLayout && CGDisplayBounds(id).origin != state.origin)
                || (state.color != nil && DisplayColor.read(id) != state.color)
        }
    }

    func reconnectBeforeQuit() {
        if let display = softwareDisconnect?.display {
            try? DisplayConnection.setEnabled(true, display: display.id, identity: display.identity)
        }
    }

    func tryOrientation(_ orientation: DisplayOrientation, on display: Display) {
        guard canChangeDisplayConfiguration, !display.isInMirrorSet,
              let original = DisplayOrientation.current(display.id), original != orientation else { return }
        let rotation = RotationChange(id: display.id, identity: display.identity, previous: original,
                                      requested: orientation)
        _ = beginPreview("Поворот на \(orientation.title)", rotation: rotation) { _ in }
    }

    func tryMirror(_ targetID: CGDirectDisplayID, of sourceID: CGDirectDisplayID) {
        guard canChangeDisplayConfiguration, sourceID != targetID else { return }
        refresh()
        guard let target = screens.first(where: { $0.id == targetID }),
              let source = screens.first(where: { $0.id == sourceID }),
              screens.allSatisfy({ !$0.isInMirrorSet }) else {
            message = "Выключи текущий видеоповтор перед проверкой нового."
            return
        }
        let change = MirrorChange(source: sourceID, target: targetID)
        beginPreview("Повтор изображения с \(source.title) на \(target.title)", mirror: change) { config in
            try checkDisplayError(CGConfigureDisplayMirrorOfDisplay(config, targetID, sourceID))
        }
    }

    func stopMirroring(_ displayID: CGDirectDisplayID) {
        guard canChangeDisplayConfiguration else { return }
        let targets = onlineDisplayIDs().filter { id in
            let source = CGDisplayMirrorsDisplay(id)
            return source != kCGNullDirectDisplay && (id == displayID || source == displayID)
        }
        guard !targets.isEmpty else { return }
        cancelVerification()
        do {
            try configureDisplays { config in
                for target in targets {
                    try checkDisplayError(CGConfigureDisplayMirrorOfDisplay(config, target, kCGNullDirectDisplay))
                }
            }
            refresh()
            updateProtectedTopology()
            message = "Видеоповтор отключён."
        } catch {
            message = error.localizedDescription
        }
    }

    private func setOrigin(_ config: CGDisplayConfigRef, _ id: CGDirectDisplayID, _ origin: CGPoint) throws {
        guard let x = Int32(exactly: origin.x.rounded()), let y = Int32(exactly: origin.y.rounded()) else {
            throw DisplayFailure("Координаты дисплея вне допустимого диапазона.")
        }
        try checkDisplayError(CGConfigureDisplayOrigin(config, id, x, y))
    }

    @discardableResult
    private func beginPreview(
        _ title: String, expectedModes: [String: ModeKey] = [:], expectedOrigins: [String: CGPoint] = [:],
        expectedMain: CGDirectDisplayID? = nil, profile: DisplayProfile? = nil, mirror: MirrorChange? = nil,
        rotation: RotationChange? = nil, _ operation: (CGDisplayConfigRef) throws -> Void
    ) -> String? {
        guard canChangeDisplayConfiguration else { return "Дождись восстановления настроек." }
        let snapshot = screens.filter { $0.mirrors == kCGNullDirectDisplay }.map(DisplayState.init)
        let couldLoseOrigin = screens.contains { display in
            expectedModes[display.identity].map({ $0 != display.current.key }) == true && display.current.key.isHiDPI
                && HiddenDisplayModes.configure == nil
        }
        guard !couldLoseOrigin else {
            message = "В этой версии macOS BestDisplay может не восстановить этот режим HiDPI."
            return message
        }
        cancelVerification()
        do {
            if let profile {
                try applyConfiguration(snapshot, restoreLayout: true, operation: operation,
                                       afterConfiguration: { try self.applyProfileColors(profile) }) { profile.isApplied(to: $0) }
            } else if let rotation {
                try rotation.requested.request(on: rotation.id, identity: rotation.identity)
            } else {
                try configureDisplays(operation)
            }
        } catch {
            message = error.localizedDescription
            return message
        }
        message = nil
        secondsLeft = 20
        preview = DisplayPreview(title: title, previous: snapshot, expectedModes: expectedModes,
                                 expectedOrigins: expectedOrigins, expectedMain: expectedMain,
                                 profile: profile, mirror: mirror,
                                 rotation: rotation, deadline: ProcessInfo.processInfo.systemUptime + 20)
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickPreview() }
        }
        previewTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        refresh()
        return nil
    }

    private func tickPreview() {
        guard let preview else { return }
        let remaining = max(0, Int(ceil(preview.deadline - ProcessInfo.processInfo.systemUptime)))
        if secondsLeft != remaining { secondsLeft = remaining }
        if remaining == 0 { revertPreview(reason: "Время проверки истекло.") }
    }

    private func clearPreview() {
        previewTimer?.invalidate()
        previewTimer = nil
        preview = nil
        secondsLeft = 0
    }

    func keepPreview() {
        guard let preview else { return }
        let actual = displays()
        let modesMatch = preview.expectedModes.allSatisfy { identity, mode in
            actual.contains { $0.identity == identity && $0.current.key == mode }
        }
        let originsMatch = preview.expectedOrigins.allSatisfy { identity, origin in
            let expected = CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
            return actual.contains { $0.identity == identity && $0.bounds.origin == expected }
        }
        guard modesMatch, originsMatch,
              preview.expectedMain.map({ $0 == CGMainDisplayID() }) ?? true,
              preview.profile.map({ $0.isApplied(to: actual) }) ?? true,
              preview.mirror?.isApplied ?? true, preview.rotation?.isApplied ?? true else {
            revertPreview(reason: "macOS не применила запрошенные настройки.")
            return
        }
        _ = collectDisplayEvents(among: actual, now: ProcessInfo.processInfo.systemUptime)
        cancelVerification()
        if var pending = pendingRestore {
            pending.confirm(modes: Set(preview.expectedModes.keys),
                            changesLayout: !preview.expectedOrigins.isEmpty || preview.expectedMain != nil
                                || preview.mirror != nil || preview.rotation != nil || preview.profile != nil)
            pendingRestore = pending.targets.isEmpty && !preview.expectedModes.isEmpty ? nil : pending
        }
        clearPreview()
        refresh()
        if (preview.expectedMain != nil || !preview.expectedOrigins.isEmpty), let layout = currentLayout {
            rememberLayout(layout)
            lastObservedLayout = layout
        }
        if preview.profile == nil { updateProtectedProfile() }
        if preview.mirror != nil || preview.rotation != nil { updateProtectedTopology() }
        message = "Настройки применены до выхода из учётной записи macOS."
        recordProfilePreview(preview, result: "Применение профиля подтверждено.")
        scheduleRefresh()
    }

    func revertPreview(reason: String? = nil) {
        guard let preview else { return }
        lastObservedLayout = nil
        clearPreview()
        if let rotation = preview.rotation, displayIdentity(rotation.id) == rotation.identity,
           CGDisplayIsOnline(rotation.id) != 0 {
            isChangingTopology = true
            Task {
                do {
                    try rotation.previous.request(on: rotation.id, identity: rotation.identity)
                    try await rotation.previous.wait(on: rotation.id, identity: rotation.identity)
                    finishRevert(preview, reason: reason)
                } catch {
                    refresh()
                    message = error.localizedDescription
                }
                isChangingTopology = false
                scheduleRefresh()
            }
            return
        }
        finishRevert(preview, reason: reason)
        scheduleRefresh()
    }

    private func finishRevert(_ preview: DisplayPreview, reason: String?) {
        do {
            try preview.mirror?.undo()
            let actual = displays()
            let sameTopology = Set(preview.previous.map(\.identity))
                == Set(actual.filter { $0.mirrors == kCGNullDirectDisplay }.map(\.identity))
            try restore(preview.previous, among: actual, restoreLayout: sameTopology)
            refresh()
            let restored = "Предыдущие настройки восстановлены."
            message = reason.map { "\($0) \(restored)" } ?? restored
        } catch {
            refresh()
            message = error.localizedDescription
        }
        if let message { recordProfilePreview(preview, result: message) }
    }

    private func recordProfilePreview(_ preview: DisplayPreview, result: String) {
        guard let profile = preview.profile else { return }
        let before = Dictionary(preview.previous.map { ($0.identity, $0.observation) },
                                uniquingKeysWith: { first, _ in first })
        addHistory([.profile], profileName: profile.name, before: before, requested: profile.modes, result: result)
    }

    private func restore(_ snapshot: [DisplayState], among actual: [Display], restoreLayout: Bool) throws {
        let available = actual.filter { $0.mirrors == kCGNullDirectDisplay }
        let states = snapshot.compactMap { state -> (Display, DisplayState)? in
            let display = matchSnapshotDisplay(identity: state.identity, fallbackID: state.id,
                                               among: available, identityOf: \.identity, idOf: \.id)
            return display.map { ($0, state) }
        }
        let updateMode = states.contains { $0.0.current.key != $0.1.mode.key }
        let updateLayout = restoreLayout && states.contains { $0.0.bounds.origin != $0.1.origin }
        let colorStates = states.filter { $0.1.color != nil && $0.0.color != $0.1.color }
        guard updateMode || updateLayout || !colorStates.isEmpty else { return }
        if updateMode || updateLayout {
            try configureDisplays { config in
                for (display, state) in states where display.current.key != state.mode.key {
                    if let original = display.modes.first(where: { $0.key == state.mode.key }) {
                        try setMode(config, display: display.id, mode: original)
                    } else if display.id == state.id, !display.modes.contains(where: { $0.modeID == state.mode.modeID }) {
                        try setMode(config, display: display.id, mode: ScreenMode(hidden: state.mode.key, modeID: state.mode.modeID))
                    } else {
                        throw DisplayFailure("Прежний режим \(display.title) больше недоступен.")
                    }
                }
                if restoreLayout {
                    for (display, state) in states { try setOrigin(config, display.id, state.origin) }
                }
            }
        }
        for (display, state) in colorStates { try state.color?.apply(to: display) }
        let online = onlineDisplayIdentities(onlineDisplayIDs())
        let restored = states.allSatisfy { _, state in
            guard let id = matchSnapshotDisplay(identity: state.identity, fallbackID: state.id,
                                                among: online, identityOf: \.identity, idOf: \.id)?.id else { return false }
            return CGDisplayCopyDisplayMode(id).map(ModeKey.init) == state.mode.key
                && (!restoreLayout || CGDisplayBounds(id).origin == state.origin)
                && (state.color == nil || DisplayColor.read(id) == state.color)
        }
        guard restored else { throw DisplayFailure("macOS не восстановила предыдущие настройки дисплеев.") }
    }

    func setRemembered(_ enabled: Bool, for identity: String) {
        guard canChangeDisplayConfiguration, !identity.hasPrefix("session-") else { return }
        if enabled { refresh() }
        guard let display = screens.first(where: { $0.identity == identity }) else { return }
        cancelVerification()
        let hdr = enabled ? DisplayHDRMode.status(for: display) : nil
        rememberedSettings.setMode(enabled ? display.current.key : nil, currentHDR: hdr, for: identity)
        persist(remembered, for: rememberedKey)
        if hdr != nil { persist(rememberedHDR, for: rememberedHDRKey) }
        message = nil
        if enabled { persistActiveMode(of: display) }
    }

    var dimming: [String: Double] { dimmer.levels }

    func dim(_ identity: String, by amount: Double) {
        dimmer.set(amount, for: identity)
        dimmer.sync(screens)
    }

    func createVirtual(width: Int, height: Int, hiDPI: Bool, rate: Int = 60) {
        guard virtualDisplay == nil, canChangeDisplayConfiguration else { return }
        let original = displays().filter { $0.mirrors == kCGNullDirectDisplay }.map(DisplayState.init)
        let maximum = hiDPI ? 2560 : 5120
        guard (640...maximum).contains(width), (360...maximum).contains(height), (24...120).contains(rate) else {
            message = "Укажи ширину от 640 до \(maximum) и высоту от 360 до \(maximum) пикселей."
            return
        }
        cancelVerification()
        var id: CGDirectDisplayID = 0
        guard let handle = BDMakeVirtualDisplay("BestDisplay Virtual", Self.virtualSerial, UInt32(width), UInt32(height), Double(rate), hiDPI, &id) else {
            message = "macOS не смогла создать виртуальный дисплей."
            return
        }
        virtualDisplay = LiveVirtualDisplay(id: id, handle: handle)
        isChangingVirtual = true
        message = "Подключение виртуального дисплея…"
        let expected = Dimensions(width: width, height: height)
        Task {
            let connected = await waitForVirtual(id, connected: true)
            let observed = CGDisplayCopyDisplayMode(id).map(ModeKey.init)
            let matches = connected && observed?.desktop == expected && observed?.isHiDPI == hiDPI
            if !matches {
                retiredVirtualIDs.insert(id)
                virtualDisplay = nil
                _ = await waitForVirtual(id, connected: false)
            }
            finishVirtualChange(original, message: matches
                                ? "Виртуальный дисплей создан."
                                : "macOS не активировала виртуальный дисплей с указанным разрешением.")
        }
    }

    func removeVirtual() {
        guard canChangeDisplayConfiguration, let id = virtualDisplay?.id else { return }
        cancelVerification()
        let original = displays().filter { $0.id != id && $0.mirrors == kCGNullDirectDisplay }.map(DisplayState.init)
        retiredVirtualIDs.insert(id)
        virtualDisplay = nil
        isChangingVirtual = true
        message = "Отключение виртуального дисплея…"
        Task {
            let disconnected = await waitForVirtual(id, connected: false)
            finishVirtualChange(original, message: disconnected
                                ? "Виртуальный дисплей отключён."
                                : "macOS ещё показывает отключаемый дисплей.")
        }
    }

    private func waitForVirtual(_ id: CGDirectDisplayID, connected: Bool) async -> Bool {
        for _ in 0..<24 {
            if connected ? CGDisplayCopyDisplayMode(id) != nil : CGDisplayIsOnline(id) == 0 { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    private func finishVirtualChange(_ original: [DisplayState], message: String) {
        do {
            try restore(original, among: displays(), restoreLayout: false)
            self.message = message
        } catch {
            self.message = error.localizedDescription
        }
        refresh()
        isChangingVirtual = false
        scheduleRefresh()
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            message = SMAppService.mainApp.status == .requiresApproval
                ? "Открой «Объекты входа» в настройках macOS и разреши запуск BestDisplay."
                : nil
        } catch {
            message = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
