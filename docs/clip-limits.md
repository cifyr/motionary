# How long a clip can be, and how many of them

Measured on 2026-08-13 by building clips of 2s to 45s and designs of 1 to 57
clips through `MotionaryStudio --deliver`, then sending several of them to an
iPhone 17 Pro and reading the widget's own render log back with
`Tools/pull-reports.sh`.

Everything here is a measurement. Where a number was assumed before and turned
out to be wrong, the assumption is named.

## Length

One clip, one design, `light` smoothness (16fps), delivered as pictures.

| loop | frames | per archive | what happened |
| --- | --- | --- | --- |
| 4s | 64 | 6.7MB | drew |
| 10s | 160 | 5.7MB | drew; the frames shrank to fit |
| 15s | 240 | 6.7MB | drew |
| 20s | 320 | 8.9MB | drew, confirmed on the phone at a 10MB footprint |
| 30s | 480 | 13.2MB | over; the widget took one lane in two and drew at half the frame rate |
| 45s | 480 | 13.2MB | became 30s — the blink mask's period tops out there |

A shorter loop is not a smaller archive. Four seconds costs more per archive
than ten, because at 160 frames `FramePayloadPlan.shrink(toFit:measured:)` starts
spending resolution and at 64 it has no need to.

**Two ceilings stack, and they do not agree.** `TimerFontSpec.maximumLoopFrames`
is 320, which is 10s at 32fps and 20s at 16fps. `FrameSetGenerator.provenLoopSeconds`
is 10 whatever the frame rate. The smaller one wins, so a design at `light`
smoothness is cut to half of what its own loop sizing allowed. Both are
overridable for one build: `MOTIONARY_LOOP_SECONDS` and `MOTIONARY_LANE_BUDGET`.

**Past the ceiling the clip is truncated, not sped up.** A 45-second clip
delivers as its first ten seconds. It used to do that silently; the build and
the editor both say so now, and say how much was left behind.

## Bytes

Two numbers, and the gap between them is where a Home Screen goes black.

- `FramePayloadPlan.byteBudget` — 7MB. What a build aims at.
- `FramePayloadPlan.archiveLimit` — 9MB. Where the widget stops being drawn.
  9.32MB has been photographed drawing nothing.

A 20-second loop lands at 8.9MB: inside the limit, four per cent under the size
that draws nothing, and it used to ship without a word. `ClipWeight.headroom`
now reports `comfortable`, `tight` or `over`, and the build output says which.

Over the limit the widget degrades rather than failing: it takes every `n`th
lane, which halves the frame rate and keeps the loop the length it was authored
at. Confirmed on the phone — 480 lanes at 13MB came back as 240 lanes at 6.6MB
and drew.

## Count

Clip count is not what makes a widget black. Only the clip being shown is
loaded, so the per-archive weight is flat however many there are.

| clips | package | build | per archive |
| --- | --- | --- | --- |
| 14 | 69MB | 16s | 6.9MB |
| 29 | 139MB | 31s | 7.0MB |
| 57 | 265MB | 61s | 7.0MB |

Roughly 4.7MB and one second of build per clip. The limit is the cable, the
phone's disk, and patience — not the extension.

**Shuffled programs are the exception.** Every clip shares one stack, so their
lengths add up in a single archive: ten clips shuffled measured 13.9MB and
dropped to half the frame rate. Three to five is the working range, which is why
`Spidey Swing` has three.

## Edge cases that were broken

Each of these was found by building it, and each is fixed.

- **Speeding a clip up past the point where the source runs out** failed the
  whole build on `yielded 97 frames but the loop needs 160`. Variants had been
  sized against their own clip since they arrived; the design's own clip never
  was. It shortens the loop now.
- **A missing clip** came back as AVFoundation's `an unknown error occurred
  (-17913)`, which reads like a damaged one and sends you looking at the wrong
  thing. `videoFrames` loaded its tracks outside any catch, so damaged clips
  escaped as a UserInfo paragraph with a percent-encoded URL in it.
- **A one-frame loop** reported the mask's period rather than its own length,
  claiming two seconds for a clip that plays for a sixteenth of one.
- **Every first render of a fresh extension process** logged `0x0px` and still
  said `OK`. The size is captured in `onAppear` and the report is written during
  body evaluation, one pass earlier — so the render most worth reading after a
  delivery was the one the log said nothing about. It says
  `size-not-measured-yet` now.

## How to measure this again

```sh
# Build a design headlessly and read what came out.
xcodebuild -project Motionary.xcodeproj -scheme MotionaryStudio \
    -derivedDataPath build/mac build
STUDIO=build/mac/Build/Products/Debug/MotionaryStudio.app/Contents/MacOS/MotionaryStudio
MOTIONARY_LOOP_SECONDS=20 "$STUDIO" --deliver /tmp/test.motionary --design "Name"

# Send it and read the widget's own account of drawing it.
Tools/deliver.sh <design-uuid>
Tools/pull-reports.sh /tmp/reports
```

The render log is the only thing that can be read back off a phone. The
extension's own log is out of reach — the tunnel hides it from syslog, `log
collect` wants root, and `devicectl` refuses the app group path.
