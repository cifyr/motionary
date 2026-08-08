# Installing Motionary

From a fresh clone to an animated widget on your Home Screen. Budget about
twenty minutes, most of it waiting for builds.

- [What you need](#what-you-need)
- [1. Clone and generate the project](#1-clone-and-generate-the-project)
- [2. Make it yours](#2-make-it-yours)
- [3. Check it builds](#3-check-it-builds)
- [4. Build your first design](#4-build-your-first-design)
- [5. Put it on the phone](#5-put-it-on-the-phone)
- [6. Set the wallpaper and place the widget](#6-set-the-wallpaper-and-place-the-widget)
- [Troubleshooting](#troubleshooting)

## What you need

| | |
|---|---|
| macOS | 14 or later |
| Xcode | Any version carrying the iOS 26+ SDK, with a matching simulator installed |
| XcodeGen | `brew install xcodegen` |
| iPhone | **iPhone 17 Pro**, iOS 26+ — the only calibrated device |
| Apple ID | Any account that can sign a development build |

A free Apple ID works. It gives seven-day provisioning, so the app stops
launching after a week and you reinstall it. A paid Developer Program membership
gives a year.

`ffmpeg` and Python 3 are only needed by the analysis scripts in `Tools/`.

> **Why the device list is so short.** The widget's frame on screen is measured
> against real hardware, not derived from Apple's published sizes — deriving it
> put the origin 7.33pt out on the one device that was checked, which showed as
> the whole composition sitting 22px to the right of the wallpaper behind it. An
> uncalibrated device will look wrong in exactly that way. See
> [Adding a device](USAGE.md#adding-a-device).

## 1. Clone and generate the project

```sh
git clone <your-fork-url> motionary
cd motionary
xcodegen generate
```

`Motionary.xcodeproj` is generated from `project.yml` and is never committed.
You will regenerate it often — **any time files are added, moved or renamed, and
any time a design is built**, because the project lists fonts by name.

## 2. Make it yours

Five things reference an identity that is not yours. Change all of them, or
signing will fail and the app group will not resolve.

**`project.yml`** — your team, and a bundle prefix you own:

```yaml
options:
  bundleIdPrefix: com.example          # was com.caden
settings:
  base:
    DEVELOPMENT_TEAM: XXXXXXXXXX       # your 10-character Team ID
```

Then update each `PRODUCT_BUNDLE_IDENTIFIER` in the same file — they are written
out in full rather than derived from the prefix:

```
com.example.Motionary
com.example.Motionary.widget
com.example.MotionaryTests
com.example.MotionaryStudio
com.example.MotionaryUITests
```

**`App/Motionary.entitlements`** and **`Widget/MotionaryWidget.entitlements`** —
the app group, which must match between the two:

```xml
<key>com.apple.security.application-groups</key>
<array><string>group.com.example.Motionary</string></array>
```

**`Shared/Storage/DesignStore.swift`** — the same group, in code:

```swift
static let appGroupIdentifier = "group.com.example.Motionary"
```

Your Team ID is in the Apple Developer portal under Membership, or in Xcode
under Settings → Accounts → Manage Certificates.

Regenerate after editing:

```sh
xcodegen generate
```

## 3. Check it builds

Before involving a phone, confirm the pipeline is healthy:

```sh
xcodebuild -scheme Motionary \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:MotionaryTests test

xcodebuild -scheme MotionaryStudio -destination 'platform=macOS' build
```

Both should succeed on a fresh clone. **A fresh clone has no designs in it** —
`Resources/prebuilt-*` and `MFont*.ttf` are build output, roughly 60MB per
design, so they are not committed. Tests that need a bundled design skip
themselves and say so. If you install the app now it will say "No design is built
into this app yet", which is correct.

## 4. Build your first design

Open Motionary Studio:

```sh
open ~/Library/Developer/Xcode/DerivedData/Motionary-*/Build/Products/Debug/MotionaryStudio.app
```

Then:

1. **Drop in a clip.** MP4, MOV or GIF. Short and loopable works best — the loop
   is capped at 320 frames, and a clip that does not divide the 30-second cycle
   gets one visible jump at the wrap.
2. **Position it** on the phone-shaped canvas. What lands inside the widget frame
   animates; what falls outside becomes wallpaper.
3. **Place app tiles** where you want launchers. They are drawn live over the
   animation, so they stay sharp and stay tappable.
4. **Press build.**

Studio extracts the frames, measures how much of the widget actually moves,
encodes only that region, writes the lane fonts, and copies everything into
`Resources/` as `prebuilt-*`.

The same thing headless, which is how it gets tested:

```sh
MotionaryStudio --build clip.mp4              # generate only, install nothing
MotionaryStudio --build clip.mp4 --bundle     # generate and compile into the app
```

`MotionaryStudio` here is the binary inside the app bundle:
`MotionaryStudio.app/Contents/MacOS/MotionaryStudio`.

## 5. Put it on the phone

Connect the iPhone by cable and trust the Mac. Find its identifier:

```sh
xcrun devicectl list devices
```

Then either press install in Studio, or:

```sh
MotionaryStudio --build clip.mp4 --device <UDID>
```

That regenerates the project, builds for the device, installs and launches. The
first run on a new machine may need you to accept the development certificate on
the phone: **Settings → General → VPN & Device Management → Developer App →
Trust**.

## 6. Set the wallpaper and place the widget

This is the step that makes the illusion work, and it is easy to skip.

1. **Open the Motionary app on the phone.** It shows the design as it will look.
2. **Tap the save button** (bottom right). It writes the wallpaper to Photos and
   tells you: *"Saved to Photos. Set it as your wallpaper, then place the widget
   over it."*
3. **Set it as your wallpaper** — Settings → Wallpaper → Add New Wallpaper →
   Photos, and pick it. Turn **off** any zoom or parallax; the composition is cut
   to exact pixels and a crop will shift it.
4. **Add the widget.** Long-press the Home Screen → Edit → Add Widget →
   Motionary, and choose the full-screen portrait size.
5. **Line it up.** The widget must sit in the top slot the design was cut for.

The widget's picture and the wallpaper behind it are two halves of one image. If
they are a few pixels out you will see a seam — that is a geometry problem, not
a rendering one, and [Usage](USAGE.md#the-composition-is-misaligned) covers it.

## Troubleshooting

**"No design is built into this app yet"**
No design is compiled into the build you installed. Build one in Studio, then
reinstall. If you *did* build one, you probably did not regenerate the project —
`xcodegen generate`, then build again.

**The widget is black**
Almost always the fonts. A font only draws if it was in the extension's bundle at
install time *and* declared in `UIAppFonts`. Studio writes both; a stale
`.xcodeproj` breaks the link. Regenerate, rebuild, reinstall. If it persists, the
app's diagnostics report which lanes resolved — see
[Usage](USAGE.md#the-widget-is-black).

**Signing fails**
The team, the bundle identifiers and the app group all have to be yours and
consistent. Re-read [step 2](#2-make-it-yours). A free Apple ID cannot use some
capabilities and expires the build after seven days.

**`xcodegen: command not found` from inside Studio**
Studio looks in `/opt/homebrew/bin` and `/usr/local/bin` as well as `PATH`,
because a GUI app does not inherit a shell's environment. If Homebrew is
somewhere else, launch Studio from a terminal so it inherits your `PATH`.

**The app stops launching after a week**
Free provisioning expires after seven days. Reinstall.
