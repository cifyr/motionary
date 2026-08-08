# Contributing

Read [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md) first — particularly [the
constraint about bundled
fonts](docs/HOW-IT-WORKS.md#the-constraint-everything-follows-from), because it
explains why the project is shaped the way it is and why a design cannot be made
on the phone.

Then [docs/PITFALLS.md](docs/PITFALLS.md), which is the list of things that have
already cost someone a day.

By taking part you agree to the [Code of Conduct](CODE_OF_CONDUCT.md), and you
accept that contributions are distributed under the project's
[licence](LICENSE) — which is source-available, not open source.

## Getting a build running

You need macOS 14+, Xcode with an iOS 26+ simulator, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

    xcodegen generate                       # the .xcodeproj is generated, never committed
    xcodebuild -scheme Motionary -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
      -only-testing:MotionaryTests test
    xcodebuild -scheme MotionaryStudio -destination 'platform=macOS' build

A fresh clone has no designs in it. `Resources/prebuilt-*` and `MFont*.ttf` are
build output — 60MB per design — so they are ignored. The app and the widget
build without them; anything that needs a bundled design skips itself and says
so. Make one with Motionary Studio.

**Regenerate the project after adding, moving or renaming a file.** The Mac
target lists several files individually, and `Resources` is expanded at
generation time, so a stale project fails on paths that no longer exist.

## Where things go

    Shared/Model/        Data and maths. No UI, no I/O, no platform APIs.
    Shared/Rendering/     Views drawn by the app, the widget and the editor alike.
    Shared/Storage/       Where designs live and how they are read back.
    Shared/Pipeline/      Clip in, lane fonts and pictures out.
    Shared/Diagnostics/   The labs and the reporting that answer "did it draw?"
    Shared/Icons/         Catalogue icon fetch and rasterisation.
    Shared/SFNT/          Font container writing. Bytes, not policy.
    Mac/Studio/           The editor and the build pipeline's driver.
    Mac/Install/          Writes into the project, puts it on a phone.
    Mac/Library/          Skins, design archives, tile artwork lookup.
    App/                  The iPhone viewer.
    Widget/               The extension.
    Tests/                Mirrors the sections above.
    Tools/                Shot loops and analysis scripts.

Two rules that matter more than the folders:

- **Anything in `Shared/` must compile for iOS and macOS.** `FileProtectionType`
  is iOS-only, `Process` is macOS-only, and both have caught people out.
- **The widget extension gets all of `Shared/`.** Adding a dependency there adds
  it to a process with a ~45MB ceiling that runs in a sandbox.

## Measure before you change, and after

Most of the hard problems here were invisible from inside the code: a widget that
drew nothing looked identical to a widget that was broken, and a correction that
was a row out looked identical to no correction. The habit that worked:

1. Render something whose every pixel you know.
2. Photograph the result — `Tools/edge-shot.sh`, `Tools/lab-shot.sh`, both drive
   the simulator from the inside so they need nobody's screen.
3. Subtract what you expected from what you got.
4. Change one number, then do it again.

[docs/home-screen-compositing.md](docs/home-screen-compositing.md) is that loop
written out, including the two places it hit a wall. If you are about to guess at
a number, measure it instead; if you cannot measure it, say so in the comment.

## Tests

Write them for anything new, and run them. The suite is fast (about 11 seconds)
and runs on the simulator.

- Test the observable behaviour, not the implementation. Assert on which picture
  arrived rather than an exact pixel value, because `CGContext` fills are
  colour-managed — filling 200 and reading 210 is normal.
- Never weaken an assertion to make a test pass. A test that skips itself is
  worse than a failing one: three of these skipped silently for weeks because
  `Bundle.main` in a unit test is the runner, and the bug they were meant to catch
  shipped.
- If a test encodes an assumption, say so in a comment. One asserted that every
  catalogue app was launchable, which was never true.

## Comments

Explain *why*, never *what*. The names say what. A comment earns its place by
recording a constraint, a workaround, an invariant, or a measurement — something
the next person would otherwise have to rediscover. One line where one line does.

The code is dense with these because nearly every one cost a night to learn.
Keep that up: if you fix something subtle, leave the reason behind.

## Commits and pull requests

- Conventional prefixes: `feat:`, `fix:`, `refactor:`, `docs:`, `chore:`.
- Subject under about 50 characters, then a body explaining why, not what.
- One logical change per commit. Never commit a state where the tests fail.
- Never commit `Resources/prebuilt-*`, `MFont*.ttf`, `build/`, or anything from
  `.archive/`.
- Say what you verified in the PR: which tests ran, and on what. "Builds" is not
  a verification for anything that draws.

## Working on a phone

Anything that touches a physical device needs the owner's say-so — a deploy takes
over the phone and relaunches the app. The simulator paths are there so that
almost nothing needs one: the shot loops, the calibration target and the whole
pipeline run headless.

`--rebuild-starred` regenerates every starred design after a pipeline change. A
design's backdrop and wallpaper are written at build time, so changing the
pipeline does nothing to designs already built — an easy way to conclude a fix
did not work when it was simply never applied.

Rebuild the studio *before* the designs, for the same reason one level up:

    xcodebuild -scheme MotionaryStudio -destination 'platform=macOS' build
    MotionaryStudio --rebuild-starred

A design shipped with neither the edge nor the colour correction in its backdrop
because the binary that rebuilt it predated both, and from a screenshot that is
indistinguishable from a correction that does not work.
`Tools/edge-calibrate.py` reports what share of the profile is actually baked into
a design, and refuses to calibrate against one that has none.
