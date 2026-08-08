# Things that have bitten, and will again

Each of these cost real time to find. Most of them share a shape: the broken
state and the working state look identical from the outside, so the bug hides
until someone measures rather than looks.

## SwiftUI and layout

- **An oversized child grows a `ZStack`**, which silently breaks every
  `topLeading` offset in it. Use `Color.x.frame(...).overlay(alignment:)` — an
  overlay cannot enlarge its base.

- **A mask applies in the coordinate space of what it masks.** Wrap the thing in
  a full-size container *first*, or the mask clips against the wrong bounds.

## Storage and decoding

- **Swift `Decodable` does not apply property defaults to missing keys.** Every
  field added to a stored type needs `decodeIfPresent`, or old designs fail to
  decode and the store skips them — they vanish from the library rather than
  failing loudly.

## The extension

- **The extension's memory ceiling is about 45MB.** A full-screen image costs
  12.6MB decoded; that is why the widget loads a cropped backdrop rather than the
  wallpaper. Measured: 43.3MB drew, 46.7MB had its render dropped.

- **A font only draws if it was bundled at install time and declared in
  `UIAppFonts`.** Runtime registration resolves by name and then draws nothing.
  This is the constraint the whole project is shaped around — see
  [HOW-IT-WORKS.md](HOW-IT-WORKS.md#the-constraint-everything-follows-from).

## Colour and pixels

- **A `CGContext` fill is colour-managed.** Filling 200 and reading back 210 is
  normal. Assert on which picture arrived, not on an exact value.

- **JPEG smooths a one-row correction.** Anything that depends on a sharp
  single-pixel step needs quality 0.95 or better.

- **An iPhone screenshot is Display P3; the pipeline's pictures are untagged
  sRGB.** Differencing one against the other without converting invents about
  −13 red / +14 blue on warm content, which is big enough to look like a finding.
  sRGB red is `(234, 51, 35)` read as P3.

## The build

- **The project lists fonts by name**, so it must be regenerated whenever they
  change — not only when a device is attached. A stale `.xcodeproj` produces a
  build with *zero* design resources in it, and the app reports "No design is
  built into this app yet" as though none had ever been made.

- **A stale studio binary silently un-applies a pipeline change.** Rebuilding
  designs is not enough if what rebuilt them was compiled before the change: a
  design shipped with neither the edge nor the colour correction in its backdrop
  that way, and it looks exactly like a correction that does not work.
  `Tools/edge-calibrate.py` checks the design's backdrop and says what share of
  the profile is actually in it.

## Testing

- **In a unit test `Bundle.main` is the runner**, not the bundle holding the
  resources, so every test that asked about a bundled design used to skip itself
  silently — which is how the widget's design selection went untested long enough
  to regress. `PrebuiltDesign.resource(named:extension:)` falls back to the
  compiled-in bundle for exactly that reason.

## Geometry

- **The widget's frame is not derivable.** `Shared/Model/DeviceGeometry.swift`
  holds one measured device, and only measured devices belong in it. Deriving the
  numbers from Apple's published point sizes put the origin 7.33pt out, which
  showed as the composition sitting about 22px to the right.

- **The system hands over more widget than the frame says**, and starts it 2px
  further left: 1079x1645 px at (64, 270) against a cut frame of 1074x1632 at
  (66, 270). The extension lays out from the rendered origin; using the cut
  frame's put every design 2px left of its wallpaper.
