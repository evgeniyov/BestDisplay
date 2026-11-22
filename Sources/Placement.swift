import CoreGraphics

enum Placement: String, CaseIterable {
    case left = "Слева"
    case right = "Справа"
    case above = "Сверху"
    case below = "Снизу"

    func origin(for display: CGRect, relativeTo primary: CGRect) -> CGPoint {
        switch self {
        case .left: CGPoint(x: primary.minX - display.width, y: primary.minY)
        case .right: CGPoint(x: primary.maxX, y: primary.minY)
        case .above: CGPoint(x: primary.minX, y: primary.minY - display.height)
        case .below: CGPoint(x: primary.minX, y: primary.maxY)
        }
    }
}
