# Motionary

Animated, full-screen iPhone Home Screen widgets, with tappable app launchers
placed on them.

A design is a video clip, positioned on the screen, with app tiles on top. The
widget plays it. The wallpaper behind it carries the rest of the picture, so the
two read as one continuous scene.

## The constraint everything else follows from

A widget's view is built inside the extension and rasterised somewhere else —
`WidgetRenderer_Default`. **A font only draws if it was in the extension's bundle
at install time and declared in `UIAppFonts`.** Runtime registration resolves by
name inside the extension and then draws nothing where the glyph is actually
rendered, or makes WidgetKit reject the whole timeline.

That was established the hard way, and it is why:

- designs are compiled on a Mac and shipped inside the app, not made on the
  phone;
- the phone app is a viewer, with no import, no settings and no generation;
- adding or changing a design means a build and an install.

Every route out of it was tested and closed. See
[docs/widget-animation-surface.md](docs/widget-animation-surface.md) — the
`.process`/`.persistent` registration routes, `CTFontManagerRegisterGraphicsFont`,
`Font(CTFont)`, App Group URLs in the archive, and the private
`_wantsCustomFontsEmbeddedInArchive` flag, which is real, linkable, and embeds
nothing.

## How the animation works

There is no animation API in a widget worth using for this. What there is:
`Text(date, style: .timer)`, which the system re-renders on its own schedule.

- A frame of video is JPEG-encoded, base64'd, and embedded in an OT-SVG colour
  glyph.
- A `GSUB` ligature maps a run of timer digits to that glyph, so as the timer
  advances the system swaps one picture for the next.
- One font carries 15 frames — a "lane". 32 to 64 lanes are stacked, and a
  bundled blink-mask font (`Custom-Regular.otf`) makes exactly one lane visible
  at a time.
- The cycle is 30 seconds, anchored to wall-clock time so the app and the widget
  agree on which frame is showing.

`Shared/CompositionView.swift` draws it; `Shared/Pipeline/` builds it.

## Layout

    Mac/        Motionary Studio: the editor and the build pipeline's driver
    Shared/     Everything both platforms need, including all of Pipeline/
    App/        The iPhone viewer
    Widget/     The extension
    Tests/      202 unit tests, run on the simulator
    UITests/    Drives SpringBoard from inside the simulator to photograph the widget
    Tools/      Shot loops and analysis scripts
    docs/       What was measured and what it cost to find out

## Building a design

Open Motionary Studio (macOS 14+), drop in a clip, position it, place tiles,
press build. It generates the lane fonts, copies them into `Resources/` as
`prebuilt-*`, rewrites `UIAppFonts` in both `Info.plist`s, regenerates the Xcode
project, builds for the device and installs.

The same pipeline runs headless, which is how it gets tested:

    MotionaryStudio --build clip.mp4              # generate only
    MotionaryStudio --build clip.mp4 --bundle      # generate and compile in
    MotionaryStudio --build clip.mp4 --device UDID # the whole job
    MotionaryStudio --install-starred [--device UDID]
    MotionaryStudio --rebuild-starred [--device UDID]  # regenerate every starred design
    MotionaryStudio --roundtrip                    # export a design and import it back

`--rebuild-starred` is what to reach for after changing anything in the pipeline:
a design's backdrop and wallpaper are written at build time, so a pipeline change
does nothing to designs already built.

## Looking at the result

The widget can only be judged by looking at a rendered one, and that used to mean
mirroring a phone. It does not now:

    Tools/lab-shot.sh on|off  out.png    # the font lab, on the simulator
    Tools/edge-shot.sh on|off out.png    # the edge calibration target
    Tools/edge-profile.py shot.png       # read the target back

Both drive SpringBoard from inside the simulator via XCUITest, so a run needs
nobody's screen.

## Testing

    xcodebuild -scheme Motionary -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
      -only-testing:MotionaryTests test

One trap worth knowing: in a unit test `Bundle.main` is the runner, not the
bundle holding the resources, so every test that asked about a bundled design
used to skip itself silently — which is how the widget's design selection went
untested long enough to regress. `PrebuiltDesign.resource(named:extension:)`
falls back to the compiled-in bundle for exactly that reason.

## Geometry

`Shared/DeviceGeometry.swift` holds one measured device. Only measured devices
belong in that table — the widget's frame is not derivable, and a few pixels of
drift shows as a seam against the wallpaper.

The system hands over slightly *more* widget than the frame says: 548pt where the
table says 544. The backdrop is padded to cover it. See
[docs/home-screen-compositing.md](docs/home-screen-compositing.md).

## Things that have bitten, and will again

- **An oversized child grows a `ZStack`**, which silently breaks every
  `topLeading` offset in it. Use `Color.x.frame(...).overlay(alignment:)` — an
  overlay cannot enlarge its base.
- **A mask applies in the coordinate space of what it masks.** Wrap the thing in
  a full-size container *first*, or the mask clips against the wrong bounds.
- **Swift `Decodable` does not apply property defaults to missing keys.** Every
  field added to a stored type needs `decodeIfPresent`, or old designs fail to
  decode and the store skips them — they vanish from the library rather than
  failing loudly.
- **The extension's memory ceiling is about 45MB.** A full-screen image costs
  12.6MB decoded; that is why the widget loads a cropped backdrop rather than the
  wallpaper.
- **A `CGContext` fill is colour-managed.** Filling 200 and reading back 210 is
  normal. Assert on which picture arrived, not on an exact value.
- **JPEG smooths a one-row correction.** Anything that depends on a sharp
  single-pixel step needs quality 0.95 or better.
- **The project lists fonts by name**, so it must be regenerated whenever they
  change — not only when a device is attached.
