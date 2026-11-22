import Foundation

@MainActor
func displayReport(_ screens: [Display]) -> String {
    let os = ProcessInfo.processInfo.operatingSystemVersionString
    let summary = screens.map { display in
        let state = display.isMain ? ", основной" : ""
        let panel = display.panel.map { "\($0.label) пикс." } ?? "не определена"
        let rendering = display.current.key.rendering.label
        let edr = display.edr.map { $0 > 1 ? "поддерживается" : "SDR" } ?? "нет данных"
        let origin = "\(Int(display.bounds.minX)), \(Int(display.bounds.minY))"
        return """
        \(display.title) (\(display.category.lowercased())\(state))
          Режим: \(display.current.key.label)
          Изображение macOS: \(rendering) пикс. Панель: \(panel).
          Положение: \(origin). EDR: \(edr). Доступно режимов: \(display.modes.count)
        \(display.recommendations.map { "  \($0.0): \($0.1.key.label)" }.joined(separator: "\n"))
        """
    }.joined(separator: "\n\n")
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    return "BestDisplay \(version), macOS \(os)\n\n\(summary)"
}
