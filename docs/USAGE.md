# Using Motionary

Everything past a first successful install: how the editor works, every command
line flag, how to inspect a rendered widget, and what to do when it looks wrong.

- [The Studio workflow](#the-studio-workflow)
- [Command line reference](#command-line-reference)
- [Looking at the result](#looking-at-the-result)
- [Adding a device](#adding-a-device)
- [When it looks wrong](#when-it-looks-wrong)

## The Studio workflow

Motionary Studio is where a design is made. It is a Mac app because it has to be
— see [How it works](HOW-IT-WORKS.md#the-constraint-everything-follows-from).

### Choosing a clip

MP4, MOV and GIF all work. What matters:

- **Length.** The loop is capped at 320 frames. That is not a payload limit —
  every lane font embeds 15 frames whatever the loop length — but a bound on
  build-time memory, because the whole loop is decoded to full-screen RGBA at
  once, about 12.6MB a frame.
- **Looping.** The timer cycle is 30 seconds. A loop that divides the cycle
  evenly is seamless; one that does not gets a single visible jump at the wrap,
  every 30 seconds. Studio snaps to the nearest clean length and tells you.
- **Motion, not detail.** Only the part of the frame that actually moves is
  encoded into glyphs. A clip where a small object moves against a still
  background is dramatically cheaper than one where everything drifts.

### Positioning

The canvas is the phone. Drag and scale the clip on it. The widget frame is drawn
over the top:

- Inside the frame **animates**.
- Outside the frame becomes **wallpaper**, exported as a still.

The two are cut from the same picture, so a design usually wants to place the
interesting motion inside the frame and let scenery run out past it.

### Tiles

Tiles are app launchers drawn live over the animation by SwiftUI, not baked into
the frames. That means they stay sharp, stay tappable, and can be changed on the
phone without a rebuild. Artwork comes from SF Symbols or from
[Iconify](https://iconify.design), fetched once and cached in the app group so
the widget never touches the network.

Tiles snap to the real Home Screen icon grid, which is measured, so a tile lands
where an icon would.

### Two ways to build

A design has two possible bodies, and which one you want depends on whether it
has to travel.

**As fonts** - the default, and everything below. Its frames are colour glyphs,
it gets a thirty-second loop, and it can only reach a phone by being compiled
into the widget extension and installed. A font only draws in a widget if it
shipped inside the extension, which is the constraint the whole project is
shaped around.

**As pictures** - `Send to phone`, `--send`, `--deliver`, `Tools/deliver.sh`.
Its frames are JPEGs the widget stacks under the same masks, so it needs nothing
installed and can be handed to a phone that already has the app. The loop is the
blink mask's period, and masks of two, five and ten seconds ship - the build
picks the shortest that covers the clip, so a clip plays as long as it is up to
ten seconds. Only periods dividing ten exist, because the substitution keys on
the timer's ones digit alone. Every second of period costs `framesPerSecond` more
pictures whether the clip fills them or not, because the stack has to cover the
whole cycle. Every clip a design has travels together, so variants can still be
switched on the phone.

Both bodies produce identical stills - one `DesignArtWriter` writes the
wallpaper and the backdrop for both - so switching between them does not move
the scene against the wallpaper behind it.

### Building

Build does, in order: extract frames → measure the motion crop → choose a quality
plan that fits the memory budget → encode frames → write the lane fonts → write
the wallpaper and the widget backdrop → rewrite `UIAppFonts` → regenerate the
project → build → install.

The quality plan is automatic. It tries the smoothest setting first and steps
down until the payload fits the measured ceiling, preferring a crisp 16fps loop
over a mushy 32fps one.

## Command line reference

The pipeline runs without a window, which is how it is tested. The binary lives
inside the app bundle:

```sh
STUDIO=~/Library/Developer/Xcode/DerivedData/Motionary-*/Build/Products/Debug/MotionaryStudio.app/Contents/MacOS/MotionaryStudio
```

| Command | What it does |
|---|---|
| `--build <clip>` | Generate a design's fonts and pictures. Installs nothing. |
| `--build <clip> --bundle` | Generate, and compile the result into the app. |
| `--build <clip> --device <UDID>` | The whole job: generate, bundle, build, install, launch. |
| `--install-starred [--device <UDID>]` | Install the designs marked starred in the library. |
| `--rebuild-starred [--device <UDID>]` | Regenerate every starred design from its source clip. |
| `--roundtrip` | Export a design and import it back. A pipeline self-check. |
| `--analyse-crop [--starred]` | Report what each design's animated area costs. Read-only. |
| `--deliver <out.motionary> [--design <name\|uuid>]` | Build the design as pictures and pack every clip into one file. Installs nothing. |
| `--send [--to <phone name>] [--design <name\|uuid>]` | The same, sent over the local network to a phone with Motionary open. |

**`--rebuild-starred` is what to reach for after changing anything in the
pipeline.** A design's backdrop and wallpaper are written at build time, so a
pipeline change does nothing at all to designs that are already built. This has
bitten before: a design shipped with neither the edge nor the colour correction
in its backdrop, which looks exactly like a correction that does not work.

Find a device identifier with:

```sh
xcrun devicectl list devices
```

## Looking at the result

A widget can only be judged by looking at a rendered one. That used to mean
mirroring a phone. It does not now — these drive SpringBoard from inside the
simulator via XCUITest, so a run needs nobody's screen:

```sh
Tools/lab-shot.sh on|off  out.png     # the font lab, on the simulator
Tools/mask-shot.sh dir n "32,4,240"   # the mask lab, as a burst of shots
Tools/mask-sweep.sh "32,32,540 ..."   # what a frame stack costs, on the phone
Tools/edge-shot.sh on|off out.png     # the edge calibration target
Tools/edge-profile.py shot.png        # read the target back
Tools/edge-calibrate.py shot.png --design <id> [--write]
                                      # measure the edge residual from a Home
                                      # Screen shot and write the profile back
```

The **font lab** is the useful one when something will not draw. It takes the
same design and tries to deliver its lane fonts nine different ways, then reports
which routes produced a picture. If every route fails, the fonts are not in the
bundle. If one works and the widget does not, the fault is in the composition.

The **mask lab** answers the other question: whether a live timer mask gates a
picture that arrived after the install. That is the finding the delivered engine
rests on, and the lab draws it with the production masking rather than a
restatement of it - see
[the measurement](widget-animation-surface.md#411-measured-cost-of-a-runtime-frame-stack--device-2026-08-12).

The app also keeps a status report and a render log in the app group, written on
every widget render. That is what to read first when the widget is black —
it records how many lanes were requested, how many resolved, whether the backdrop
loaded, and the extension's memory footprint at the moment it drew.

On a phone those used to be unreadable without holding it: `devicectl` will not
read anything but `Library` out of an app group. The app mirrors them into its
own Documents on every foreground, so a device run can end in a file instead of a
photograph:

```sh
Tools/pull-reports.sh [out-dir]
```

## Adding a device

Only devices whose geometry was **measured against real hardware** belong in
`Shared/Model/DeviceGeometry.swift`. Deriving the numbers from Apple's published
point sizes put the widget origin 7.33pt out on the one device that was checked,
which showed as the composition sitting about 22px right of where it should — a
derived entry looks plausible in the picker and is visibly wrong on the phone.

What has to be measured, all in device pixels:

| Field | How it was measured |
|---|---|
| `screenPixelSize` | A Home Screen screenshot from the device. |
| `widgetOrigin` / `widgetPixelSize` | The frame a design is cut to. |
| `widgetRenderedOrigin` / `widgetRenderedPixelSize` | What the system actually hands the extension — larger than the cut frame, and offset. Read off the `EdgeLab` ring target, whose outermost 1px ring lands on the view's own bounds. |
| `iconGridOrigin` / `iconGridPitch` / `iconSide` | Read off a Home Screen screenshot. |
| `widgetCornerRadius` | Estimated; iOS does not publish it. |

On the calibrated iPhone 17 Pro the system hands over a frame 2px left, 3px
right and 13px below the cut frame, and there is no known reason for the
asymmetry — only the measurement. `Tools/edge-shot.sh` and `Tools/edge-profile.py`
exist to take these readings.

## When it looks wrong

### The widget is black

A black widget and a broken widget look identical from outside, so work from the
report rather than from the picture.

1. **Read the status report** in the app group. `lanesRequested` versus
   `lanesResolvable` is the first number that matters.
2. **If no lanes resolve**, the fonts are not in the bundle or not in
   `UIAppFonts`. Regenerate the project and reinstall. This is by far the most
   common cause.
3. **If lanes resolve and it is still black**, suspect memory. The extension's
   ceiling is about 45MB and a full-screen image costs 12.6MB decoded. A build
   measured at 46.7MB had its render dropped; one at 43.3MB drew correctly.
   `--analyse-crop` reports what each design spends.
4. **If the design is fine but one clip is not**, check that its fonts were
   bundled: a stale variant selection degrades to a lane set that was never
   installed.

### The composition is misaligned

A seam between the widget and the wallpaper is a geometry problem.

- **Zoom or parallax on the wallpaper** will shift it. Turn both off.
- **The wrong widget slot.** A design is cut for one position.
- **An uncalibrated device.** See [Adding a device](#adding-a-device).
- **A stale studio binary.** If the pipeline changed but the design was rebuilt
  by a binary compiled before the change, the correction is simply not in the
  backdrop. `Tools/edge-calibrate.py` reports what share of the profile is
  actually present in a design's backdrop.

### The animation jumps every 30 seconds

The loop does not divide the timer cycle. Studio warns about this at build time
and offers the nearest clean length.

### Colours do not match the wallpaper

An iPhone screenshot is Display P3; the pipeline's pictures are untagged sRGB.
Differencing one against the other without converting invents roughly −13 red and
+14 blue on warm content, which is large enough to look like a real finding. sRGB
red `(255, 0, 0)` reads as `(234, 51, 35)` in P3.

If the mismatch is real rather than a measurement artefact, it is the widget tint
and edge correction — both are applied at build time, so rebuild with
`--rebuild-starred`.
