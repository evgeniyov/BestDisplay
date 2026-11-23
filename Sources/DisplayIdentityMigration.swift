import Foundation

struct DisplayIdentityMigration: Equatable {
    struct OnlineDisplay {
        let identity: String
        let legacyUUID: String?
        let name: String?
        let modes: Set<ModeKey>
    }

    var remembered: [String: ModeKey]
    var rememberedHDR: [String: Bool] = [:]
    var profiles: [DisplayProfile]
    var topologies: [DisplayTopology]
    var layouts: [DisplayLayout] = []
    var brightnessGroup: Set<String>
    var migratedHardwareIDs: Set<String> = []

    func migrated(online: [OnlineDisplay], history: [DisplayHistoryEntry]) -> Self {
        rekeyingChangedSerials(online: online, history: history).migratingUUIDs(online: online, history: history)
    }

    private func migratingUUIDs(online: [OnlineDisplay], history: [DisplayHistoryEntry]) -> Self {
        let byIdentity = Dictionary(grouping: online, by: \.identity)
        let eligible = online.filter {
            $0.identity.hasPrefix("hw-") && !migratedHardwareIDs.contains($0.identity)
                && byIdentity[$0.identity]?.count == 1
                && DisplayHistoryEntry.Screen.knownName($0.name) != nil && !$0.modes.isEmpty
        }
        guard !eligible.isEmpty else { return self }

        let byUUID = Dictionary(grouping: online.compactMap(\.legacyUUID), by: { $0 })
        let byName = Dictionary(grouping: online.compactMap { DisplayHistoryEntry.Screen.knownName($0.name) },
                                by: { $0 })
        let sightings = history.sorted { $0.date > $1.date }.flatMap(\.screens).filter {
            byUUID[$0.id] == nil && UUID(uuidString: $0.id) != nil
                && DisplayHistoryEntry.Screen.knownName($0.name) != nil
        }
        let namesByUUID = Dictionary(grouping: sightings, by: \.id).mapValues { Set($0.map(\.name)) }
        var seenUUIDs = Set<String>()
        let historyUUIDsByName = Dictionary(grouping: sightings.filter {
            namesByUUID[$0.id]?.count == 1 && seenUUIDs.insert($0.id).inserted
        }, by: \.name).mapValues { $0.map(\.id) }

        var updated = self
        var ownedUUIDs: [(old: String, new: String)] = []
        for display in eligible {
            let identity = display.identity
            let currentUUID = display.legacyUUID.flatMap { byUUID[$0]?.count == 1 ? $0 : nil }
            let historicalUUIDs = display.name.flatMap { name in
                byName[name]?.count == 1 ? historyUUIDsByName[name] : nil
            } ?? []
            let owned = [currentUUID].compactMap { $0 } + historicalUUIDs
            if updated.remembered[identity] == nil {
                let adopted = currentUUID.flatMap { remembered[$0] }
                    ?? historicalUUIDs.lazy.compactMap { remembered[$0] }.first(where: display.modes.contains)
                if adopted == nil, historicalUUIDs.contains(where: { remembered[$0] != nil }) { continue }
                updated.remembered[identity] = adopted
            }
            for uuid in owned { updated.remembered[uuid] = nil }
            ownedUUIDs += owned.map { ($0, identity) }
            updated.migratedHardwareIDs.insert(identity)
        }

        return updated.rekeying(ownedUUIDs)
    }

    private func rekeyingChangedSerials(online: [OnlineDisplay], history: [DisplayHistoryEntry]) -> Self {
        func productPrefix(_ identity: String) -> String? {
            let parts = identity.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 4, parts[0] == "hw",
                  parts.dropFirst().allSatisfy({ UInt32($0) != nil }) else { return nil }
            return String(identity.dropLast(parts[3].count))
        }

        var storedIDs = Set(remembered.keys).union(rememberedHDR.keys).union(brightnessGroup)
        for profile in profiles { storedIDs.formUnion(profile.displayIDs) }
        for topology in topologies {
            storedIDs.formUnion(topology.identities)
            storedIDs.formUnion(topology.orientations.keys)
            storedIDs.formUnion(topology.mirrors.keys)
            storedIDs.formUnion(topology.mirrors.values)
        }
        for layout in layouts { storedIDs.formUnion(layout.identities) }

        let onlineProducts = Dictionary(grouping: online.compactMap { display in
            productPrefix(display.identity).map { (prefix: $0, identity: display.identity) }
        }, by: \.prefix)
        let changes = onlineProducts.compactMap { prefix, displays -> (old: String, new: String)? in
            guard displays.count == 1, let current = displays.first?.identity,
                  !storedIDs.contains(current) else { return nil }
            let candidates = storedIDs.filter { productPrefix($0) == prefix }
            if candidates.count == 1, let old = candidates.first { return (old, current) }
            guard !candidates.isEmpty else { return nil }
            let old = history.sorted { $0.date > $1.date }.lazy.flatMap(\.screens)
                .first { candidates.contains($0.id) }?.id
            return old.map { ($0, current) }
        }
        return rekeying(changes)
    }

    private func rekeying(_ changes: [(old: String, new: String)]) -> Self {
        guard !changes.isEmpty else { return self }
        let replacements = Dictionary(uniqueKeysWithValues: changes)
        func identity(_ old: String) -> String { replacements[old] ?? old }
        func rekey<Value>(_ values: [String: Value]) -> [String: Value] {
            var updated = values
            for (old, new) in changes {
                if let value = updated.removeValue(forKey: old), updated[new] == nil {
                    updated[new] = value
                }
            }
            return updated
        }

        var updated = self
        updated.remembered = rekey(remembered)
        updated.rememberedHDR = rekey(rememberedHDR)
        updated.profiles = profiles.map { profile in
            var migrated = profile
            migrated.screens = profile.screens.map { screen in
                DisplayProfile.Screen(id: identity(screen.id), name: screen.name, mode: screen.mode,
                                      origin: screen.origin, isMain: screen.isMain, color: screen.color)
            }
            return migrated
        }
        let rekeyedTopologies = topologies.map { topology in
            let identities = topology.identities.map(identity)
            return DisplayTopology(identities: identities == topology.identities ? identities : Set(identities).sorted(),
                                   orientations: rekey(topology.orientations),
                                   mirrors: rekey(topology.mirrors).mapValues(identity))
        }
        var seenTopologyIDs = Set<Set<String>>()
        updated.topologies = Array(rekeyedTopologies.reversed().filter {
            seenTopologyIDs.insert(Set($0.identities)).inserted
        }.reversed())
        var seenLayoutIDs = Set<[String]>()
        updated.layouts = Array(layouts.reversed().compactMap { $0.rekeyed(using: identity) }.filter {
            seenLayoutIDs.insert($0.identities).inserted
        }.reversed())
        updated.brightnessGroup = Set(brightnessGroup.map(identity))
        return updated
    }
}
