import Foundation

extension DisplayProfile.Screen {
    init(_ display: Display) {
        self.init(id: display.identity, name: display.title, mode: display.current.key,
                  origin: display.bounds.origin, isMain: display.isMain, color: display.color)
    }
}

extension DisplayProfile {
    func matches(_ displays: [Display]) -> Bool {
        Self.canCapture(displays) && displays.count == screens.count
            && displayIDs == Set(displays.map(\.identity))
    }

    func isApplied(to displays: [Display]) -> Bool {
        matches(displays) && screens.allSatisfy { saved in
            displays.contains { display in
                display.identity == saved.id && display.current.key == saved.mode
                    && display.bounds.origin == saved.origin && display.isMain == saved.isMain
                    && (saved.color == nil || display.color == saved.color)
            }
        }
    }

    static func canCapture(_ displays: [Display]) -> Bool {
        !displays.isEmpty && displays.allSatisfy { !$0.isVirtual && !$0.isInMirrorSet && !$0.identity.hasPrefix("session-") }
            && Set(displays.map(\.identity)).count == displays.count
            && displays.filter(\.isMain).count == 1
    }
}
