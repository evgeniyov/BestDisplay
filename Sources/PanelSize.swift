struct PanelSize: Equatable {
    let dimensions: Dimensions?
    var isInferred = false
}

func detectPanelSize(
    edid: Dimensions?, nativeFormat: Dimensions?, nativeFlag: Dimensions?,
    oneXModes: [ModeKey], builtIn: Bool
) -> PanelSize {
    if let size = edid ?? nativeFormat { return PanelSize(dimensions: size) }
    let fallback = PanelSize(dimensions: nativeFlag)
    guard !builtIn, let nativeFlag else { return fallback }

    let nativeRates = oneXModes.filter { $0.desktop == nativeFlag }.map(\.millihertz)
    guard !nativeRates.isEmpty, nativeRates.allSatisfy({ (1...60_000).contains($0) }) else {
        return fallback
    }
    let candidates = oneXModes.filter {
        $0.millihertz >= 100_000 && $0.desktop.area < nativeFlag.area
    }
    guard let size = panelSizes(from: candidates, matching: nativeFlag).first else { return fallback }
    return PanelSize(dimensions: size, isInferred: true)
}

func panelSizes(from oneXModes: [ModeKey], matching reference: Dimensions) -> [Dimensions] {
    Set(oneXModes.map(\.desktop).filter { $0.matchesAspect(of: reference) }).sorted {
        $0.area == $1.area ? $0.width > $1.width : $0.area > $1.area
    }
}
