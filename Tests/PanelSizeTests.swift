func panelSizeTests() {
    let uhd = Dimensions(width: 3840, height: 2160)
    let qhd = Dimensions(width: 2560, height: 1440)
    let fullHD = Dimensions(width: 1920, height: 1080)
    let ultrawide = Dimensions(width: 3440, height: 1440)
    let intermediate = [
        Dimensions(width: 3360, height: 1890),
        Dimensions(width: 3200, height: 1800),
        Dimensions(width: 3008, height: 1692)
    ]

    func mode(_ size: Dimensions, hz: Int) -> ModeKey {
        ModeKey(desktop: size, rendering: size, millihertz: hz * 1000)
    }

    let philips = ([uhd] + intermediate + [qhd]).map { mode($0, hz: 60) }
        + [mode(qhd, hz: 120), mode(qhd, hz: 131)]
    func detect(
        _ modes: [ModeKey], edid: Dimensions? = nil, nativeFormat: Dimensions? = nil,
        nativeFlag: Dimensions? = uhd, builtIn: Bool = false
    ) -> PanelSize {
        detectPanelSize(edid: edid, nativeFormat: nativeFormat, nativeFlag: nativeFlag,
                        oneXModes: modes, builtIn: builtIn)
    }

    let native = PanelSize(dimensions: uhd)
    let inferred = PanelSize(dimensions: qhd, isInferred: true)
    check(detect(philips) == inferred, "Philips 4K at 60 Hz falls back to the 1440p panel")
    check(detect(philips, edid: uhd, nativeFormat: qhd) == native, "EDID takes precedence")
    check(detect(philips, nativeFormat: uhd) == native, "NativeFormat takes precedence")
    check(detect(philips + [mode(uhd, hz: 120)]) == native, "120 Hz native 4K is kept")
    check(detect(philips.filter { $0.millihertz < 100_000 }) == native, "No smaller high-refresh mode")
    check(detect(philips + [mode(fullHD, hz: 144), mode(ultrawide, hz: 144)]) == inferred,
          "Use the largest smaller high-refresh size with the same aspect")
    check(detect(philips.filter { $0.desktop != uhd }) == native, "Native size has no 1× timing")
    check(detect(philips + [mode(uhd, hz: 0)]) == native, "Unknown native refresh is not evidence")
    check(detect(philips, builtIn: true) == native, "Built-in keeps its native size")
    check(detect(philips, nativeFlag: nil) == PanelSize(dimensions: nil), "Missing native size stays unknown")
    check(panelSizes(from: philips + [mode(ultrawide, hz: 60)], matching: uhd) == [uhd] + intermediate + [qhd],
          "Manual sizes are distinct, match the aspect, and are largest first")
}
