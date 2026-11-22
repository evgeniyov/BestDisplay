import ColorSync
import CoreGraphics
import Foundation

extension DisplayOrientation {
    static func current(_ id: CGDirectDisplayID) -> Self? {
        let angle = Int(CGDisplayRotation(id).rounded())
        return Self(rawValue: Int32((angle % 360 + 360) % 360))
    }

    @MainActor
    func request(on id: CGDirectDisplayID, identity: String) throws {
        guard CGDisplayIsInMirrorSet(id) == 0, displayIdentity(id) == identity,
              BDRequestDisplayOrientation(id, rawValue) else {
            throw DisplayFailure("macOS отклонила поворот дисплея.")
        }
    }

    @MainActor
    func wait(on id: CGDirectDisplayID, identity: String) async throws {
        for _ in 0..<40 {
            guard CGDisplayIsOnline(id) != 0, displayIdentity(id) == identity else { break }
            if Self.current(id) == self { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw DisplayFailure("macOS не подтвердила поворот дисплея.")
    }
}

extension DisplayTopology {
    @MainActor
    static func read(among screens: [Display]) -> Self? {
        let ids = onlineDisplayIDs()
        guard !ids.isEmpty, Set(ids) == Set(screens.map(\.id)),
              screens.allSatisfy({ !$0.isVirtual && !$0.identity.hasPrefix("session-") }),
              Set(screens.map(\.identity)).count == screens.count else { return nil }
        let names = Dictionary(uniqueKeysWithValues: screens.map { ($0.id, $0.identity) })
        var orientations: [String: DisplayOrientation] = [:]
        var mirrors: [String: String] = [:]
        for display in screens {
            let source = CGDisplayMirrorsDisplay(display.id)
            if source != kCGNullDirectDisplay {
                guard let identity = names[source] else { return nil }
                mirrors[display.identity] = identity
            } else if !display.isInMirrorSet && !display.builtIn && display.location != nil,
                      BDCanRequestDisplayOrientation() {
                orientations[display.identity] = DisplayOrientation.current(display.id)
            }
        }
        return Self(identities: names.values.sorted(), orientations: orientations, mirrors: mirrors)
    }

    @MainActor
    func apply(among screens: [Display]) async throws {
        guard let actual = Self.read(among: screens), actual.identities == identities else {
            throw DisplayFailure("Изменился набор физических дисплеев.")
        }
        let ids = Dictionary(uniqueKeysWithValues: screens.map { ($0.identity, $0.id) })
        let rotationChanges = orientations.compactMap { identity, target -> (String, CGDirectDisplayID, DisplayOrientation, DisplayOrientation)? in
            guard let id = ids[identity], let original = DisplayOrientation.current(id), original != target else { return nil }
            return (identity, id, original, target)
        }
        if actual.mirrors != mirrors || !rotationChanges.isEmpty {
            try Self.configureMirrors([:], replacing: actual.mirrors, ids: ids)
        }
        var attempted: [(String, CGDirectDisplayID, DisplayOrientation)] = []
        do {
            for (identity, id, original, target) in rotationChanges {
                try target.request(on: id, identity: identity)
                attempted.append((identity, id, original))
                try await target.wait(on: id, identity: identity)
            }
            guard let current = Self.read(among: displays()), current.identities == identities else {
                throw DisplayFailure("Изменился набор физических дисплеев.")
            }
            try Self.configureMirrors(mirrors, replacing: current.mirrors, ids: ids)
        } catch {
            for (identity, id, original) in attempted.reversed() {
                try? original.request(on: id, identity: identity)
                try? await original.wait(on: id, identity: identity)
            }
            if let current = Self.read(among: displays()), current.identities == identities {
                try? Self.configureMirrors(actual.mirrors, replacing: current.mirrors, ids: ids)
            }
            throw error
        }
    }

    @MainActor
    private static func configureMirrors(
        _ desired: [String: String], replacing previous: [String: String], ids: [String: CGDirectDisplayID]
    ) throws {
        guard desired != previous else { return }
        try configureDisplays { config in
            for identity in previous.keys where desired[identity] != previous[identity] {
                guard let target = ids[identity], displayIdentity(target) == identity else {
                    throw DisplayFailure("Изменился дисплей видеоповтора.")
                }
                try checkDisplayError(CGConfigureDisplayMirrorOfDisplay(config, target, kCGNullDirectDisplay))
            }
            for (identity, value) in desired where previous[identity] != value {
                guard let target = ids[identity], let source = ids[value],
                      displayIdentity(target) == identity, displayIdentity(source) == value else {
                    throw DisplayFailure("Изменился дисплей видеоповтора.")
                }
                try checkDisplayError(CGConfigureDisplayMirrorOfDisplay(config, target, source))
            }
        }
        guard ids.allSatisfy({ identity, id in CGDisplayMirrorsDisplay(id) == (desired[identity].flatMap { ids[$0] } ?? 0) }) else {
            throw DisplayFailure("macOS не подтвердила схему видеоповтора.")
        }
    }
}
