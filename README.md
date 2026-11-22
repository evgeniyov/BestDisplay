# BestDisplay

BestDisplay is a macOS menu bar app for managing displays. It runs on Apple Silicon, makes no network requests and has no third-party dependencies.

The app's interface is in Russian. This README quotes each control as the app shows it and gives an English translation the first time.

## Getting started

Open BestDisplay and click the display icon on the right side of the menu bar. The panel lists every connected display, and you can switch between them.

### Scale and sharpness

For an HP 27f, the comparison section offers three modes at 75 Hz:

- **1920×1080 · 1×** draws the interface at the panel's physical resolution.
- **1920×1080 · HiDPI** keeps the interface size and draws it at 3840×2160 before scaling it down to the panel.
- **1600×900 · HiDPI** makes interface elements about 20% larger and draws them at 3200×1800.

Click **Проверить** (Test), compare small text, and click **Оставить** (Keep) if the mode suits you. If you don't confirm within 20 seconds, BestDisplay restores the previous settings. **Запомнить режим** (Remember mode) restores the confirmed mode for that display when BestDisplay starts, when the display connects and when screens wake, as long as macOS still offers the mode. BestDisplay also saves the mode in macOS, so macOS applies it on connection while the display keeps the same system identifier. To start BestDisplay at login, use the **⋯** menu.

If a monitor does not report its panel size, BestDisplay infers the size from the refresh rates of its 1× modes and labels it "по частоте обновления" (by refresh rate). Click the **Панель** (Panel) value to pick the size yourself.

### Connection profiles and history

On the **Профили** (Profiles) tab, click **Сохранить…** (Save…) and name the current configuration. BestDisplay saves the main display and each display's position, scale and refresh rate. To save a different set of displays, connect those displays first and save them as a separate profile.

Automatic profiles apply when BestDisplay starts and when displays connect, disconnect or wake. BestDisplay picks the profile that matches the exact set of connected displays, and the profile takes priority over modes remembered per display. **Применить** (Apply) lets you try a profile for 20 seconds with rollback. **Обновить…** (Update…) saves the current set again under the same profile.

The **История** (History) tab keeps the last 100 events on this Mac. Expand an event to see the modes before the restore, the requested modes and the modes macOS applied. The tab also shows when a saved mode became unavailable.

### Configuration protection and color

In a profile card, turn on **Защищать настройки во время работы** (Protect settings while running). BestDisplay then restores scale, refresh rate, main display, arrangement and ICC profiles after an outside change. A mode change you confirm in BestDisplay updates the protected profile. History shows each time protection ran and the result. For profiles saved in 0.2.1, click **Обновить…** to add the current ICC profiles.

On the **Расположение** (Arrangement) tab, the **Поворот** (Rotation) menu tests the orientation of a compatible external display and reverts after 20 seconds. **Восстанавливать поворот и видеоповтор** (Restore rotation and mirroring) saves the current layout for this set of physical displays, including extended desktop mode. Changes you confirm in BestDisplay update the saved layout.

On the **Управление** (Controls) tab, you can choose an RGB ICC file for a display and return to the factory profile. **Цвет рабочего стола и ICC** (Desktop color and ICC) changes gamma, contrast and per-channel RGB gain through the display's color table. **Снять фильтр** (Remove filter) restores the previous calibration. **Сохранить ICC…** (Save ICC…) writes a copy of the active profile with the new calibration table, and **Выбрать ICC…** (Choose ICC…) applies it. Sharpening and **3D LUT .cube** import, with values from 0 to 1 and sizes up to 64³, are available in picture-in-picture.

### Video inputs, brightness and sound

- **Управление** shows the available hardware controls and software dimming. BestDisplay reads brightness, contrast, volume and RGB gain over DDC/CI.
- **Прочитать DDC** (Read DDC) asks the monitor for its inputs and power modes. The app shows only the commands the monitor reports and asks for confirmation before it sends one. Switching inputs needs a second active display.
- **Передать яркость другим дисплеям** (Send brightness to other displays) copies the brightness of the selected monitor to the other compatible displays.
- **В группе яркости** (In brightness group) links the selected physical displays. Changes made in BestDisplay reach every connected member of the group. The group does not follow the monitor's hardware buttons or changes from other apps.
- **Системная громкость** (System volume) appears for the current audio output when CoreAudio allows changing its volume.

### HDR, XDR, HDMI-CEC and software volume

- **HDR / XDR** on the **Управление** tab shows the EDR headroom. The test draws SDR reference white next to two brighter patches through Metal. The HDR switch and the XDR reference profiles appear when macOS reports those features. The profiles use the display's built-in brightness limits. **Использовать HDR** (Use HDR) and **Запомнить режим** (Remember mode) save the display's HDR setting for the next launch, connection or wake.
- **HDMI-CEC** turns a TV on and off and selects its HDMI input from the Mac through a compatible USB-CEC adapter and `cec-client` from [libCEC](https://github.com/Pulse-Eight/libcec). With Homebrew installed, `brew install libcec` adds the tool. Click **Найти адаптеры** (Find adapters), choose an adapter and request the TV's state. If the input is detected wrong, choose its number in **HDMI-вход ТВ** (TV HDMI input). Power and input commands ask for confirmation.
- **Программная громкость** (Software volume) works on macOS 14.2 and later with an audio output that has one stereo stream and no input channels. After you turn it on, allow system audio capture if macOS asks, and play some sound. The slider attenuates the signal from 100% to 0% through Core Audio. Audio stays in memory. Switching the output, sleep and quitting BestDisplay turn the processing off.

### Picture-in-picture, mirroring and diagnostics

- In the **⋯** menu, **Картинка в картинке…** (Picture in picture…) opens the system source picker, where you choose a screen or a window. The stream plays locally, in a floating window or full screen. Closing the window stops the stream.
- **Расположение** lets you choose the main display, set where a neighboring display sits and create a temporary virtual desktop. **Показывать изображение с…** (Show image from…) tests mirroring, including mirroring a virtual display to a physical one, with a rollback timer.
- When the built-in display is the main display, you can disconnect a compatible external display in software. **Подключить** (Connect) on **Расположение** or in **⋯** brings the display back.
- **⋯** copies display diagnostics without serial numbers.
- **Все режимы** (All modes) opens the list of resolutions and refresh rates with search and a HiDPI filter.

## Terminal and Shortcuts

You can run the installed app's executable from Terminal or from the **Run Shell Script** action in the macOS Shortcuts app.

```sh
/Applications/BestDisplay.app/Contents/MacOS/BestDisplay --report
/Applications/BestDisplay.app/Contents/MacOS/BestDisplay --profiles
/Applications/BestDisplay.app/Contents/MacOS/BestDisplay --preview-profile "Ноутбук + HP 27f"
```

For the **Open URLs** action, use the `bestdisplay://profile?name=Desk%20%2B%20HP` scheme with the URL-encoded name of a saved profile. The URL opens the panel and starts a profile test. After you click **Оставить**, the settings last until you log out.

## Building and the DMG

You need Xcode with Swift 6 and an Apple Silicon Mac. The build targets macOS 14 and later. Hardware testing was done on an Apple M4 with macOS 27.2.1.

```sh
./Scripts/build.sh
open build/BestDisplay.app
BESTDISPLAY_SIGN_IDENTITY="BestDisplay Local" ./Scripts/package-dmg.sh
./Scripts/test.sh
```

`Scripts/test.sh` runs unit tests that need no displays. They cover `.cube` parsing, DDC capabilities, CEC, profile URLs, display identity migration, restore state and panel size detection. To regenerate the icon, run `swift Scripts/make-icon.swift`. [CHANGELOG.md](CHANGELOG.md) records the hardware tests. License: [MIT](LICENSE).

The disk image lands in `build/` and contains BestDisplay.app and an Applications shortcut. Install the app into that folder so macOS sees one path and one signature. The BestDisplay Local identity exists only on the author's Mac. On another Mac, pass the name of a signing identity available there in `BESTDISPLAY_SIGN_IDENTITY`. Without it, the build is signed ad hoc. Local images signed without an Apple Developer ID are not notarized.

HDR and XDR profile switching, rotation, hidden modes, hardware brightness, DDC/CI and virtual displays use macOS interfaces that Apple does not publish in the SDK. BestDisplay loads them at runtime, and whether they work depends on the macOS version and the hardware. References: [Apple Quartz Display Services](https://developer.apple.com/documentation/CoreGraphics/quartz-display-services), [displayplacer](https://github.com/jakehilborn/displayplacer), [m1ddc](https://github.com/waydabber/m1ddc), [virtual display in Chromium](https://chromium.googlesource.com/chromium/src/+/HEAD/ui/display/mac/test/virtual_display_util_mac.mm).
