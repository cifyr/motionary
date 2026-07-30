# What the Home Screen does to a widget, measured

The widget is supposed to disappear into the wallpaper. Anything the system does
between the extension's pixels and the screen shows up as a seam, and none of it
is documented or visible from inside the extension.

This is what was measured on a physical iPhone 17 Pro, and how, so the next
person can re-measure rather than re-guess.

## Method

Three things made this tractable:

1. **The design's own wallpaper is the reference.** The widget's content and the
   wallpaper behind it are the same picture, so the wallpaper file says what
   every pixel *should* be. Subtracting it leaves only what the system did.
2. **Subtract the picture's own edges too.** A row-brightness high-pass
   (`m(y) - (m(y-4) + m(y+4)) / 2`) computed on both the screenshot and the
   reference, then differenced, cancels the picture's own hard edges. The
   Polaroid borders in the test design cancelled to within ±2 while the system's
   lines stood at +60 and more — which is the check that the method works.
3. **Bin across the width, and only trust the bins with headroom.** Where the
   content is too dark to subtract from, the measurement says more about clamping
   than about the system.

Screenshots must be **full resolution**. A screenshot pasted into a chat client
gets resampled to 0.76, which spreads a two-pixel line and halves its peak — the
first profile fitted that way was wrong by 2× and put one edge a row out.

## The widget is bigger than its frame, and starts 2px left of it

`DeviceGeometry` says a design is cut to 1074×1632 px at (66, 270). What the
system hands the extension is **1078×1645 px at (64, 270)**.

That origin is the part that mattered. The composition lays its content out from
the viewport's origin, so telling it the cut frame's origin drew every design two
pixels left of the wallpaper behind it — the seam the whole exercise is about,
from a table that was four pixels narrow.

Measured without a rim line, by differencing a full-resolution Home Screen
screenshot against the app's own full-screen render of the same design. The app
draws the whole screen 1:1, so it is the picture as the design intends it:

| where | dx | dy |
|---|---|---|
| inside the widget (1260 patches, r > 0.995) | **+1.996** | +0.003 |
| wallpaper left of it, right of it, below it | −0.03 | −0.00 |

Pure translation, no scale: fitting `dx = a·x + b` across the width gives 0.54px
of slope over 1074px, and every column band reads +1.99 on its own. Sliding a
5px-wide window across the boundary reads exactly `2·n/5` for the n columns of it
that are widget, which puts the first widget column at **64** and the last at
**1141** — so the width is 1078, and 1078 centred on a 1206px screen begins at
64.0 exactly. The 2px is the width error halved, not an origin of its own.

The extra 13px of height lands entirely at the bottom (the slot's top row is 270
either way), which is why the rim lines are at rows 270 and 1914.

The composition is still cut to the calibrated frame. The backdrop is padded by
24px on every side, which is what covers the difference; without the padding
there would be unpainted pixels down all four edges. A test asserts the padding
still covers the rendered frame.

**The simulator cannot answer this one.** It places the widget as `systemLarge` —
1049×1095 at (79, 270), family raw value 2 — not the tall portrait family, so its
frame is a different measurement entirely. What the simulator did establish is
that `WidgetStatus.renderedSize × 3` equals the drawn pixel extent exactly: the
ring target's outermost ring landed on 1049×1095, and the extension reported
349.67×365.0 pt. Which also means the report's own `Int()` was hiding this —
359.33pt printed as 359, so the frame looked 1px out instead of 4px. It prints two
decimals now.

## The edges: a bright line, top and bottom only

The system adds light along the widget's top and bottom rows. Per channel, by
distance inward from the edge, as finally fitted after three measure-adjust
rounds:

| distance | top (R,G,B) | bottom (R,G,B) |
|---|---|---|
| 0 | 68, 70, 63 | 86, 75, 68 |
| 1 | 54, 45, 47 | 64, 67, 68 |
| 2 | 40, 32, 23 | 47, 39, 45 |
| 3 | 14, 13, 10 | 19, 14, 17 |
| 4 | 11, 10, 8 | 16, 12, 6 |
| 5–8 | fades to ~5 | fades to ~3 |

**Nothing down the left and right edges.** Measured at 66 and 1139 the score was
−1.9 to +0.4, i.e. noise. That asymmetry is the useful part: it makes the sides a
control, and it is why the artefact reads as two lines rather than a border.

**It adds rather than blends.** On the simulator, the same experiment against a
`systemLarge` widget fitted a blend — `captured = (1-w)·content + w·behind`, w
falling from ~0.15 five pixels in to nothing by 60, with `behind` fitting the
wallpaper's own colour. On the device, behind the widget *is* the same picture, so
a blend would cancel itself and be invisible. This is not invisible, so it is
additive — which is what makes it invertible without knowing anything about what
is behind.

`Shared/Pipeline/EdgeCompensation.swift` subtracts it from the widget's backdrop
before the backdrop is encoded. Only the backdrop: outside the widget no line is
drawn, so darkening the wallpaper there would put a dark band next to nothing.

### The limit

Light can only be removed from content that has some. Where a design's own
outermost row is nearly black, the subtraction hits zero with the line still
showing. On the test design that was 3 of 9 columns across the top and 5 of 9
across the bottom — 7.2% and 17.5% of edge pixels respectively.

No table of numbers fixes that. The fix is in the design: move the clip or the
background so the widget's outermost rows are not the darkest part of the
picture. The build logs the share and warns past a quarter.

## The colour: the widget reads warmer than the wallpaper

The same picture is displayed differently inside the widget and outside it.
Measured on strips a few pixels either side of the **side** boundaries — the
right place to look, because the sides have no rim line and the picture is
continuous across them — the widget's content came back:

    red +1%, green -3%, blue -7%

Consistent at five separate places down each side, on lit wood, on shadow, and on
a bright white border.

It is not the files. The wallpaper and the backdrop are written from the same
composed frame, both untagged, and both read as sRGB. It is the two display paths
— the Home Screen's wallpaper pipeline and the widget renderer — so the fix is
the same inversion: `Shared/Pipeline/WidgetTint.swift` applies the opposite gain
to everything the widget draws.

Both the backdrop **and** the animated frames need it. Correcting one alone makes
them agree with each other and both disagree with the wallpaper, which puts a
visible rectangle inside the widget — worse than the original problem.

Colour goes on before the edge subtraction, because the edge profile was measured
against the wallpaper as displayed and belongs on content that already matches
its colour.

### The limit

After one refinement the average difference is (+0.8, −0.6, −1.4) and falling,
but it is no longer a single offset — it varies a few units down the height of
the widget. Driving the average to zero leaves that variation. Per-row gains
would chase it; nobody has established it is visible.

## Recalibrating, in one command

    Tools/edge-calibrate.py shot.png --design <uuid-prefix>          # measure
    Tools/edge-calibrate.py shot.png --design <uuid-prefix> --write  # and write

It measures the residual per row per channel by exactly the method above — the
design's own wallpaper as the reference, a local baseline from rows 14–43 inward
so the colour path's own drift is not folded into the edge profile, nine column
bins, and only the bins whose content had room to be darkened — then writes
`Resources/edge-profile.json`, which the pipeline reads. Recalibrating does not
need a code edit; the shipped numbers stay compiled in as the fallback.

Run against the shot the profile was hand-fitted on, it reports 92% of the profile
baked in and a top-edge residual inside ±2.5 units, which is the same conclusion
that took three rounds by hand.

### The trap it exists to catch

What it measures is the light left over *after* a correction. A shot of a design
built **without** one measures the whole line, and folding that in doubles the
profile instead of refining it — the two are indistinguishable in the output.

So it checks the design's own backdrop first, and reports the share of the profile
actually baked into it. Below 50% it refuses to write.

That check earned itself immediately. A design built at 23:32 on 2026-07-29
carried **9%** — neither the edge subtraction nor the colour gain, its backdrop
sitting at 1.0004× its wallpaper where the tint should make it 0.984/1.035/1.096 —
while two designs built an hour earlier carried both. Rebuilding it from a studio
compiled out of this source took it to **84%**, with the gain back at
0.9853/1.0355/1.0983 and row 270 down by (70.2, 71.2, 59.2). So the pipeline was
never wrong; the binary that built the design was stale.

Two things follow. A design must be rebuilt after a pipeline change, and **the
studio must be rebuilt before the design** — `xcodebuild -scheme MotionaryStudio`
then `--rebuild-starred`. And a Home Screen screenshot is not self-describing: it
cannot say which build it came from, so the tool checks the files on disk rather
than trusting the shot.

## Reproducing any of this

    Tools/edge-shot.sh on /tmp/edge.png    # calibration target, simulator
    Tools/edge-profile.py /tmp/edge.png

The target is four saturated 1px rings on the boundary, flat grey bands at three
levels, and a 1px grid: the rings fix the boundary to the pixel, the three levels
separate an added line from a gain, and the grid shows whether content is
displaced. On iOS 26.5 every ring survived in its exact pixel, so nothing is
clipped or warped.

For a device measurement there is no shortcut: install, screenshot at full
resolution, and difference against the design's own wallpaper as above.
