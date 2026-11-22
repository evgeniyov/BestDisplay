import Foundation

struct RememberedDisplaySettings {
    var modes: [String: ModeKey] = [:]
    var hdr: [String: Bool] = [:]

    mutating func setMode(_ mode: ModeKey?, currentHDR: Bool?, for identity: String) {
        modes[identity] = mode
        if mode != nil, let currentHDR { hdr[identity] = currentHDR }
    }

    func hdrChange(for identity: String, current: Bool?) -> Bool? {
        guard let current, let saved = hdr[identity], saved != current else { return nil }
        return saved
    }
}

struct DisplayObservation {
    let displayID: UInt32
    let name: String
    let mode: ModeKey
}

struct PendingDisplayRestore {
    enum Readiness: Equatable {
        case waiting(until: TimeInterval?)
        case ready(Set<String>)
    }

    var targets = Set<String>()
    var triggers = Set<DisplayHistoryEntry.Trigger>()
    var before: [String: DisplayObservation] = [:]
    var waitUntil: TimeInterval = 0
    var allowsProfile = true

    mutating func confirm(modes: Set<String>, changesLayout: Bool) {
        targets.subtract(modes)
        if !modes.isEmpty || changesLayout { allowsProfile = false }
    }

    mutating func takeReady(online: Set<String>, available: Set<String>, at now: TimeInterval) -> Readiness {
        let ready = targets.intersection(online).intersection(available)
        if ready != targets && now < waitUntil { return .waiting(until: waitUntil) }
        targets.formIntersection(online)
        targets.subtract(ready)
        return ready.isEmpty && !targets.isEmpty ? .waiting(until: nil) : .ready(ready)
    }
}

struct DisplayVerificationWindow {
    private var entries: [String: (deadline: TimeInterval, allowsProfile: Bool)] = [:]

    var identities: Set<String> { Set(entries.keys) }
    var profileIdentities: Set<String> { Set(entries.keys.filter { entries[$0]?.allowsProfile == true }) }
    var deadline: TimeInterval? { entries.values.map(\.deadline).min() }

    mutating func start(for identities: Set<String>, now: TimeInterval, allowsProfile: Bool = true) {
        for identity in identities { entries[identity] = (now + 10, allowsProfile) }
    }

    mutating func expire(at now: TimeInterval) {
        entries = entries.filter { $0.value.deadline > now }
    }

    mutating func cancel() {
        entries.removeAll()
    }
}

func matchSnapshotDisplay<Live>(
    identity: String, fallbackID: UInt32, among online: [Live],
    identityOf: (Live) -> String, idOf: (Live) -> UInt32
) -> Live? {
    online.first { identityOf($0) == identity } ?? online.first { idOf($0) == fallbackID }
}
