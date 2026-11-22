import Foundation

func displayRestoreTests() {
    let fingerprint = DisplayHardwareFingerprint(vendor: 12, model: 34, serial: 56)
    let otherModel = DisplayHardwareFingerprint(vendor: 12, model: 35, serial: 56)
    let noSerial = DisplayHardwareFingerprint(vendor: 12, model: 34, serial: 0)
    let noVendor = DisplayHardwareFingerprint(vendor: 0, model: 34, serial: 56)
    check(fingerprint.identity(among: [], uuid: "first-uuid") == "hw-12-34-56", "Unique serial uses hardware identity")
    check(fingerprint.identity(among: [otherModel], uuid: "first-uuid") == "hw-12-34-56", "Serial shared by different models is safe")
    check(fingerprint.identity(among: [fingerprint], uuid: "first-uuid") == "first-uuid", "First display in collision uses its UUID")
    check(fingerprint.identity(among: [fingerprint], uuid: "second-uuid") == "second-uuid", "Second display in collision uses its UUID")
    check(fingerprint.identity(among: [fingerprint], uuid: nil) == nil, "Collision with no UUID does not reuse the fingerprint")
    check(noSerial.identity(among: [], uuid: "first-uuid") == "first-uuid", "Missing serial uses UUID")
    check(noVendor.identity(among: [], uuid: "first-uuid") == "first-uuid", "Missing vendor uses UUID")

    let historyName = DisplayHistoryEntry.Screen.displayName
    check(historyName("Philips", "HP", "42") == "Philips", "History prefers the current name")
    check(historyName("  ", "HP", "42") == "HP", "History uses the last known name")
    check(historyName("Дисплей 42", "HP", "42") == "HP", "History prefers a real name to a generated name")
    check(historyName("", nil, "42") == "Дисплей 42", "History falls back to the display ID")

    let beforeWake: [UInt32: String] = [1: "A", 11: "B", 13: "C"]
    let afterWake: [UInt32: String] = [1: "A", 12: "B"]
    let online = Set(afterWake.values)
    var pending = PendingDisplayRestore(targets: Set(beforeWake.values), waitUntil: 3.5)
    check(pending.takeReady(online: ["A"], available: ["A"], at: 2) == .waiting(until: 3.5),
          "Missing identities get the readiness grace period")
    check(pending.takeReady(online: online, available: online, at: 3.5) == .ready(["A", "B"]) && pending.targets.isEmpty,
          "A display returning under CG ID 12 restores by identity and the absent display leaves the queue")
    var missing = PendingDisplayRestore(targets: ["C"], waitUntil: 3.5)
    check(missing.takeReady(online: online, available: online, at: 3.5) == .ready([]) && missing.targets.isEmpty,
          "An entirely absent queue clears at the deadline")
    var unready = PendingDisplayRestore(targets: ["A", "B", "C"], waitUntil: 3.5)
    check(unready.takeReady(online: online, available: ["A"], at: 3.5) == .ready(["A"]) && unready.targets == ["B"],
          "Only an online display without a ready mode remains pending")
    check(unready.takeReady(online: online, available: online, at: 4) == .ready(["B"]) && unready.targets.isEmpty,
          "The remaining display restores as soon as its mode is ready")

    var layout = PendingDisplayRestore(targets: ["A", "B"], waitUntil: 3.5)
    layout.confirm(modes: [], changesLayout: true)
    check(layout.targets == ["A", "B"] && !layout.allowsProfile
            && layout.takeReady(online: online, available: online, at: 2) == .ready(["A", "B"]),
          "A layout-only preview preserves all mode targets and blocks the auto profile")
    var mode = PendingDisplayRestore(targets: ["A", "B"], waitUntil: 3.5)
    mode.confirm(modes: ["A"], changesLayout: false)
    check(mode.targets == ["B"] && !mode.allowsProfile
            && mode.takeReady(online: online, available: online, at: 2) == .ready(["B"]),
          "Only the confirmed mode leaves the queue and the auto profile cannot overwrite it")

    let hw = "hw-12-34-56"
    let uuid = "first-uuid"
    func match(_ identity: String, id: UInt32, online: [(id: UInt32, identity: String)]) -> UInt32? {
        matchSnapshotDisplay(identity: identity, fallbackID: id, among: online, identityOf: \.identity, idOf: \.id)?.id
    }
    check(match(hw, id: 11, online: [(11, uuid), (12, hw)]) == 12, "Snapshot prefers identity over the old CG ID")
    check(match(hw, id: 11, online: [(11, uuid)]) == 11, "Snapshot falls back from hardware identity to UUID")
    check(match(uuid, id: 11, online: [(11, hw)]) == 11, "Snapshot falls back from UUID to hardware identity")
    check(match(uuid, id: 11, online: [(12, hw)]) == nil, "Snapshot fallback requires the same online CG ID")

    var verification = DisplayVerificationWindow()
    verification.start(for: ["A"], now: 0)
    verification.start(for: ["B"], now: 4)
    check(verification.identities == ["A", "B"] && verification.deadline == 10, "Attaching B keeps A's original deadline")
    verification.expire(at: 9.9)
    check(verification.identities == ["A", "B"], "A mode notification leaves verification active until the deadline")
    verification.expire(at: 10)
    check(verification.identities == ["B"] && verification.deadline == 14, "The final check expires only the due displays")
    verification.cancel()
    check(verification.identities.isEmpty && verification.deadline == nil, "Manual configuration cancels verification")
    verification.start(for: ["A", "B"], now: 15, allowsProfile: layout.allowsProfile)
    verification.start(for: ["C"], now: 16)
    check(verification.identities == ["A", "B", "C"] && verification.profileIdentities == ["C"],
          "A layout confirmation keeps remembered-mode verification without making the auto profile eligible")
}
