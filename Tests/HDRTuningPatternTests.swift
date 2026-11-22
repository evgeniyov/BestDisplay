func hdrTuningPatternTests() {
    check(HDRTuningPattern.shadows == [0.005, 0.01, 0.02, 0.04, 0.08], "HDR shadows use the specified fractions of SDR white")
    check(zip(HDRTuningPattern.shadows, HDRTuningPattern.shadows.dropFirst()).allSatisfy(<), "HDR shadow patches get brighter left to right")
}
