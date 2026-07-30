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

`Shared/Rendering/CompositionView.swift` draws it; `Shared/Pipeline/` builds it.

Only the moving part of the frame goes into the glyphs. The rest is one still
backdrop, so a design animating 24% of the widget costs a quarter of the decoded
bitmap that a full-screen one would. `MotionaryStudio --analyse-crop` reports what
each design actually spends.

## Layout

    Mac/        Motionary Studio, split into Studio / Install / Library
    Shared/     Both platforms: Model, Rendering, Storage, Pipeline,
                Diagnostics, Icons, SFNT — see CONTRIBUTING.md for what goes where
    App/        The iPhone viewer
    Widget/     The extension
    Tests/      The unit suite, run on the simulator, mirroring the sections above
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
    MotionaryStudio --analyse-crop [--starred]     # what each design's animated area costs, read-only

`--rebuild-starred` is what to reach for after changing anything in the pipeline:
a design's backdrop and wallpaper are written at build time, so a pipeline change
does nothing to designs already built.

## Looking at the result

The widget can only be judged by looking at a rendered one, and that used to mean
mirroring a phone. It does not now:

    Tools/lab-shot.sh on|off  out.png    # the font lab, on the simulator
    Tools/edge-shot.sh on|off out.png    # the edge calibration target
    Tools/edge-profile.py shot.png       # read the target back
    Tools/edge-calibrate.py shot.png --design <id> [--write]
                                         # measure the edge residual off a Home
                                         # Screen shot and write the profile back

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

The system hands over slightly *more* widget than the frame says, and starts it
2px further left: 1079x1645 px at (64, 270) against a cut frame of 1074x1632 at
(66, 270). The extension lays its content out from the rendered origin — using the
cut frame's put every design 2px left of the wallpaper — and the backdrop is
padded to cover the difference. See
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
- **An iPhone screenshot is Display P3; the pipeline's pictures are untagged
  sRGB.** Differencing one against the other without converting invents about
  −13 red / +14 blue on warm content, which is big enough to look like a finding.
  sRGB red is (234, 51, 35) read as P3.
- **A stale studio binary silently un-applies a pipeline change.** Rebuilding
  designs is not enough if what rebuilt them was compiled before the change: a
  design shipped with neither the edge nor the colour correction in its backdrop
  that way, and it looks exactly like a correction that does not work.
  `Tools/edge-calibrate.py` checks the design's backdrop and says what share of
  the profile is actually in it.
