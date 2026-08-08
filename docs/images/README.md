# Documentation images

## What is here

| File | What it is | How it was made |
|---|---|---|
| `design-spidey.gif` | A design animating across the full screen | `Tools/make-gif.sh` from the design's own preview video |
| `app-viewer.png` | The iPhone app showing a design and its tiles | Simulator screenshot |

## Regenerating the animation

The pipeline writes a full-screen preview video of every design it builds, and
that video *is* what the widget plays — so it is the honest source for an
animated image, and it needs neither a phone nor a simulator:

```sh
Tools/make-gif.sh Resources/prebuilt-<id>-preview.mp4 docs/images/design.gif 8 300
```

Keep these small. A 300px, 8-second, 12fps GIF of a full-screen design lands
around 150KB; the same clip at 600px is several megabytes and makes the README
slow to open.

## Regenerating the app screenshot

```sh
xcrun simctl boot "iPhone 17 Pro"
xcrun simctl install booted <path to Motionary.app>
xcrun simctl launch booted com.caden.Motionary -MotionaryDesignIndex 0
xcrun simctl io booted screenshot --type=png app-viewer.png
```

`-MotionaryDesignIndex 0` picks the first bundled design in the order Studio
wrote them, so a screenshot can be taken of a specific one without tapping
through the picker.

**The app must have a design compiled into it.** A fresh clone has none, and the
app will correctly say "No design is built into this app yet". If you have built
one and still see that, the Xcode project is stale — run `xcodegen generate` and
build again.

## Still wanted

Two images would improve the README and are easiest to capture by hand:

- **The Studio editor**, showing a clip positioned on the phone canvas with tiles
  placed. Screenshot the window with `⌘⇧4` then space.
- **The widget on a real Home Screen**, photographed or screenshotted from the
  calibrated iPhone. The simulator is a poor substitute here: it carries test
  artefacts on its Home Screen, and the full-screen portrait widget family is the
  point of the project.
