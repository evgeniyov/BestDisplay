import Foundation

func displayIdentityMigrationTests() {
    let legacy = "AAAAAAAA-0000-4000-8000-000000000001"
    let older = "AAAAAAAA-0000-4000-8000-000000000002"
    let newer = "AAAAAAAA-0000-4000-8000-000000000003"
    let unsupported = "AAAAAAAA-0000-4000-8000-000000000004"
    let other = "BBBBBBBB-0000-4000-8000-000000000001"
    let hardware = "hw-16652-49780-3194035838"
    let name = "PHL32M1N5500V"
    let desktop = Dimensions(width: 2560, height: 1440)
    let hidpi = ModeKey(desktop: desktop, rendering: Dimensions(width: 5120, height: 2880), millihertz: 60000)
    let native = ModeKey(desktop: desktop, rendering: desktop, millihertz: 60000)
    let unavailable = ModeKey(desktop: desktop, rendering: desktop, millihertz: 75000)
    let philips = DisplayIdentityMigration.OnlineDisplay(identity: hardware, legacyUUID: legacy,
                                                        name: name, modes: [hidpi, native])

    let color = DisplayColor(customProfile: URL(fileURLWithPath: "/tmp/profile.icc"))
    let saved = DisplayProfile.Screen(id: legacy, name: name, mode: hidpi,
                                      origin: CGPoint(x: 10, y: -30), isMain: false, color: color)
    let profile = DisplayProfile(id: UUID(), name: "Работа", automaticallyApplies: true,
                                 protectsConfiguration: true, screens: [saved])
    let topology = DisplayTopology(identities: [legacy, other], orientations: [legacy: .right, other: .left],
                                   mirrors: [legacy: other])
    let stored = DisplayIdentityMigration(remembered: [legacy: hidpi, other: native],
                                          rememberedHDR: [legacy: false, other: true], profiles: [profile],
                                          topologies: [topology], brightnessGroup: [legacy, other])
    let migrated = stored.migrated(online: [philips], history: [])
    check(migrated.remembered == [hardware: hidpi, other: native], "moves remembered UUID")
    check(migrated.rememberedHDR == [hardware: false, other: true], "moves HDR off from UUID to hardware identity")
    var expectedProfile = profile
    expectedProfile.screens = [DisplayProfile.Screen(id: hardware, name: saved.name, mode: saved.mode,
                                                     origin: saved.origin, isMain: saved.isMain, color: saved.color)]
    check(migrated.profiles == [expectedProfile], "rewrites profile screen while preserving profile and screen settings")
    check(migrated.topologies == [
        DisplayTopology(identities: [other, hardware], orientations: [hardware: .right, other: .left],
                        mirrors: [hardware: other])
    ], "sorts topology identities and rewrites orientation and both sides of mirror links")
    check(migrated.brightnessGroup == [hardware, other], "moves brightness group membership")
    check(migrated.migrated(online: [philips], history: []) == migrated, "exact migration is idempotent")
    var existing = stored
    existing.remembered[hardware] = native
    check(existing.migrated(online: [philips], history: []).remembered == [hardware: native, other: native],
          "existing hardware preference wins an exact UUID conflict")
    existing.rememberedHDR[hardware] = true
    check(existing.migrated(online: [philips], history: []).rememberedHDR == [hardware: true, other: true],
          "existing hardware HDR preference wins an exact UUID conflict")

    var duplicateTopologies = stored
    let unrelated = DisplayTopology(identities: [other], orientations: [other: .left], mirrors: [:])
    let latest = DisplayTopology(identities: [other, hardware], orientations: [hardware: .left], mirrors: [other: hardware])
    duplicateTopologies.topologies += [unrelated, latest]
    check(duplicateTopologies.migrated(online: [philips], history: []).topologies == [unrelated, latest],
          "Migration keeps the most recent protected topology with the same identity set")

    func event(_ id: String, at time: TimeInterval, name: String = name) -> DisplayHistoryEntry {
        DisplayHistoryEntry(id: UUID(), date: Date(timeIntervalSince1970: time), triggers: [.attached],
                            profileName: nil, result: "", screens: [
                                .init(id: id, name: name, before: nil, requested: nil, after: nil)
                            ])
    }

    let orphaned = DisplayIdentityMigration(remembered: [older: native, newer: hidpi, unsupported: unavailable,
                                                         other: native, "session-4": native],
                                            profiles: [], topologies: [], brightnessGroup: [])
    let history = [event(older, at: 1), event(newer, at: 2), event(unsupported, at: 3), event("session-4", at: 4)]
    let noModes = DisplayIdentityMigration.OnlineDisplay(identity: hardware, legacyUUID: legacy,
                                                         name: name, modes: [])
    for unknownName in [nil, "", "  ", "Дисплей 42"] {
        let unnamed = DisplayIdentityMigration.OnlineDisplay(identity: hardware, legacyUUID: legacy,
                                                             name: unknownName, modes: [hidpi])
        check(stored.migrated(online: [unnamed], history: history) == stored,
              "An unknown name defers all migration")
    }
    let unready = orphaned.migrated(online: [noModes], history: history)
    check(unready == orphaned && stored.migrated(online: [noModes], history: history) == stored,
          "An empty mode catalog defers both exact and historical migration")
    let adopted = orphaned.migrated(online: [philips], history: history)
    check(unready.migrated(online: [philips], history: history).remembered[hardware] == hidpi,
          "A populated mode catalog can migrate after an unready refresh")
    check(adopted.remembered == [hardware: hidpi, other: native, "session-4": native],
          "adopts the most recent supported mode and removes all matching orphan UUIDs")
    check(adopted.migrated(online: [philips], history: history) == adopted, "orphan adoption is idempotent")
    var firstSighting = orphaned
    firstSighting.migratedHardwareIDs = [hardware]
    check(adopted.migratedHardwareIDs == [hardware], "Successful adoption marks the hardware identity as migrated")
    check(orphaned.migrated(online: [philips], history: []).migrated(online: [philips], history: history) == firstSighting,
          "A first sighting without history still consumes the one opportunity for adoption")
    var forgotten = existing.migrated(online: [philips], history: [])
    forgotten.remembered[hardware] = nil
    check(forgotten.migrated(online: [philips], history: []) == forgotten,
          "Forgetting the hardware preference cannot resurrect a discarded exact UUID entry")
    let returned = DisplayIdentityMigration.OnlineDisplay(identity: hardware, legacyUUID: newer,
                                                          name: name, modes: [hidpi, native])
    check(firstSighting.migrated(online: [returned], history: history) == firstSighting,
          "An already migrated display never rewrites settings for its current UUID")

    let oldScreen = DisplayProfile.Screen(id: older, name: name, mode: native, origin: .zero, isMain: true)
    let newScreen = DisplayProfile.Screen(id: newer, name: name, mode: hidpi, origin: .zero, isMain: true)
    let oldProfile = DisplayProfile(id: UUID(), name: "Old", automaticallyApplies: true, screens: [oldScreen])
    let newProfile = DisplayProfile(id: UUID(), name: "New", automaticallyApplies: true, screens: [newScreen])
    let oldTopology = DisplayTopology(identities: [older, other], orientations: [older: .right],
                                      mirrors: [other: older])
    let newTopology = DisplayTopology(identities: [newer, other], orientations: [newer: .left],
                                      mirrors: [other: newer])
    var beforeReconnect = orphaned
    beforeReconnect.profiles = [oldProfile, newProfile]
    beforeReconnect.topologies = [oldTopology, newTopology]
    beforeReconnect.brightnessGroup = [older, newer, other]
    var afterReconnect = beforeReconnect.migrated(online: [returned], history: history)
    check(afterReconnect.remembered == adopted.remembered, "The current UUID wins and all owned legacy modes are removed")
    check(afterReconnect.profiles.map(\.id) == [oldProfile.id, newProfile.id]
            && afterReconnect.profiles.allSatisfy { $0.displayIDs == [hardware] },
          "Both profiles survive the UUID rewrite")
    let matchingProfiles = [oldProfile, newProfile].map { profile in
        DisplayProfile(id: profile.id, name: profile.name, automaticallyApplies: true,
                       screens: [.init(id: hardware, name: name, mode: profile.screens[0].mode,
                                       origin: .zero, isMain: true)])
    }
    check(DisplayProfile.current(in: matchingProfiles, displayIDs: [hardware])?.id == newProfile.id
            && DisplayProfile.current(in: afterReconnect.profiles, displayIDs: [hardware])?.id == newProfile.id,
          "The later profile is current when both profiles match")
    check(afterReconnect.topologies == [
        DisplayTopology(identities: [other, hardware], orientations: [hardware: .left], mirrors: [other: hardware])
    ] && afterReconnect.brightnessGroup == [hardware, other],
          "History UUIDs are rewritten in topologies and brightness groups")
    var profileOnlyHistory = beforeReconnect
    profileOnlyHistory.remembered = [newer: unavailable]
    let migratedProfileOnlyHistory = profileOnlyHistory.migrated(online: [returned], history: history)
    check(migratedProfileOnlyHistory.remembered == [hardware: unavailable]
            && migratedProfileOnlyHistory.profiles == afterReconnect.profiles
            && migratedProfileOnlyHistory.topologies == afterReconnect.topologies
            && migratedProfileOnlyHistory.brightnessGroup == afterReconnect.brightnessGroup,
          "The current UUID keeps its mode and history UUIDs migrate even without remembered entries")
    afterReconnect.remembered[hardware] = nil
    let returnedWithOldUUID = DisplayIdentityMigration.OnlineDisplay(identity: hardware, legacyUUID: older,
                                                                     name: name, modes: [hidpi, native])
    check(afterReconnect.migrated(online: [returnedWithOldUUID], history: history) == afterReconnect,
          "A forgotten mode stays forgotten when the display returns with its old UUID")
    let historyWithUnknownNames = history + [
        event(newer, at: 0, name: ""), event(newer, at: 1, name: "  "),
        event(newer, at: 5, name: "Дисплей 42"), event(older, at: 6, name: "")
    ]
    check(orphaned.migrated(online: [philips], history: historyWithUnknownNames) == adopted,
          "Unknown history names neither block adoption nor change the ranking of known sightings")

    let sameName = DisplayIdentityMigration.OnlineDisplay(identity: other, legacyUUID: other,
                                                          name: name, modes: [hidpi])
    check(orphaned.migrated(online: [philips, sameName], history: history) == firstSighting,
          "same-name online displays prevent adoption")
    check(orphaned.migrated(online: [sameName], history: history) == orphaned,
          "UUID-only display keeps its existing behavior")
    let unreadable = DisplayIdentityMigration.OnlineDisplay(identity: other, legacyUUID: other,
                                                            name: nil, modes: [])
    check(orphaned.migrated(online: [philips, unreadable], history: history) == adopted,
          "An unreadable name does not count toward a duplicate name")
    check(orphaned.migrated(online: [philips], history: [event(unsupported, at: 3)]) == orphaned,
          "An unavailable mode keeps its UUID entry until the display offers it")
    check(orphaned.migrated(online: [philips], history: [event(newer, at: 2), event(newer, at: 1, name: "Other")]) == firstSighting,
          "conflicting historical names prevent adoption")
    var alreadySaved = orphaned
    alreadySaved.remembered[hardware] = native
    var savedAfterSighting = alreadySaved.migrated(online: [philips], history: history)
    var expectedSavedModes = adopted.remembered
    expectedSavedModes[hardware] = native
    check(savedAfterSighting.remembered == expectedSavedModes && savedAfterSighting.migratedHardwareIDs == [hardware],
          "The hardware preference wins and owned legacy entries are removed")
    savedAfterSighting.remembered[hardware] = nil
    check(savedAfterSighting.migrated(online: [philips], history: history) == savedAfterSighting,
          "Forgetting a mode after migration leaves no historical preference to adopt")
    let onlineLegacy = DisplayIdentityMigration.OnlineDisplay(identity: newer, legacyUUID: newer,
                                                              name: "Other", modes: [hidpi])
    check(orphaned.migrated(online: [philips, onlineLegacy], history: [event(newer, at: 2)]) == firstSighting,
          "an online UUID cannot be adopted as an orphan")
    let sameFingerprint = DisplayIdentityMigration.OnlineDisplay(identity: hardware, legacyUUID: other,
                                                                  name: "Other", modes: [hidpi])
    check(stored.migrated(online: [philips, sameFingerprint], history: history) == stored,
          "colliding hardware fingerprints prevent rewrites")
    check(stored.migrated(online: [], history: history) == stored, "offline settings stay intact")

    let historyOnly = DisplayIdentityMigration(remembered: [older: hidpi], profiles: [], topologies: [],
                                               brightnessGroup: [])
    let partialCatalog = DisplayIdentityMigration.OnlineDisplay(identity: hardware, legacyUUID: legacy,
                                                                name: name, modes: [native])
    check(historyOnly.migrated(online: [partialCatalog], history: [event(older, at: 1)]) == historyOnly,
          "a remembered mode missing from the first catalog waits for a later one")
    check(historyOnly.migrated(online: [philips], history: [event(older, at: 1)]).remembered == [hardware: hidpi],
          "the waiting mode is adopted once the display offers it")

    let changedSerial = "hw-16652-49780-3467276838"
    let spareSerial = "hw-16652-49780-123"
    let afterWake = DisplayIdentityMigration.OnlineDisplay(identity: changedSerial, legacyUUID: newer,
                                                           name: name, modes: [])
    var beforeWake = migrated
    beforeWake.migratedHardwareIDs.insert(changedSerial)
    beforeWake.topologies.insert(
        DisplayTopology(identities: [other, hardware], orientations: [hardware: .left], mirrors: [other: hardware]),
        at: 0)
    let afterSerialChange = beforeWake.migrated(online: [afterWake], history: [])
    var rekeyedProfile = expectedProfile
    rekeyedProfile.screens = [DisplayProfile.Screen(id: changedSerial, name: saved.name, mode: saved.mode,
                                                    origin: saved.origin, isMain: saved.isMain, color: saved.color)]
    check(afterSerialChange.remembered == [changedSerial: hidpi, other: native]
            && afterSerialChange.rememberedHDR == [changedSerial: false, other: true]
            && afterSerialChange.profiles == [rekeyedProfile]
            && afterSerialChange.topologies == [
                DisplayTopology(identities: [other, changedSerial],
                                orientations: [changedSerial: .right, other: .left], mirrors: [changedSerial: other])
            ] && afterSerialChange.brightnessGroup == [changedSerial, other]
            && afterSerialChange.migratedHardwareIDs == beforeWake.migratedHardwareIDs,
          "a changed serial moves all settings and deduplicates topologies even after UUID migration")
    check(afterSerialChange.migrated(online: [afterWake], history: [event(hardware, at: 1)]) == afterSerialChange,
          "serial migration is idempotent")
    var mixedIdentities = beforeWake
    mixedIdentities.migratedHardwareIDs.remove(changedSerial)
    mixedIdentities.remembered[unsupported] = unavailable
    let readyAfterWake = DisplayIdentityMigration.OnlineDisplay(identity: changedSerial, legacyUUID: newer,
                                                                name: name, modes: [hidpi])
    let mixedHistory = [event(unsupported, at: 1)]
    check(mixedIdentities.migrated(online: [readyAfterWake], history: mixedHistory) == afterSerialChange,
          "serial and UUID migration finish in one pass when a remembered serial and legacy UUID coexist")

    let secondPhilips = DisplayIdentityMigration.OnlineDisplay(identity: spareSerial, legacyUUID: nil,
                                                               name: name, modes: [])
    check(beforeWake.migrated(online: [afterWake, secondPhilips], history: [event(hardware, at: 1)]) == beforeWake,
          "two online displays of the same product prevent serial migration")
    var savedUnderNewSerial = beforeWake
    savedUnderNewSerial.remembered[changedSerial] = native
    check(savedUnderNewSerial.migrated(online: [afterWake], history: [event(hardware, at: 1)]) == savedUnderNewSerial,
          "existing remembered settings for the new serial prevent all serial migration")
    savedUnderNewSerial.remembered[changedSerial] = nil
    savedUnderNewSerial.profiles.append(rekeyedProfile)
    check(savedUnderNewSerial.migrated(online: [afterWake], history: []) == savedUnderNewSerial,
          "a reference in a profile alone protects the new serial")

    var multipleSerials = migrated
    multipleSerials.migratedHardwareIDs = beforeWake.migratedHardwareIDs
    multipleSerials.remembered[spareSerial] = native
    let serialHistory = [event(hardware, at: 2), event(spareSerial, at: 4), event(changedSerial, at: 5)]
    var expectedSerials = multipleSerials
    expectedSerials.remembered.removeValue(forKey: spareSerial)
    expectedSerials.remembered[changedSerial] = native
    check(multipleSerials.migrated(online: [afterWake], history: serialHistory) == expectedSerials,
          "the newest stored serial in history wins and settings for the other serial remain")
    check(multipleSerials.migrated(online: [afterWake], history: [event(changedSerial, at: 5)]) == multipleSerials,
          "multiple stored serials without a history match prevent serial migration")

    var forgottenBeforeWake = beforeWake
    forgottenBeforeWake.remembered.removeValue(forKey: hardware)
    var expectedAfterForget = afterSerialChange
    expectedAfterForget.remembered.removeValue(forKey: changedSerial)
    check(forgottenBeforeWake.migrated(online: [afterWake], history: [event(hardware, at: 1)]) == expectedAfterForget,
          "a serial change preserves the other settings without resurrecting a forgotten mode")
    forgottenBeforeWake.profiles = []
    forgottenBeforeWake.topologies = []
    forgottenBeforeWake.brightnessGroup = []
    let hdrOnly = forgottenBeforeWake.migrated(online: [afterWake], history: [])
    check(hdrOnly.rememberedHDR == [changedSerial: false, other: true] && hdrOnly.remembered == [other: native],
          "a saved HDR preference alone follows the new serial without restoring a forgotten mode")
    forgottenBeforeWake.rememberedHDR = [:]
    check(forgottenBeforeWake.migrated(online: [afterWake], history: [event(hardware, at: 1)]) == forgottenBeforeWake,
          "a history row alone cannot resurrect a forgotten serial")
}
