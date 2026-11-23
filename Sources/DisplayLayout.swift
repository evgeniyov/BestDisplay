import Foundation

struct DisplayLayout: Codable, Equatable {
    let main: String
    let origins: [String: CGPoint]

    var identities: [String] { origins.keys.sorted() }

    init?(main: String, origins: [String: CGPoint]) {
        guard let origin = origins[main] else { return nil }
        self.main = main
        self.origins = origins.mapValues { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
    }

    func rekeyed(using identity: (String) -> String) -> Self? {
        let pairs = origins.map { (identity($0.key), $0.value) }
        let rekeyed = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        guard pairs.count == rekeyed.count else { return nil }
        return Self(main: identity(main), origins: rekeyed)
    }

    func shouldRestore(over current: Self, profileTakesPriority: Bool, suppressed: Bool) -> Bool {
        !profileTakesPriority && !suppressed && identities == current.identities && self != current
    }

    func shouldLearn(after previous: Self?, isVerifying: Bool) -> Bool {
        !isVerifying && previous?.identities == identities && previous != self
    }
}
