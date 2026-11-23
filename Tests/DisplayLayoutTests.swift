import Foundation

func displayLayoutTests() {
    let external = CGPoint(x: 1500, y: 100)
    let laptop = CGPoint(x: 100, y: 220)
    let saved = DisplayLayout(main: "External", origins: ["Laptop": laptop, "External": external])!
    let current = DisplayLayout(main: "Laptop", origins: ["External": external, "Laptop": laptop])!
    let single = DisplayLayout(main: "Laptop", origins: ["Laptop": .zero])!
    let shifted = DisplayLayout(main: "External", origins: [
        "Laptop": CGPoint(x: -1400, y: 120), "External": .zero
    ])!

    check(saved.identities == ["External", "Laptop"] && saved.identities == current.identities,
          "Layout key is sorted and independent of the main display")
    check(saved.origins == ["External": .zero, "Laptop": CGPoint(x: -1400, y: 120)] && saved == shifted,
          "Layout origins are relative to the main display")
    let decoded = try? JSONDecoder().decode(DisplayLayout.self, from: JSONEncoder().encode(saved))
    check(decoded == saved, "Remembered layout survives a storage round trip")

    check(saved.shouldLearn(after: current, isVerifying: false), "Learns a change on the same set")
    check(!saved.shouldLearn(after: current, isVerifying: true), "Does not learn during verification")
    check(!saved.shouldLearn(after: single, isVerifying: false), "Does not learn after the set changes")
    check(!saved.shouldLearn(after: nil, isVerifying: false), "First observation only establishes a baseline")
    check(!saved.shouldLearn(after: shifted, isVerifying: false), "Does not learn an unchanged arrangement")

    check(saved.shouldRestore(over: current, profileTakesPriority: false, suppressed: false),
          "Restores a different arrangement on the same set")
    check(!saved.shouldRestore(over: shifted, profileTakesPriority: false, suppressed: false),
          "Does not restore a matching arrangement")
    check(!saved.shouldRestore(over: single, profileTakesPriority: false, suppressed: false),
          "Does not restore on another display set")
    check(!saved.shouldRestore(over: current, profileTakesPriority: true, suppressed: false),
          "Defers to a matching automatic profile")
    check(!saved.shouldRestore(over: current, profileTakesPriority: false, suppressed: true),
          "Does not retry a failed layout restore in the same verification window")
}
