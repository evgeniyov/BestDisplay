import CoreGraphics
import Foundation

// Minimal stand-in so the production files under test compile without the whole app.
struct DisplayFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

nonisolated(unsafe) var failures = 0
func check(_ condition: Bool, _ name: String) {
    if !condition {
        failures += 1
        print("FAIL: \(name)")
    }
}

cubeLUTTests()
profileURLTests()
hardwareOptionsTests()
placementTests()
cecTests()
displayIdentityMigrationTests()
displayRestoreTests()

if failures > 0 {
    print("\(failures) test(s) failed")
    exit(1)
}
print("All tests passed")
