<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Icon/AppIcon-dark.png">
    <img src="Icon/AppIcon-light.png" width="128" alt="NitSync icon">
  </picture>
</p>

<h1 align="center">NitSync</h1>

<p align="center">
  Make your external monitor follow your MacBook's display brightness, matched in nits rather than percent.
</p>

<p align="center">
  <b>English</b> · <a href="README.ja.md">日本語</a> · <a href="README.zh-Hans.md">简体中文</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-required-555555" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license">
</p>

---

When you press the brightness keys, drag the Control Center slider or let auto-brightness do its thing, only the MacBook's own display changes. NitSync makes the external monitor follow, with the same smooth fade, so both screens stay equally bright. It lives in the menu bar and doesn't intercept keys or draw its own HUD.

## Features

- **Matched in nits.** NitSync reads the built-in panel's actual white level and drives the external monitor to the same luminance, not to the same percentage.
- **SDR and HDR monitors.** In SDR it sets the monitor's backlight over DDC/CI. In HDR, where the monitor ignores DDC, it sets the SDR white level macOS renders, which is in absolute nits and needs no calibration.
- **Smooth following.** It wakes on the system's brightness change notification before a fade starts and follows the built-in display's curve at 120 Hz. Idle CPU is under 0.1 %.
- **Color calibration against the built-in display.** Match the external's white point, three gray levels (tint and lightness) and red/green/blue primaries by eye, using forced-choice questions that are robust to noisy judgments.
- **Stored in an ICC profile.** Color corrections are written into a profile for the external display, so they apply system-wide and keep working when NitSync isn't running.
- **Per-monitor.** Monitors are told apart by their EDID, so each keeps its own calibration across ports and reconnects.
- **Localized** in English, Japanese, Simplified Chinese and Traditional Chinese.

## Requirements

- A Mac with Apple Silicon (DDC/CI goes through the Apple Silicon display pipeline).
- macOS 14 or later.
- An external monitor that supports DDC/CI, with DDC/CI enabled in its on-screen menu. In HDR mode DDC is only used to find the monitor.

## Installation

Download `NitSync-<version>.zip` from the [latest release](https://github.com/shiinayane/NitSync/releases/latest), unzip it and move **NitSync.app** to **Applications**. The app is signed with a Developer ID and notarized by Apple.

Open it once; a sun icon appears in the menu bar. Choose **Open at Login** in its menu to start it automatically.

## Usage

The menu shows the built-in display's current luminance and, for each external monitor, whether it's driven in **SDR** (the DDC value it was sent) or **HDR** (the SDR white level in nits).

### Brightness calibration (SDR monitors)

In SDR, NitSync has to translate nits into the monitor's DDC brightness value. Until you calibrate, it estimates from the monitor's EDID.

Choose **Brightness Calibration…**. Every screen shows a white patch of the same physical size on a dark background:

1. Press ←/→ until both patches look equally bright, then press ⏎.
2. Use the brightness keys to make the built-in display clearly darker (the screen suggests a level), match again and save.
3. Press Esc.

Points are interpolated in nits; add more if brightness in between still doesn't match. HDR monitors don't need this step.

<p align="center"><img src="docs/brightness-calibration.png" width="720" alt="Brightness calibration screen"></p>

### Color calibration

Two panels built with different technologies can look different even when both claim D65 white, and once white matches, dark grays may still be tinted. Color calibration uses the built-in display as the reference and adjusts the external display to match what *you* see.

Choose **Color Calibration…**, then:

| Key | Measures | Time |
|---|---|---|
| **W** | White: warmer/cooler, greener/more magenta | about 1 min |
| **G** | Grays at 50 %, 25 % and 12 %: tint, and lightness against a white frame | about 4 min |
| **P** | sRGB red, green and blue: hue and saturation | about 3 min |

Each question is a two-way choice ("Compared with the built-in display, which way does the external's white lean?"), answered with ←/→, or ↓ when you can't tell. Adaptive staircases close in on the match from a random starting side, the patches go dark between questions so you never see which way a color moved, and no numbers are shown while you answer. Every run can be saved or redone. Saved runs are averaged (up to five per item), and later runs are checked against earlier ones. Press ⌫ twice to clear all color calibration.

<p align="center"><img src="docs/color-calibration.png" width="720" alt="Color calibration: a gray level"></p>

This matches the two screens for your eyes. It doesn't make the external display colorimetrically accurate; that needs a colorimeter.

## How it works

- **Built-in luminance.** The built-in panel's framebuffer reports its SDR white level in nits (`IOMFBBrightnessLevel`). macOS's private DisplayServices notifies before a brightness change starts, which wakes NitSync's sampling loop.
- **SDR.** NitSync writes the monitor's brightness (VCP 0x10) over DDC/CI through `IOAVService`, mapped from nits by your calibration.
- **HDR.** The signal is PQ-encoded absolute luminance, so the monitor locks its own brightness and macOS decides where SDR white sits. NitSync sets that level through DisplayServices and corrects it from the external framebuffer's reading.
- **Color.** White and gray corrections go into the profile's `vcgt` table, which macOS loads into the display's gamma table. Primaries go into the profile's colorants, which color management uses. The profile, named "<monitor> (NitSync)", is a copy of the display's factory profile and is stored in `~/Library/ColorSync/Profiles/NitSync/`.

## Building from source

Needs the Xcode command line tools.

```bash
./build.sh
open build/NitSync.app
```

`build.sh` compiles with `swiftc` and signs ad hoc, so the result only runs on your own Mac. Translations live in `Localization/translations.json`; the build generates the `.strings` files from it and fails if a string is missing or a placeholder doesn't match. The app icon is an Icon Composer document (`Icon/AppIcon.icon`); `Icon/build-icon.sh` rebuilds its compiled form (Xcode 26 or later).

### Releasing

```bash
./release.sh            # sign, notarize, staple, zip into dist/
./release.sh --install  # …and install to /Applications
```

`release.sh` uses the first Developer ID Application certificate in your keychain and a notarytool keychain profile named `NitSync`, which you create once:

```bash
xcrun notarytool store-credentials NitSync --apple-id <Apple ID> --team-id <Team ID>
```

## Uninstalling

Turn off **Open at Login** and quit NitSync. Then remove the color calibration, which puts each display's original profile back, deletes NitSync's profiles and quits again:

```bash
open -a NitSync --args --reset-color
```

Finally move NitSync.app to the Trash. Its settings are in `~/Library/Preferences/local.nitsync.plist`.

## Limitations

- NitSync relies on private macOS interfaces (`IOAVService`, DisplayServices, framebuffer registry properties). A macOS update can break it.
- In HDR, macOS offers SDR white between about 4 and 200 nit; when the built-in display is brighter, the external stays at its maximum.
- DDC is slow, so following in SDR comes in visible steps of about 60 ms; HDR follows smoothly.
- If the monitor is in a preset that locks brightness, or another app (Lunar, MonitorControl, BetterDisplay…) also writes DDC, results will fight. Apps that rewrite gamma tables (f.lux…) override the white and gray correction.
- Primaries only affect color-managed content, which is nearly everything on macOS but not every game or video player.
- Color calibration has only been tested with an HDR external monitor; multiple external monitors haven't been tested on real hardware.

## License

[MIT](LICENSE)
