# Changelog

## Unreleased

- BestDisplay remembers the main display and arrangement for each set of physical displays and restores them at launch, on connection and after wake, even when a display reports a different serial number.

- A wizard sets the monitor's HDR brightness with a shadow pattern and shows the HDR headroom macOS gives the monitor. Monitor contrast and color gains are locked while HDR is on.
- BestDisplay restores each display's saved HDR setting at launch, on connection and after wake, even if the display reports a different serial number.
- Saved display settings follow a monitor when its reported serial number changes and it is the only connected monitor of that model.
- External monitors that don't report their panel size get a size inferred from the refresh rates of their 1× modes. You can also pick the size by hand on the Scale tab.
- A remembered mode is also saved in macOS. macOS applies it when the display connects, even when BestDisplay isn't running, until macOS gives the display a new system identifier.
- Remembered modes, profiles, layout protection and the brightness group now survive reconnecting monitors that report a serial number. Old entries move over automatically. A remembered mode whose UUID changed can be recovered from the connection history.
- After launch, connection and wake, BestDisplay keeps checking saved modes and the automatic profile for 10 more seconds. History records a repeated change only when BestDisplay corrected it. A manual change ends the check.
- Restore waits for a running preview to finish. It handles displays that are ready even if macOS hasn't yet reported modes for the others. Configuration protection checks again after its pause.
- Software reconnect waits for the display without enumerating every mode, and it blocks other configuration changes until it finishes. BestDisplay's own virtual display no longer triggers the automatic profile when it connects or disconnects.
- Confirming a layout checks the requested coordinates and the chosen main display. When a display has no name, history uses its last known name or its display ID.
- Monitors that share a hardware identifier are told apart by UUID while both are connected.

## 0.5.1

- App icon, MIT license, and CI on GitHub Actions that runs the tests and a full build on `macos-26`.
- Fixed a Swift 6.1-6.3 compiler crash in IRGen. `Binding(get:set:)` received references to the `@MainActor` methods `setHDR` and `setLogin` instead of closures.
- Split an expression in the layout map so it stays under the type checker's limit.
- Added unit tests in `Scripts/test.sh`.
- HDMI-CEC caches the adapter list for 15 seconds, so commands go out faster.
- Split `DisplayManager`. `ScreenDimmer`, `Placement`, and the extensions for DDC brightness and the report now live in separate files.
- The remembered mode is saved through the shared `persist` helper. The report no longer shows a stale version.

## Hardware test for 0.4.0

On an HP 27f and the built-in Retina display, the tests covered rotation rollback, restoring orientation after an outside change, mirroring protection in both directions, writing a generated ICC profile, reading and resetting the HP's modified color table, and copying hardware brightness from the HP to the Retina display. Each test returned the original modes, layout, brightness and ICC profile.

## Hardware test for 0.5.0

On a MacBook Air M4, the built-in Retina display reached 2× active EDR headroom in the test window at 40% brightness. At the starting brightness of 100%, macOS reported 1× in this test. The starting brightness was restored afterward. The HP 27f runs in SDR, and in this setup external HDR switching and XDR profile selection are unavailable. Software volume was tested on the built-in speakers, and the original system output was kept. HDMI-CEC commands were tested against a libCEC test client. Testing on a TV needs a USB-CEC adapter.
