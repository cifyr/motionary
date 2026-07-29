# The WidgetKit animation surface on iOS 26 / 27

A survey of every mechanism by which the content of a WidgetKit view can change
over time *without the extension being re-run*, with evidence and confidence for
each, and a ranked shortlist of routes worth implementing.

Goal this serves: let a user upload a video on their phone and get an animated
Home Screen widget, with no Mac and no recompile. The current engine works but
requires the generated OT-SVG lane fonts to be compiled into the widget
extension's bundle at install time. Everything below is assessed against
escaping that constraint.

---

## 0. Method, and how to read the evidence tags

Three kinds of evidence appear, and they are not interchangeable.

| Tag | Meaning |
|---|---|
| **[DOC]** | Apple documentation or a WWDC session transcript |
| **[BIN]** | First-hand symbol/disassembly evidence from shipped Apple binaries, gathered for this report |
| **[CODE]** | Working, on-device-verified source in this project or in Bryce Bostwick's `WidgetAnimation` |
| **[FORUM]** | Apple Developer Forums report — sometimes with an Apple engineer reply, sometimes not |
| **[INF]** | My inference. Labelled wherever it appears |

Confidence levels are stated per mechanism as **high / medium / low / unverified**.

### What was measured locally

All **[BIN]** claims are reproducible with the commands below. Binaries used:

- `/Library/Developer/CoreSimulator/Volumes/iOS_23F77/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.5.simruntime/Contents/Resources/RuntimeRoot/System/Library/Frameworks/{WidgetKit,SwiftUI}.framework/`
- `/Applications/Xcode.app/.../iPhoneSimulator.sdk/System/Library/Frameworks/WidgetKit.framework/WidgetKit.tbd`

A methodology note that matters, because it explains why earlier public
reverse-engineering missed this: **the interesting Swift symbols are not
findable with `strings` or `grep`.** They live in the Mach-O *exports trie*
(`LC_DYLD_EXPORTS_TRIE`), which stores names as a prefix trie split across
nodes. Confirmed empirically: `grep -c clockHandRotationEffect WidgetKit`
returns 0, extracting the `LC_SYMTAB` string table and grepping returns 0, but
`nm -a WidgetKit | grep clockHand` returns 21 symbols. **Use `nm`, not
`strings`.**

Environment: Xcode 26.6 (17F113), iPhoneOS 26.5 SDK, iOS 26.5 simulator runtime,
macOS 26.2. No device or simulator Home Screen was driven for this report.

---

## 1. The architecture everything else follows from

Apple states the model plainly, and it is the single fact that constrains every
mechanism below. WWDC23 session 10028 *Bring widgets to life*: [DOC]

> "The system generates a representation of these views and archives it on disk.
> When it's time to display a specific entry, the system decodes and renders the
> archived representation of your widget in its process. **Your view code only
> runs during archiving.** [...] When your widget is visible, your code is not
> running."

So only two things can move:

1. Nodes the **render server already knows how to keep moving on its own**.
2. Diffs the system computes **between two archived timeline entries**.

Everything in this report is an instance of (1), an instance of (2), or a way to
smuggle more information into (1).

### 1.1 What the archive actually is [BIN] — high confidence

It is **not** a `CAArchive`, layer tree, PDF, or pixel buffer. It is a Swift
`Codable` graph of view descriptors, gated by two private SwiftUI protocols:

```
_$s7SwiftUI15_ArchivableViewP16publicIdentifierSSvgZTj
_$s7SwiftUI15_ArchivableViewP14publicEncodingSe_SEpvgTj
_$s7SwiftUI15_ArchivableViewP12sizeThatFits2inSo6CGSizeVAA13_ProposedSizeV_tF
_$s7SwiftUI15_ArchivableViewPAAE15registerDecoderyyFZ
_$s7SwiftUI23_ArchivableViewModifierMp
```

Shape (reconstructed from the mangled requirements, not from a header):

```swift
protocol _ArchivableView: View {
    static var publicIdentifier: String { get }        // stable string tag
    var publicEncoding: Encodable & Decodable { get }  // the payload
    func sizeThatFits(in: _ProposedSize) -> CGSize
    static func registerDecoder()
}
protocol _ArchivableViewModifier: ViewModifier { /* same three requirements */ }
```

Two consequences fall straight out:

- **A view is archivable if and only if it conforms.** Apple's "SwiftUI views for
  widgets" page is an *allowlist*, not a denylist [DOC] — which is exactly the
  documentation you'd write for a conformance-gated protocol.
- **`sizeThatFits` is a protocol requirement**, so *layout is resolved in the
  extension before archiving*. The render server is not re-running SwiftUI
  layout. This is the root cause of the whole family of "sizing modifiers
  degenerate in widgets" bugs (`.minimumScaleFactor` always renders at its floor,
  `ViewThatFits` always picks the smallest branch, `.fixedSize()` blanks the
  widget) [FORUM: forums/thread/763797].

### 1.2 The archive's declared capabilities [BIN] — high confidence

`SwiftUI.ArchivedViewInput.Flags` is an OptionSet with exactly these members
(extracted via `nm -a SwiftUI | grep ArchivedViewInputV5FlagsV`):

```
publicArchive   customFontURLs   preciseTextLayout
stableIDs       intelligenceContent   assetCatalogRefences   // Apple's typo, verbatim
```

`customFontURLs` and `assetCatalogRefences` are the load-bearing ones: **the
archive format can carry by-reference payloads, but only when the consumer
advertises support via a flag.** This is a policy switch, not a format
limitation — see §7.

Also present, and versioned: `ArchivedViewInput.DeploymentVersion` ∈ `{v5, v6, v7}`.

### 1.3 The WidgetKit side [BIN] — high confidence

```
_$s9WidgetKit0A8ArchiverC...            // WidgetArchiver
_$s9WidgetKit18ViewStatesArchiverV13archiveToData...
_$s9WidgetKit18ViewStatesArchiverV24encodesCustomFontsAsURLsSbvg
_$s9WidgetKit18ViewStatesArchiverV24encodesPreciseTextLayoutSbvg
_$s9WidgetKit31_TimelineArchivedViewCollection
_TtC9WidgetKit14WidgetArchiver
```

`ArchivableTimelineViewCollection` has one requirement:

```swift
func enumeratedViewableEntriesAndEnvironments()
    -> CartesianProduct<[TimelineEntry], [EnvironmentValues]>
```

**The archive is a cartesian product of entries × environments.** Every entry is
rendered against every environment permutation the system might need
(`colorScheme`, `colorSchemeContrast`, `displayScale`, `legibilityWeight`,
`sizeCategory`, `redactionReasons`, `isLuminanceReduced`, `showsWidgetLabel`,
`_widgetFamily`, `widgetRenderingMode` ∈ `{fullColor, vibrant, accented}`, plus
accessibility switches). This is the dominant multiplier on archive size, and it
is why "just add more entries" scales badly.

Transport is by **file descriptor, not inline data**: the XPC interface
`WidgetKit.ExtensionToHostXPCInterface` takes an `NSFileHandle`, and the field is
named `archiveFileHandle`. `WidgetRenderer.framework` exists in
`/System/Library/PrivateFrameworks/`, and the literal string
`WidgetRenderer_Default` is present in the shared cache — matching the process
name this project already observed in jetsam reports [CODE:
`Shared/FontLab.swift:12`].

---

## 2. `Text(_:style:)` — the primary live primitive

### 2.1 The variants [DOC] — high confidence

From ["Displaying dynamic dates in widgets"](https://developer.apple.com/documentation/widgetkit/displaying-dynamic-dates):

| Style | Renders | Auto-updates? |
|---|---|---|
| `.timer` | `15:00` — counts down to the date, then counts up | **Yes** |
| `.relative` | `11 min, 14 sec` — absolute difference, no sign | **Yes** |
| `.offset` | `-11 minutes` — signed difference | **Yes** |
| `.date` | `April 1, 2020` | No |
| `.time` | `9:41AM` | No |
| `Text(start...end)` | `9:30AM-2:45PM` | No |

Also live, and *not* on the dynamic-dates page:

- `Text(timerInterval:pauseTime:countsDown:showsHours:)` — iOS 16+, public [DOC]
- `ProgressView(timerInterval:countsDown:)` — see §3, the under-used one
- `TimeDataSource` + `Text(_:format:)` — iOS 18+. **Trap:** `.timer` and
  `.stopwatch` formats update; `.relative(presentation:unitsStyle:)` given a plain
  `Date` does **not**, which is a silent regression for anyone migrating off
  `Text(date, style: .relative)` [FORUM: forums/thread/763273].

**Cadence is nowhere documented.** `.timer` and `.relative` visibly tick at 1 Hz.
Sub-second motion is obtained not by a faster tick but by *stacking* N texts with
staggered reference dates — the technique this project already uses.

### 2.2 What the renderer re-rasterises — medium confidence

`Text.DateStyle` is `Codable` [BIN] — WidgetKit imports
`_$s7SwiftUI4TextV9DateStyleVSeAAMc` and `...VSEAAMc`, i.e. its `Decodable` and
`Encodable` conformances. So the archive carries **(date, style)**, not a
resolved string, and the render server re-evaluates it. That is the mechanism.

WidgetKit also exports `_animatedIdealizedDateComponents` and
`_$s9WidgetKit18ViewStatesArchiverV24encodesPreciseTextLayoutSbvg` [BIN], which
together imply the extension precomputes an *idealised* layout for the animating
date so the box does not need re-measuring at render time. This matches the
`sizeThatFits`-at-archive-time model in §1.1.

**The glyph run's width is not stable, but the box is.** Four independent lines
of evidence converge:

- Relative dates truncate when the string grows (`59 sec` → `1 min, 0 sec`) even
  with `.lineLimit(1)` [FORUM: forums/thread/656207]
- The text box renders "much longer than it should", with glyphs aligned inside
  it [FORUM: forums/thread/662640]
- Sizing modifiers degenerate, as above [FORUM: forums/thread/763797]
- Both Bostwick and this project deliberately reserve `size * 9` of width and use
  `.multilineTextAlignment(.trailing)` plus an `.offset` to pin the last glyph
  [CODE: `Shared/CompositionView.swift:226`]

**Whether the whole view tree or only the text region is re-rasterised is
unverified.** No source addresses it. It would be settled by a Core Animation
instrument trace on device showing whether the dirty rect is confined to the
text's bounds.

### 2.3 Can it carry arbitrary per-frame imagery?

**Yes — but only through a font.** The glyphs the renderer draws come from a
`CTFont`, so arbitrary imagery means arbitrary glyphs, which means a font file
the renderer can resolve. That is precisely the constraint this report is trying
to escape. See §7.

**Confidence: high.** This is the shipping engine.

---

## 3. `ProgressView(timerInterval:)` — the overlooked live *geometric* primitive

Apple documents it as "showing **continuous progress as time passes**" [DOC].
Binary evidence confirms it is a first-class archivable live node [BIN]:

```
SwiftUI.TimelineProgressView.ArchivableTimelineProgressView(
    interval: Range<Date>, updateStyle: TimelineProgressViewUpdateStyle,
    countdown: Bool, resolvedTint: Color.Resolved, extendedState: ...)
SwiftUI.ConditionallyArchivableTimelineProgressView(...)
```

This matters because it is the **only public, continuously-driven primitive whose
output is a geometric quantity rather than a glyph.** A linear progress view's
fill edge sweeps across the view as wall-clock time advances, with no font
involved and no extension running.

That makes it a candidate for a **live mask that moves continuously** — which is
the thing a font is currently being used to fake.

**Limitations, stated plainly:**

- The interval is a `Range<Date>` and runs **once**. There is no loop. A looping
  animation would need fresh entries, and entries are guidance-bound to ~5 min
  apart [DOC].
- Progress is a *ramp*, not a step. Masking a frame with it produces a wipe, not
  an instant cut. Building a boxcar (frame k visible only during `[t_k, t_k+dt]`)
  needs either a subtractive composite of two ramps or `.blendMode`, and blend-mode
  liveness in an archived widget is **unverified**.
- Date-relative progress views **do not support custom `ProgressViewStyle`** [DOC],
  which sharply limits how the ramp can be reshaped.
- Reported broken in the Dynamic Island and under Always-On since iOS 16.2
  [FORUM: forums/thread/722073].

**Can it carry arbitrary per-frame imagery? Not on its own — but possibly as the
mask that gates it.** Confidence: **unverified, and the single most interesting
untested idea in this report.** I found no prior art at all: nobody has published
an attempt to use `ProgressView(timerInterval:)` as a widget animation driver.

---

## 4. Masking — settled, and more permissive than assumed

**A live `Text(_:style:)` used as a `.mask()` stays live in the archive and gates
the visibility of other content, including an entire composited subtree.**

This is not inference. It is shipping, on-device-verified code in this project
[CODE: `Shared/CompositionView.swift:144-176`]:

```swift
ZStack {
    ForEach((lanes / 2) ..< lanes, id: \.self) { lane in
        Text(reference + 1 + frameDuration * CGFloat(lane), style: .timer)
            .font(font(lane, size))
            .mask { BlinkMask(reference: reference, blinkOffset: ...) }   // (a) leaf
    }
}
.mask { BlinkMask(reference: reference, blinkOffset: 1) }                 // (b) subtree
```

`BlinkMask` is itself nothing but `Text(reference - blinkOffset, style: .timer)`
in a font whose glyphs are a solid square or nothing. Bostwick's repo does the
same two things.

**Why (b) is the important one.** If `.mask()` were flattened at archive time,
every stacked lane would be permanently visible or permanently hidden and the
result would be a static smear. It demonstrably animates. And in case (b) the
masked thing is a `ZStack` container, not a leaf `Text` — so the render server is
applying a **live mask to a composited subtree**, not doing a text-specific glyph
trick. Gating granularity is sub-second (`frameDuration = 1/32 s` here), so mask
liveness is not limited to 1 Hz boundaries.

**Confidence: high** that live-text masks work and compose over subtrees.

### 4.1 Does a live mask gate *static* content? Yes — settled by prior art

Initially I had this as the report's biggest open question, because in every
`Text`-based case the *masked* content is itself `Text`. It is now settled, by a
different live primitive, and the answer generalises.

`tangtiancheng/DouYinComment` implements **full GIF playback in a widget** using
`_clockHandRotationEffect` (§5) as the live driver and a mask over **static
`Image`s**. Its author's own comment describes the construction:

> "If there are N frames, place N images stacked in place, unmoving; then use
> `mask` to put a mask on each. Each mask corresponds to one angular wedge of a
> circle. Once they are all rotating, you get a frame-by-frame movie effect."

Concretely: N stacked static `Image`s, each with

```swift
.mask(
    ArcView(start: i * θ, end: (i + 1) * θ, radius: R)
        .stroke(lineWidth: …)
        .clockHandRotationEffect(period: .custom(gifDuration))
        .offset(y: …)
)
```

where `θ = 360 / N`. The wedge sweeps past the widget bounds once per period,
revealing exactly one frame at a time.

**This proves the general property:** the render server evaluates
`_MaskEffect` *live, downstream of the time-driven effect*, and it composites a
live mask over **arbitrary static raster content**. If masking were resolved
against a frozen snapshot at archive time, that widget would show one static
frame. It demonstrably plays the GIF.

So both directions are now evidenced:

| Mask | Masked content | Evidence |
|---|---|---|
| live `Text(style:.timer)` | live `Text(style:.timer)` | Bostwick, this repo [CODE] |
| live `Text(style:.timer)` | a composited `ZStack` subtree | this repo [CODE] |
| rotating shape (`_clockHandRotationEffect`) | **static `Image`** | DouYinComment [CODE] |

**Still not directly proven:** a live *`Text`*-driven mask over a static `Image`
specifically. But the mechanism is now clearly content-agnostic and effect-agnostic
compositing in the render server, so this is a small remaining gap rather than a
structural unknown. **Confidence it works: high [INF].**

**The experiment, still worth 30 minutes.** One widget, three bands, on device
(not Simulator — several of the relevant bugs are device-only):

1. `Image(uiImage: photo).mask(BlinkMask(blinkOffset: 0))`
2. `Color.red.mask(BlinkMask(blinkOffset: 0))`
3. `Text("hello").mask(BlinkMask(blinkOffset: 0))` — known-good control

Follow with `.blendMode(.destinationOut)` and `.luminanceToAlpha()` variants, and
repeat under Always-On, Low Power Mode and Reduce Motion.

### 4.2 The remaining catch

A mask that *reveals* is not a mask that *moves*. To step a filmstrip the
aperture must translate, and with `Text`-driven masks the aperture's position
comes from glyph metrics — i.e. from a font again. The genuinely font-free
variants are:

- **one live mask per frame, N frames stacked** — costs one live view per frame,
  which is what the font trick exists to compress (15 frames per live text view
  instead of 1)
- **a rotating wedge over N stacked static frames** (§5) — costs *one* live
  effect for the whole animation, which is why the prior art uses it

---

## 5. `_clockHandRotationEffect` — the strongest route, with working prior art

### 5.1 Exact signature — high confidence, two independent confirmations

It is **in WidgetKit, not SwiftUI**. It was **fully public in the shipped
`.swiftinterface` for iOS 14.0 – 15.6 / macOS 11.0 – 11.3**, and stripped from
the interface at iOS 16.1. Verbatim from
`iPhoneOS14.5.sdk/.../WidgetKit.swiftmodule/arm64e-apple-ios.swiftinterface`
(identical in the 15.6 and MacOSX 11.3 SDKs):

```swift
@available(iOS 14.0, macOS 11, *)
@available(tvOS, unavailable) @available(watchOS, unavailable)
public struct _ClockHandRotationEffect: SwiftUI.ViewModifier, SwiftUI._ArchivableViewModifier {
    public enum Period {
        case hourHand
        case minuteHand
        case secondHand
        case custom(Foundation.TimeInterval)
    }
    public init(from decoder: Swift.Decoder) throws
    public func encode(to encoder: Swift.Encoder) throws
    public func body(content: WidgetKit._ClockHandRotationEffect.Content) -> some SwiftUI.View
}

extension View {
    public func _clockHandRotationEffect(
        _ period: WidgetKit._ClockHandRotationEffect.Period,
        in timeZone: Foundation.TimeZone,
        anchor: SwiftUI.UnitPoint = .center
    ) -> some SwiftUI.View
}
```

Independently confirmed for **iOS 26.5** by demangling the exported symbol
`_$s7SwiftUI4ViewP9WidgetKitE24_clockHandRotationEffect_2in6anchorQrAD06_ClockghI0V6PeriodO_10Foundation8TimeZoneVAA9UnitPointVtF`
[BIN] — the signature is unchanged in twelve years of SDKs.

Two corrections to widely-copied folklore:

- The first parameter is **unlabelled** and the timezone label is **`in:`**. The
  blog form `._clockHandRotationEffect(period:timeZone:anchor:)` is wrong.
- There is **no `ClockHandRotationPeriod` type in Apple's SDK.** That name is
  invented by the third-party wrapper `octree/ClockHandRotationKit`.
- `AnalogTimeMode` — **no evidence it exists.** Zero hits for "Analog" in any
  SwiftUI or WidgetKit `.swiftinterface` from iOS 14.0 to 26.5.

Stored properties are `period`, `timeZone`, `anchor`, confirmed by a runtime
bridge that JSON-decodes `{"period":…,"timeZone":{"identifier":…},"anchor":{"x":…,"y":…}}`
into the type looked up by mangled name `9WidgetKit24_ClockHandRotationEffectV`
(`giljihun/ClockHandKit`).

`_ClockHandRotationEffect` conforms to **`SwiftUI._ArchivableViewModifier`**
[BIN: `_$s9WidgetKit24_ClockHandRotationEffectV7SwiftUI23_ArchivableViewModifierAAMc`],
so it is archived as a live modifier node and the **rotation is performed by the
render server**, continuously, with no extension running and no timeline entries.

It is one of only **three** `_ArchivableViewModifier` conformances in all of
WidgetKit [BIN] — the others being `WidgetURLModifier` and `WidgetContentLayerTag` —
and it is **the only continuously-time-driven one**. An independent sweep of every
public `.swiftinterface` from iOS 14.0 to 26.5 found no `_pulsatingEffect`, no
`_flipEffect`, no shimmer/marquee/breathe equivalent. This is the only such
primitive that exists.

### 5.2 Semantics — medium-high confidence

- `.custom(t)` = one full 360° revolution per `t` seconds, **constant angular
  velocity, smooth not ticking**. A **negative** `t` reverses direction —
  `TopWidgets/SwingAnimation` relies on `.custom(-duration / 2)`.
- `.secondHand` / `.minuteHand` / `.hourHand` are **phase-locked to the supplied
  `TimeZone`'s wall clock**. That is what the `in timeZone:` parameter is for. It
  makes them useless for "start animating when the widget appears" and ideal for
  "always in a known phase" — the same property this project already relies on
  with `cycleAlignedReference` [CODE: `Shared/TimerFontSpec.swift:79`].
- Verified on Home Screen `systemSmall`/`systemMedium` in every shipping example.
  **Lock Screen accessory families and Always-On: unverified.** No example
  exercises `.accessoryCircular`/`.accessoryRectangular`, and Always-On throttles
  the whole render path.
- Works in a plain in-app SwiftUI hierarchy too, not only in widgets — which
  makes it testable in the app without touching a Home Screen.

### 5.3 Can it carry arbitrary per-frame imagery? **Yes — this is done and shipping**

This is the headline finding of the report. The flipbook idea is not speculative;
it is established prior art, and the implementation is smarter than the obvious
version.

**Do not rotate a disc of frames.** Rotate a thin angular **wedge used as a mask**
over N stacked *static* frames (§4.1). Each frame `i` gets a wedge covering
`[i·θ, (i+1)·θ]` where `θ = 360/N`; all wedges rotate with the same
`.custom(loopDuration)`; exactly one frame is unmasked at a time. Source:
`tangtiancheng/DouYinComment/…/GifVideoPlay.swift`.

Why this ordering matters for this project specifically:

- It **avoids resampling a large rotated bitmap**, so it does not fight the
  pixel-area cap (§6.4) the way a rotating frame-disc would. Each frame stays its
  natural size.
- Only the small vector wedge shapes rotate. There is **one live effect for the
  whole animation**, not one per frame.
- The author notes the arc radius is deliberately scaled up (~300×) so the seam
  between adjacent wedges sweeps past the aperture too fast for the eye to catch.
  That is a real implementation detail worth copying rather than rediscovering.

Related prior art from the same lineage:

- **`TopWidgets/SwingAnimation`** converts rotation into bounded *linear*
  translation by composing three nested counter-rotations (`+d`, `−d/2`, `+d`)
  with sized frames. Public API `.swingAnimation(duration:direction:distance:)`.
  This is a general "pan a filmstrip" primitive.
- A **scrolling photo carousel** built on that swing primitive
  (`DouYinComment/…/ScrolPick.swift`), which additionally shows `.clipped()` and
  `.cornerRadius()` composing correctly host-side.
- Fan and shake effects in the same repo using `.custom(0.5)`.

### 5.4 Composition with masks and clipping — **verified, not inferred**

This was my largest open question and it is answered by the above: the rotation is
applied *inside the mask content* and a **static `Image` underneath** is revealed
and hidden by the sweeping wedge. If masking were resolved at archive time against
a frozen snapshot, that widget would show one static frame. It plays the GIF.

`SwingAnimation` further shows `.frame()`, `ZStack` alignment, `GeometryReader`
and **nested** rotations all composing correctly in the render server.

**Confidence: high.**

### 5.5 Invocation — high confidence, and my earlier read was wrong

**Not source-callable on the iPhoneOS 26.5 SDK.** Measured: a file containing
`Image(systemName:)._clockHandRotationEffect(.custom(2.0), in: .current, anchor: .center)`
fails `swiftc -typecheck` with `value of type 'Image' has no member
'_clockHandRotationEffect'`. It is absent from the 26.5
`WidgetKit.swiftinterface`; there is no `.private.swiftinterface`; the
`-library-level api` interface contains zero `@_spi` declarations.

**But the symbol is exported in the SDK stub, so it links.** Verbatim in
`iPhoneSimulator26.5.sdk/.../WidgetKit.framework/WidgetKit.tbd` [BIN]:

```
_$s7SwiftUI4ViewP9WidgetKitE24_clockHandRotationEffect_2in6anchorQrAD06_ClockghI0V6PeriodO_10Foundation8TimeZoneVAA9UnitPointVtF
…VtFQOMQ      // the opaque type descriptor for the `some View` return
```

Three practical routes, in order of preference:

1. **Vendored xcframework built against the iOS 14/15 SDK**, where the API was
   genuinely public — no `dlsym`, no swizzling, stock compiler. This is what
   `octree/ClockHandRotationKit`, `everettjf/Xcode13ClockHandRotationEffectModifier`
   and `pawello2222/WidgetExamples` all do, and what ships in the App Store app
   Top Widgets⁺.
2. **Runtime type bridge**: `_typeByName("9WidgetKit24_ClockHandRotationEffectV")`
   plus JSON `Codable` reconstruction (`giljihun/ClockHandKit`, self-labelled
   experimental). Leaves a string literal rather than a mangled import.
3. `@_silgen_name` against the mangled symbol. Both the function and its opaque
   type descriptor are exported, so this is plausible, but reconstructing an
   opaque `some View` return by hand is the hardest of the three.

⚠️ **Correction to something I asserted earlier in this investigation.** I
initially concluded the public shims were dead on iOS 26 because they targeted a
*SwiftUI* symbol that no longer exists. That is **wrong**. `everettjf`'s shim
source calls `._clockHandRotationEffect(period, in: tz, anchor: anchor)` — the
correct WidgetKit signature — and that symbol **is still exported in the iOS 26.5
SDK**, verified above. `WidgetAnimation` issue #4 ("including the Clock framework
breaks the build on iOS 26") is therefore a build-configuration or module-ABI
problem, **not** a missing symbol. I could not determine its actual cause and will
not guess.

**Confidence:** high that the symbol exists, is archivable, and is linkable;
high that the technique works (shipping apps do it); **unverified** specifically
on iOS 26/27, since all the prior art predates iOS 26.

### 5.6 App Store risk — stated plainly

This is a private API and using it violates App Review guideline 2.5.1.

Mitigating facts, which are real:

- It was **genuinely public in the shipped SDK interface for iOS 14.0 – 15.6**.
  A vendored old-SDK xcframework needs no obfuscation, no `dlsym`, no swizzling.
- The mangled symbol is a **legitimate export** in every `WidgetKit.tbd` from
  iOS 14 through 26.5. The signature has never changed.
- **Apps ship it.** `TopWidgets/SwingAnimation` is the open-source core of the
  App Store app Top Widgets⁺. The Scripting app exposes `clockHandRotationEffect`
  and `swingAnimation` as first-class scriptable modifiers in its public `.d.ts`.

Aggravating facts:

- A vendored xcframework leaves the literal mangled symbol
  `_$s7SwiftUI4ViewP9WidgetKitE24_clockHandRotationEffect…` in the binary's import
  table. Trivially greppable if Apple decides to look.
- **Removed from the SDK interface at Xcode 14**, and Bostwick's May 2025 video
  plus the ensuing Hacker News and Hackaday coverage put the whole technique on
  Apple's radar. The stated reason Apple restricts continuous widget animation is
  battery on Always-On displays, which argues for a clamp-down rather than a
  blessing.
- If the symbol is ever removed, a linked shim produces a **launch-time dyld
  crash**, not a static widget.

**Documented rejections: none found.** I searched specifically and found zero
first-hand reports of a rejection attributed to this symbol. Absence of reported
rejections is weak evidence of safety, not strong. Since this is a personal app,
that is likely an acceptable trade — but it should be a decision, not an
accident, and it forecloses distribution.

---

## 6. What the archive will and will not carry

### 6.1 `badTimelineData` is not what it looks like — high confidence [BIN]

**This is the most consequential correction in the report.**

`badTimelineData` is **not an archiver error**. It is a case of `Reload.Reason`
in ChronoCore — the reason code `chronod` records when it decides to ask the
extension for a *new* timeline. Its siblings:

```
initial, stale, timelineExhausted, badTimelineData, environmentMismatch,
environmentChanged, metricsChanged, extensionChanged, appAuthChanged,
significantLocationChange, interaction, push, systemRequest(String),
externalRequest(...), scheduledRetry, reloadLoop, ...
```

carried in `Reload(type:cost:reason:retryAttempts:allowCostOverride:fromUserInteraction:)`
with `Reload.Cost ∈ {budgeted, free}`.

So `badTimelineData` means *"chronod could not use what you returned, so it is
reloading."* It is a symptom, downstream of a real failure. The real failure is
one of four `WidgetArchiver.ArchivingError` cases, whose `errorDescription`
strings are verbatim in the binary [BIN]:

| Case | Description string |
|---|---|
| `imageTooLarge(CGSize, CGSize)` | "The body of the Widget entries' view contains an image of size {…} which is beyond the maximum of {…}" |
| `failedToEncode([Any.Type])` | "The body of the Widget entries' view contains the following unsupported types: {…}" |
| `missingNecessaryWidgetMetrics` | "Failed due to missing Widget metrics" |
| `bundleLookupFailed(Error)` | "Failed to lookup Widget bundle due to {…}" |

Plus `WidgetArchiver.ValidationError`: `bundleStubNotSupported`, `systemVersionNotSupported`.

**Actionable consequence for this project:** the diagnostic worth capturing is
the `[archiving]` line from *the extension's own process*, naming the unsupported
type, not chronod's reload reason. This project currently reads the reload reason
[CODE: commit `69dfd7d`]. The `failedToEncode` payload is literally a list of the
offending `Any.Type`s — it would have named the culprit directly.

Note also `ArchivingDelegate.failIfAnyTypeFailedToEncode` [BIN]: an unencodable
view does **not** always fail the archive. Sometimes it is silently dropped,
which is why a partially-empty widget is a distinct failure mode from an empty one.

### 6.2 The font mechanism — two different failures, not one — high confidence

The premise in the brief ("`Font` from a raw `CTFont` and
`CTFontManagerRegisterGraphicsFont`-registered fonts BOTH cause `badTimelineData`")
is correct in outcome but conflates two mechanisms that fail in **different
processes** and have **different fixes**.

The governing fact is `ArchivedViewInput.Flags.customFontURLs` [BIN] and
`WidgetKit.ViewStatesArchiver.encodesCustomFontsAsURLs: Bool` [BIN]:
**by default, a custom font is archived as a name and/or a file URL, not as bytes.**

**Case A — no serialisable identity. Fails at ENCODE time, in your process.**

`CGFont` built from a `CGDataProvider`, or a `SwiftUI.Font` wrapping a raw
`CTFont`, has no file URL and no registered resolvable name to write. There is
nothing URL-shaped to encode → `ArchivingError.failedToEncode` /
`_ArchivedViewHost.failedToEncodeView(type:)`.

Corroborated [FORUM]: forums/thread/659332 ("'Archiving error' when using a
custom font", resolved as "you cannot use a `CGDataProvider`-created font for
widgets") and forums/thread/654408 ("`CTFontManagerRegisterGraphicsFont` ...
caused the entire view to not render ... I switched to
`CTFontManagerRegisterFontsForURL` and it worked").

⚠️ An Apple Staff reply in thread 654408 says `CTFontManagerRegisterGraphicsFont`
"should be able to use that in your widget code". **Every developer who followed
that advice reported failure.** Do not treat it as authoritative.

**Case B — valid archive, unresolvable reference. Fails at DECODE time, in chronod.**

`CTFontManagerRegisterFontsForURL` pointing at an App Group file archives fine —
the URL is written — and then chronod cannot read it. The decisive log
[FORUM: forums/thread/671476, FB8978909, never answered by Apple]:

```
error  chronod  Encountered an error reading the view archive for <private>
error  chronod  [...] reload: could not decode view
error  kernel   Sandbox: chronod(2128) deny(1) file-read-metadata /private/var/mobile/Containers/Shared/AppGroup/.../Chewy-Regular.ttf
error  kernel   Sandbox: chronod(2128) deny(1) file-read-data     /private/var/mobile/Containers/Shared/AppGroup/.../Chewy-Regular.ttf
```

That log proves two things at once: **chronod does resolve file references out of
the archive lazily at render time** (otherwise there would be no read attempt),
and **chronod does not inherit the extension's App Group sandbox grant**. It
works in the Simulator, whose sandbox is weaker, and fails on device — which is
precisely the pattern this project observed.

This also explains the most confusing symptom recorded in this repo: registration
returns `true`, `CTFontCopyPostScriptName` round-trips, 32/32 lanes report usable
— and the widget draws black [CODE: `Shared/RuntimeFontRegistry.swift:99`,
`Shared/FontLab.swift:327`]. Everything was verified **in the wrong process**.

**Confidence: high** on both mechanisms.

### 6.3 `_wantsCustomFontsEmbeddedInArchive` — the escape hatch [BIN]

WidgetKit declares a WidgetKit-only environment value on `EnvironmentValues`:

```
_$s7SwiftUI17EnvironmentValuesV9WidgetKitE34_wantsCustomFontsEmbeddedInArchiveSbvg   // getter
_$s7SwiftUI17EnvironmentValuesV9WidgetKitE34_wantsCustomFontsEmbeddedInArchiveSbvs   // setter
_$s7SwiftUI17EnvironmentValuesV9WidgetKitE34_wantsCustomFontsEmbeddedInArchiveSbvM   // modify
9WidgetKit36WantsCustomFontsEmbeddedInArchiveKeyV                                     // the key
```

**When set, custom font *data* is embedded into the archive rather than
referenced.** If it could be set, both Case A and Case B above would evaporate,
and the entire "fonts must be bundled at install time" constraint would be a
policy decision rather than a platform limit.

**This directly contradicts the framing in the brief** — "runtime-registered
fonts never reach the renderer" is true *as configured*, not *in principle*.

Two caveats, one of them now partly resolved:

- **Not source-settable, but linkable.** Measured:
  `.environment(\._wantsCustomFontsEmbeddedInArchive, true)` fails
  `swiftc -typecheck` with "cannot infer key path type from context" — it is
  absent from the public `.swiftinterface`, same as §5.5. **But all four
  accessors, including the property descriptor a key path needs, are exported in
  `iPhoneSimulator26.5.sdk/.../WidgetKit.tbd`** [BIN]:

  ```
  _$s7SwiftUI17EnvironmentValuesV9WidgetKitE34_wantsCustomFontsEmbeddedInArchiveSbvg   // get
  _$s7SwiftUI17EnvironmentValuesV9WidgetKitE34_wantsCustomFontsEmbeddedInArchiveSbvs   // set
  _$s7SwiftUI17EnvironmentValuesV9WidgetKitE34_wantsCustomFontsEmbeddedInArchiveSbvM   // modify
  _$s7SwiftUI17EnvironmentValuesV9WidgetKitE34_wantsCustomFontsEmbeddedInArchiveSbvpMV // property descriptor
  ```

  The same is true of `WidgetKit.ViewStatesArchiver.encodesCustomFontsAsURLs`
  (all four accessors exported). So the linker can reach both switches; only the
  Swift front end refuses. Given `_ClockHandRotationEffect` was public in the
  iOS 14/15 SDK interfaces (§5.1), the obvious next check is whether these were
  too — if so, the same vendored-old-SDK-xcframework trick applies with no
  `@_silgen_name` at all. **Not checked.**
- **Best public evidence it is enabled for Live Activities and not for
  Home Screen widgets** [INF, from opposite failure signatures]: a 109 KB TTF
  inflated a Live Activity archive to **2.5 MB**, scaling with the number of
  labels using it, and the activity silently failed to start
  [FORUM: forums/thread/715159]. Home Screen widgets show the opposite signature
  — chronod reading the font *file*. If that inference holds, embedding is real
  but **quadratic in use sites**, which for 64 lane fonts at ~50 KB each would be
  catastrophic. Treat as **unverified**.

Also present [BIN]: `vectorGlyphAssetLibraryDatas` — SF Symbol vector data *is*
embedded as data. So the archive demonstrably can carry glyph outlines inline;
the question is only whether that path is reachable for custom fonts.

### 6.4 Size limits — there are **four**, routinely conflated

| # | Limit | Value | Enforcement | Confidence |
|---|---|---|---|---|
| 1 | Extension process RSS | **30 MB** widely cited; **~45 MB measured here** | jetsam `EXC_RESOURCE` | see below |
| 2 | Archived timeline size | **10 MB** (one Apple engineer) / **30 MB** (another) | archive rejected | low — Apple conflicts |
| 3 | Live Activity / ChronoKit archive | **~2 MB** observed | `archiveTooLarge(fileSize:)` | medium |
| 4 | Per-image **pixel area** | device-dependent, e.g. `2121055.2` | `imageTooLarge`, fails **soft** | high |

**On (1) — a genuine contradiction worth recording.** The universally cited
figure is 30 MB, from Apple engineers in forums and from `EXC_RESOURCE
RESOURCE_TYPE_MEMORY (limit=30 MB)` crash logs spanning iOS 14.1–18.3.1. It
appears in **no Apple documentation**. But this project measured, from a jetsam
report on an iPhone 17 Pro, that the widget extension survives past 40 MB and is
killed "a little above 45" [CODE: `Shared/Pipeline/FrameEncoder.swift:97-100`,
commit `0510bf9`]. Either the cap is device- or OS-dependent, or the 30 MB figure
is stale. **This should not be silently reconciled — it is a real data point
against the received wisdom, and the local measurement is first-hand.**

**On (4) — the cap is on pixel AREA, not bytes.** Verified [BIN]:
`WidgetArchiver.ArchivingError.imageTooLarge(CGSize, CGSize)` = (actual, maximum),
fed by `ArchivingDelegate.maximumAllowedImagePixelSize: CGSize?` and
`largestImageSizeByFamily`. Disassembly of the check confirms the comparison is
`width*height` of the `CGImage` against the product of two host-supplied doubles:

```
CGImageGetWidth ; CGImageGetHeight ; mul x26, x19, x0
fmul d8, d1, d0 ; scvtf d0, x26 ; fcmp d8, d0
```

with a sibling branch logging `exit (no size constraints configured)` — so **the
maximum is configured per host/family, not a compile-time constant.** The runtime
string exposes it: `totalArea: 24000000 > max[2121055.200000]`. Observed maxima
vary by device: `2121055.2`, `951390`, `718080` [FORUM: forums/thread/710745,
768169]. Failure is **soft**: images render blank or the widget goes black rather
than crashing.

Relevant to this project directly: nine glyphs at 1074×1086 is ~40 MB decoded
[CODE: commit `0510bf9`] — a single frame at 1074×1086 is 1.17 M px, safely under
the 2.1 M cap, but a filmstrip or rotating disc of many frames in one image would
blow through it immediately.

**Where to resize** — sharpest guidance found, and it contradicts most community
advice: *"It is better to **not** try and resize images in your extension process
since the entire process is memory constrained"* [FORUM: forums/thread/779546].
Resize in the host app before writing to the shared container.

### 6.5 Entry count and refresh budget

- **No documented maximum entry count.** Apple Frameworks Engineer: *"You get
  10MB of space per timeline. You get 72 refreshes per day and an unlimited amount
  of entries"* [FORUM: forums/thread/779546]. No entry-count constant appears in
  the binaries either. The constraint is **size-based**, and given the
  entries × environments cartesian product (§1.3), entry count multiplies archive
  size fast.
- **Spacing guidance:** "at least about 5 minutes apart" [DOC].
- **Budget:** "For a widget the user frequently views, a daily budget typically
  includes from 40 to 70 refreshes ... roughly ... every 15 to 60 minutes" [DOC].
  Per **widget instance**, not per kind. Competing figure of 72/day from two Apple
  engineers. WWDC21 10048 says 15–30 min; the doc says 15–60. Apple has never
  reconciled either pair.
- **Exempt from budget** [DOC, verbatim list]: containing app in foreground;
  active audio or navigation session; widget performs an App Intent; **widget
  performs an animation**; locale change; Dynamic Type / Accessibility change.
  macOS widgets have no budget. StandBy refreshes at a system rate that does not
  count.

**Self-updating text costs no budget** — it is not a reload. This is why the
current engine can use `.never` policy and still animate.

### 6.6 What survives the archive — summary

| Construct | Verdict | Confidence |
|---|---|---|
| `Image(systemName:)` | Works; vector glyph data embedded [BIN] | high |
| `Image("asset")` from the extension's own bundle | Works. Long-standing lookup bug where previews pass and device fails; workaround `Image(uiImage: UIImage(named:))` | medium |
| `Image(uiImage:)` from runtime `Data` | **Works, and is the recommended pattern.** Re-encoded to `defaultImageType` and inlined **per entry** | high |
| `Image` referencing an App Group *path* | Same chronod sandbox denial as fonts | high |
| `AsyncImage` | **Fails.** "Drawing the view is a synchronous operation" — Apple engineer | high |
| `Color`, gradients, `ShapeStyle`, `Path`, shapes | Work; on the allowlist | high |
| `Font(name:size:)`, font in the **extension's** `UIAppFonts` | Works | high |
| Runtime-registered font | Fails — §6.2 | high |
| `Canvas` | On the allowlist; drawn once per entry | high (support), high (not live) |
| `GeometryReader` | On the allowlist | high |
| `drawingGroup()` | No source either way | unverified |
| `ImageRenderer` output as an `Image` | Viable pre-rasterisation; still subject to the pixel-area cap | medium |
| `UIViewRepresentable` / `NSViewRepresentable` | **Prohibited** [DOC] | high |
| Video, animated images (GIF), scrolling | **Not supported** [DOC, WWDC20 10028] | high |

---

## 7. `TimelineView`, `PhaseAnimator`, `.animation`, transitions

**Short answer: animations run only ACROSS timeline entry transitions. One
animation per entry change. Nothing repeats forever.**

WWDC23 10028 [DOC]: *"Widgets don't have state. Instead, they create a timeline
made of entries ... SwiftUI determines what is the same and what is different
between the entries, and animates the parts that have changed."*

From ["Animating data updates in widgets and Live Activities"](https://developer.apple.com/documentation/widgetkit/animating-data-updates-in-widgets-and-live-activities) [DOC]:

- "Widgets and Live Activities support all built-in SwiftUI transitions and animations."
- **"Animations in widgets and Live Activities have a maximum duration of two seconds."**
- **"`Transaction` isn't available to widgets and Live Activities."**
- "On devices that include an Always-On display, the system doesn't perform
  animations to preserve battery life in Always On." Check `isLuminanceReduced`.
- Supported: `transition(_:)`, `contentTransition(_:)`, `animation(_:value:)`,
  `numericText(countsDown:)`; transitions `opacity`, `move(edge:)`, `slide`,
  `push(from:)`.

Corroborated in the binary: `_ArchivedView` carries a precomputed
`maxAnimationDuration` flag [BIN], and WidgetKit declares
`EnvironmentValues.widgetAnimationsPaused` with a `WidgetAnimationsPausedKey`
[BIN] — the system has an explicit switch for suspending widget animation.

| API | Verdict | Confidence |
|---|---|---|
| `TimelineView` | **Does not tick.** Absent from Apple's allowlist. Its schedule advances by re-invoking *your* closure, and your process is not running | high |
| `.repeatForever` | Foreclosed by the 2 s cap and by the archived render having no view lifetime | high |
| `PhaseAnimator`, `KeyframeAnimator` | Not mentioned in any widget doc, not on the allowlist; self-driving per-frame constructs with nothing to drive them | medium (unverified empirically) |
| `.animation(_:value:)`, `.transition`, `.contentTransition`, `.numericText()` | Supported, but fire **on entry change only** | high |
| `withAnimation` | No live state to mutate | high |
| `.symbolEffect` (incl. `.variableColor`, `.pulse`) | No Apple statement, no community report in a widget. Indefinite effects need a live loop | unverified |
| `.matchedGeometryEffect` | Cannot bridge two entries (separate archives) | medium |
| `.visualEffect` | No source either way | unverified |
| Metal shaders (`.colorEffect` / `.distortionEffect` / `.layerEffect`) | See below | unverified |

**Two important field reports.** `TimelineView` in a Live Activity fires its
closure **exactly twice and then stops**, while a sibling `Text(timerInterval:)`
in the same view keeps updating — isolating the failure to `TimelineView`
[FORUM: forums/thread/766932, FB15590204, Apple engineer requested a bug report,
still open]. And iOS 18 widgets ignore `.bouncy` parameters and delays that
iOS 17 honoured [FORUM: forums/thread/761873, FB14760003, Apple-acknowledged] —
so even the sanctioned per-entry animation is not faithfully reproduced.

**Methodology warning that matters for this project's lab:** do not validate any
of this in the Simulator or in Xcode Previews with a debugger attached. A
debugger-attached extension keeps running and produces **false positives** for
`TimelineView` and friends [FORUM: forums/thread/652946]. This repo has already
been bitten by the inverse of this — the Simulator's weaker sandbox made
App Group font loading look like it worked.

**On shaders — the most interesting genuinely-unknown item.** Apple's own
canonical animated-shader pattern (WWDC26 session 322) is: *"Shaders are
stateless ... if I want animation, I need to pass in a value that changes over
time"* — driven by `TimelineView(.animation)`, which is exactly the thing that
does not work in a widget. A **static** shader render may work; a **time-animated**
one almost certainly yields one frame per timeline entry. **Nobody on the public
internet has published an attempt.** If tested from an extension, note that
`ShaderLibrary.default` loads from the *main app bundle* — use
`ShaderLibrary.bundle(_:)`.

---

## 8. Live Activities and interactive widgets

### 8.1 Live Activities — not an animation surface, and not on the Home Screen

- **Different update model** [DOC]: *"Instead of using a timeline mechanism, Live
  Activities receive updated data from your app with ActivityKit and from your
  server with ActivityKit push notifications."*
- **Budgeted per hour.** *"The system allows for a certain budget of ActivityKit
  push notifications per hour."* `NSSupportsLiveActivitiesFrequentUpdates` raises
  the budget, does not remove it; users can revoke it. Priority 10 counts, priority
  5 does not.
- **Recovery from throttling is brutal.** Apple Frameworks Engineer, after a
  developer sent 40+ priority-10 updates in ~5 minutes: *"The only way to remedy
  this ... is to **wait for the system to add budget which can take up to 24
  hours**"* [FORUM: forums/thread/731715].
- **Local `Activity.update` floor ~16 s on iOS 18** [FORUM: forums/thread/758475].
  Apple's reply to a developer driving lyrics at 0.25 s: *"**The system was never
  designed to refresh every 0.25 seconds.** What are you actually trying to do?"*
- **Payload cap 4 KB.** Lifetime 8 h active, 12 h on Lock Screen.
- **`Text(style:)` tricks do work there**, and `_wantsCustomFontsEmbeddedInArchive`
  may be enabled there (§6.3) — which is the one genuinely interesting reason to
  care about this surface.
- ⚠️ **Correction to a common assumption:** "Home Screen" in Apple's placement
  list does **not** mean a Home Screen widget. WWDC26 223: *"on the Home Screen or
  when using apps, they appear right in the **Dynamic Island**."* There is no Live
  Activity placement in the widget grid.

**Can it be abused for continuous animation? No.** Confidence: high.

### 8.2 Interactive widgets — cannot self-drive

- Only `Button(intent:)` and `Toggle(isOn:intent:)` [DOC, WWDC23 10028]. Inactive
  on a locked device.
- **Reload is automatic:** *"When you return from the `perform()` function, the
  system reloads the widget's timeline"* [DOC].
- **There is no self-invoke and no auto-invoke.** No API fires a widget's intent
  programmatically. Structurally impossible — nothing is running in the widget to
  schedule anything. `await`-sleeping inside `perform()` gives one delayed frame
  per tap, not a loop.
- **Latency:** ~1–2 s entry→display; *"the UI seems to update every 2 seconds at
  the fastest"* [FORUM: forums/thread/733081]; 4–5 s when the host app must launch.
- **Telling detail:** `Toggle` updates optimistically because *"this is done ...
  at archive time, by pre-rendering the toggle style in both configurations"*
  [DOC, WWDC23 10028]. That is a **two-frame flipbook baked into the archive** —
  proof the archive can carry alternate pre-rendered states, selected by the host.
  Whether that selection mechanism is reachable for anything but a toggle is
  unverified, but it is the closest thing to a sanctioned frame-selection
  primitive in the whole surface.
- Every shipping widget game (Cromulent Labs' Chess, Minesweeper, etc.) is
  turn-based: one board redraw per tap. **No widget with continuous
  interaction-driven motion exists.**

**Can it be abused for continuous animation? No.** Confidence: high (no Apple
sentence forbids it, but no mechanism exists and every published attempt failed
or was throttled).

### 8.3 `WidgetCenter.reloadTimelines`

The foreground exemption is real and documented — *"the widget's containing app
is in the foreground"* is on Apple's exempt list [DOC], and WWDC25 278 says of
`reloadAllTimelines`: *"Since the app is running when this API is called, **the
system does not budget this request**."*

But "unbudgeted" means "not silently dropped", not "fast": the observed floor for
a visible change is ~1–2 s. And background reloads are a five-year-old open
complaint — BG task verified running, App Group data verified written, timelines
still don't reload, **but it works with the debugger attached**
[FORUM: forums/thread/652946, FB15508274, never answered by Apple].

**Not an animation vector.** Confidence: high.

---

## 9. iOS 26 / 27 additions relevant to animation or images

**Nothing in iOS 26 or 27 loosens the animation model.** Still archived views,
still the 2-second animation ceiling, still no `TimelineView`, no video, no
representables.

- **`systemExtraLargePortrait`** — visionOS 26.0, then iOS/iPadOS/macOS **27.0**.
  ⚠️ The parent `WidgetFamily` page renders every case with framework-inherited
  availability and is wrong per-case; read the individual case page.
- **Liquid Glass / accented rendering** — `WidgetRenderingMode` unchanged since
  iOS 16. `widgetAccentedRenderingMode(_:)` on `Image` is **iOS 18+**, newly
  emphasised rather than new. Apple: *"Reserve `fullColor` exclusively for media
  content like album artwork or book covers."* Directly relevant: this project
  found `.widgetAccentable(true)` was required to make the glyphs visible on
  iOS 27 [CODE: `RESEARCH.md`], and now sets `.widgetAccentable(false)` in the
  shipping widget [CODE: `Widget/DesignWidgetView.swift:27`] — worth re-checking
  against the accented-rendering doc.
- **`.glassEffect()` reported a no-op in widgets** [FORUM: forums/thread/789384].
- **visionOS 26 note that matters for compositing:** *"With glass texture, blend
  modes don't interact with the container background. Use `.paper` if your widget
  relies on blend modes."* First-party confirmation that blend modes are
  container-sensitive in the archived render path.
- **Push updates** — `protocol WidgetPushHandler` (iOS 26+), `.pushHandler(_:)` on
  `WidgetConfiguration`, `apns-push-type: widgets`. **Budgeted and delivered
  opportunistically.** Not a high-frequency path.
- **RelevanceKit / `RelevanceConfiguration`** — watchOS 26 only; no effect elsewhere.
- **iOS 27 Live Activities** — Dynamic Island in landscape
  (`\.isDynamicIslandLimitedInWidth`), StandBy presentation at 200 % scale.
- **App Intents 27 `ExecutionTargets`** — lets an intent target the WidgetKit
  extension specifically.
- ⚠️ Apple's iOS 27 "What's New" gives widgets one sentence: *"widgets can now be
  customized through App Intents and dynamic styling."* **"Dynamic styling" is not
  defined as an API anywhere I could find. Unverified.** The `Updates/WidgetKit`
  page still ends at June 2025.
- There was **no "What's new in widgets" session at WWDC26** — both widget
  sessions (277 *WidgetKit foundations*, 223 *Live Activities essentials*) are
  recaps. That absence is itself a finding.

---

## 10. Ranked shortlist of routes worth implementing

Ranked by **expected value = (chance it escapes the bundling constraint) × (chance
it works) ÷ (cost to find out)**.

### 1. `_clockHandRotationEffect` + rotating wedge masks over stacked static frames

**This is the route that actually solves the stated problem, and it has working
prior art doing exactly the target use case** (§5.3): N stacked static `Image`s,
each masked by an angular wedge, all wedges rotating with one
`.custom(loopDuration)`. Arbitrary user imagery, no font, no ligature table, no
per-frame live view, no recompile — the images are ordinary `Image(uiImage:)`
inlined into the archive per entry.

It also collapses most of this project's accidental complexity: no SFNT writer, no
OT-SVG glyph packing, no 64-lane font set, no `UIAppFonts` bundling step, no
`CTFontManager` at all. The frame count is bounded by archive size and the
pixel-area cap rather than by glyph shaping.

Costs and risks, honestly: private API (§5.6), personal-app-only, dyld-crash
failure mode on OS updates, and **all the prior art predates iOS 26** so it needs
re-verification on 26/27. Start by reproducing the DouYinComment wedge construction
with 8 frames in the app's own SwiftUI hierarchy — it works outside widgets, so
the first check needs no widget at all.

**Confidence: high that the technique works; unverified on iOS 26/27.**

### 2. Flip `_wantsCustomFontsEmbeddedInArchive`

**Measured during this report: all four accessors, including the property
descriptor a key path needs, are exported in the iOS 26.5 SDK's `WidgetKit.tbd`
(§6.3).** So the switch is reachable by the linker. If it can be flipped, font
*data* is embedded into the archive rather than referenced, runtime-registered
fonts simply work, and **the existing engine keeps working unchanged** — no
rewrite, no bundling, no recompile. That is the least disruptive path to the goal.

Next steps, in order: check whether these accessors were public in the
iOS 14/15 SDK interfaces the way `_ClockHandRotationEffect` was (if so, the same
vendored-xcframework trick applies with no `@_silgen_name`); then test with
**one** lane font before 64.

Risks: private API (same calculus as §5.6); and the Live Activity evidence
suggests embedding may be **quadratic in use sites** (§6.3) — a 109 KB TTF
inflated an archive to 2.5 MB — which for 64 lane fonts would be fatal.

**Confidence: reachable (measured); effect unverified. High payoff, low cost.**

### 3. Fix the diagnostics before running any more experiments

Capture `ArchivingError.failedToEncode`'s type list from the **extension's own**
os_log stream rather than chronod's reload reason (§6.1). This repo has been
bisecting routes one at a time [CODE: commit `ab658b7`] to recover information the
system was already printing by name. This is pure cost reduction on everything
above and below.

**Confidence: high. Cost: low.**

### 4. Test whether a live *text* mask gates a static `Image`

Now much more likely to succeed than when I started (§4.1) — a rotating-shape mask
over a static `Image` is proven, so the compositing is content-agnostic. If live
text also gates static imagery, the existing blink-font machinery can drive
user-supplied images with **only a small static mask font bundled**, and the
frame content leaves the font entirely. That is a fully-public-API path to the goal.

Three bands in one widget, on device. Cost: an afternoon.

**Confidence it works: high [INF]. Payoff: the whole goal, with no private API.**

### 5. Re-test `.process`-scope registration from the extension's own container

The sandbox log (§6.2) shows chronod denied on an **App Group** path. It does not
show what happens for a path inside the extension's *own* container — the
`cachesProcess` route already built here [CODE: `Shared/FontLab.swift`] and never
conclusively resolved on device. If chronod can read the extension's own Caches,
the app could write fonts there at runtime and the bundling constraint dissolves
with no private API at all.

**Confidence: low-medium (the sandbox grant probably doesn't extend there either),
but the harness already exists.**

### 6. `SwingAnimation`-style nested counter-rotations as a filmstrip pan

If route 1 works, this is the natural follow-on: `TopWidgets/SwingAnimation`
converts rotation into bounded **linear** translation (§5.3). A long horizontal
filmstrip panned by a fixed aperture is simpler to author from a video than a
radial wedge layout, and it reuses the same single live effect. Subject to the
pixel-area cap on the strip.

**Confidence: medium. Only worth doing after route 1 is proven on iOS 26/27.**

### 7. `ProgressView(timerInterval:)` as a live geometric mask

The only *public*, continuously-driven, non-glyph primitive (§3). Nobody has
tried it. Worth one probe: does it produce a moving edge inside `.mask { }` in an
archived widget? Even a yes leaves the once-through-the-interval problem
unsolved, but it would be a new fully-public primitive and a fallback if the
private route ever closes.

**Confidence: unverified. Low cost, uncertain payoff.**

### 8. Do not pursue

`TimelineView`, `PhaseAnimator`, `.repeatForever`, `withAnimation`, Live
Activities, AppIntent self-driving loops, timeline-entry flipbooks at 1 fps.
Each is foreclosed by §7 or §8 with high confidence.

---

## 11. Contradictions with the established findings — flagged deliberately

1. **`badTimelineData` is not an archiver error.** It is a `Reload.Reason` in
   ChronoCore, downstream of one of four `WidgetArchiver.ArchivingError` cases,
   one of which names the offending types outright (§6.1). The received framing in
   this project treats it as the error itself.

2. **"Runtime-registered fonts never reach the renderer" is two different bugs,
   not one, and only one of them is about the renderer** (§6.2).
   `RegisterGraphicsFont` and raw `CTFont` fail at **encode** time in the
   extension. `RegisterFontsForURL` from an App Group encodes fine and fails at
   **decode** time on a chronod sandbox denial. They need different fixes, and
   only the second is a "renderer" problem.

3. **`_wantsCustomFontsEmbeddedInArchive` exists** (§6.3). The bundling
   requirement is a WidgetKit *policy default*, not a format limitation. The
   archive can carry font bytes; it is configured not to for Home Screen widgets.
   This is the strongest evidence yet that the project's central constraint is
   soft.

4. **The whole font architecture may be unnecessary.** Widget GIF playback with
   arbitrary imagery and no custom fonts is **already shipping** — N stacked
   static `Image`s under rotating wedge masks driven by `_clockHandRotationEffect`
   (§5.3). The premise that arbitrary per-frame imagery requires encoding frames
   as glyphs is false; it is true only if you restrict yourself to public API.

5. **`_clockHandRotationEffect` was public API for two years.** It is in the
   shipped `.swiftinterface` for iOS 14.0 – 15.6 and macOS 11.0 – 11.3, stripped
   at iOS 16.1, and its exported symbol and signature are **unchanged through
   iOS 26.5** (§5.1, §5.5). "Private API" understates how reachable it is.

6. **I was wrong mid-investigation and am recording it.** I concluded the public
   shims were dead on iOS 26 because they targeted a SwiftUI symbol that no longer
   exists. They target the *WidgetKit* symbol, which is still exported in the
   iOS 26.5 SDK. `WidgetAnimation` issue #4 has some other cause I did not
   determine (§5.5).

7. **The 30 MB widget extension memory limit is contradicted by this project's own
   measurement of ~45 MB on an iPhone 17 Pro** (§6.4). Both numbers are first-hand
   (Apple engineers in forums vs. a local jetsam report). Do not average them —
   the discrepancy is the finding, and it means the cap should be measured per
   device rather than assumed.

8. **Masks are live over static content, not only over live glyphs** (§4.1). A
   rotating mask over a static `Image` is proven by shipping code. Any model in
   which "only the text glyph itself is live" is far too narrow — the render
   server does live compositing of arbitrary content.

9. **The image cap is pixel *area*, host-configured, and device-varying** — not a
   byte size and not a constant (§6.4). Disassembly shows an explicit
   "no size constraints configured" branch.

10. **`ProgressView(timerInterval:)` is a second continuously-driven primitive**
    and is absent from this project's model entirely (§3).

11. **Simulator results are systematically misleading in both directions.** Its
   weaker sandbox makes App Group font loading falsely succeed; a debugger-attached
   extension makes `TimelineView` falsely succeed. Every route here needs device
   confirmation.

---

## 12. Reproducing the binary evidence

```bash
RR="/Library/Developer/CoreSimulator/Volumes/iOS_23F77/Library/Developer/CoreSimulator/\
Profiles/Runtimes/iOS 26.5.simruntime/Contents/Resources/RuntimeRoot"
WK="$RR/System/Library/Frameworks/WidgetKit.framework/WidgetKit"
SU="$RR/System/Library/Frameworks/SwiftUI.framework/SwiftUI"

# exact clock-hand signature (strings/grep will NOT find these - exports trie)
nm -a "$WK" | grep -i clockhand
nm -a "$WK" | grep -i clockhand | xcrun swift-demangle

# the font-embedding escape hatch
nm -a "$WK" | grep -i wantsCustomFonts
nm -a "$WK" | grep encodesCustomFontsAsURLs

# archive capability flags
nm -a "$SU" | grep ArchivedViewInputV5FlagsV | grep vgZ

# every archivable modifier in WidgetKit (only three exist)
nm -a "$WK" | grep -oE '_\$s9WidgetKit[0-9]+[A-Za-z0-9_]*V7SwiftUI23_ArchivableViewModifierAAMc'

# archivable views/modifiers in SwiftUI
strings -a "$SU" | grep -E 'Archivable[A-Za-z]+' | sort -u

# the image-area check
otool -tV "$WK" | grep -n 'too large'      # then read ~100 lines around it

# linkability of the private symbols (all are exported in the SDK stub)
TBD=/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/\
Developer/SDKs/iPhoneSimulator.sdk/System/Library/Frameworks/WidgetKit.framework/WidgetKit.tbd
grep -o '[A-Za-z0-9_$]*clockHandRotationEffect[A-Za-z0-9_$]*'        "$TBD" | sort -u
grep -o '[A-Za-z0-9_$]*wantsCustomFontsEmbeddedInArchive[A-Za-z0-9_$]*' "$TBD" | sort -u
grep -o '[A-Za-z0-9_$]*encodesCustomFontsAsURLs[A-Za-z0-9_$]*'       "$TBD" | sort -u
```

The `.tbd` is plain YAML, so `grep` works there even though it does not work on
the Mach-O (the exports-trie problem in §0).

Source-accessibility probe (both fail to typecheck on the 26.5 SDK):

```swift
import SwiftUI
import WidgetKit
struct Probe: View {
    var body: some View {
        Image(systemName: "star")
            ._clockHandRotationEffect(.custom(2.0), in: .current, anchor: .center)
            .environment(\._wantsCustomFontsEmbeddedInArchive, true)
    }
}
```
```
error: value of type 'Image' has no member '_clockHandRotationEffect'
error: cannot infer key path type from context
```

---

## 13. Master list of what remains unverified

| Question | What would settle it |
|---|---|
| **Does the wedge-mask flipbook still work on iOS 26 / 27?** All prior art predates iOS 26 | Reproduce DouYinComment's construction — it works in-app too, so no widget needed for the first check |
| Is `_wantsCustomFontsEmbeddedInArchive` linkable, and is embedding quadratic? | `grep` the `.tbd`; then a 1-lane shim |
| Does a live *text* mask gate a static `Image` / `Color`? | Three-band device render (§4.1). Rotating-shape masks over static images are already proven |
| Can chronod read the *extension's own* Caches directory? | Finish the `cachesProcess` lab route on device |
| `_clockHandRotationEffect` on Lock Screen accessory families and under Always-On | No example exercises either |
| Actual cause of `WidgetAnimation` issue #4 on iOS 26 | Not a missing symbol (§5.5); cause undetermined |
| Do Metal shaders render at all in a widget? | `Rectangle().colorEffect(ShaderLibrary.bundle(.main)...)`, one entry per minute |
| Does `ProgressView(timerInterval:)` work inside `.mask { }`? | Single device probe |
| `.blendMode` / `.luminanceToAlpha` liveness in an archived widget | Device probe alongside §4 |
| Whole tree vs. text-region re-rasterisation | Core Animation instrument trace on device |
| Real extension memory cap on modern hardware (30 vs 45 MB) | Ramp allocation in the extension, read the jetsam report |
| How the per-image `totalArea` maximum is computed per device | A developer asked Apple directly and got no answer |
| ~200 concurrent live-`Text` ceiling | Single second-hand blog claim; binary-search on device |
| Low Power Mode / Reduce Motion effect on live text | No source exists at all |
| `drawingGroup()`, `.visualEffect`, `PhaseAnimator` in widgets | No source either way |
| iOS 27 "dynamic styling" | Not defined as an API anywhere Apple has published |

---

## 14. Primary sources

- Apple, [Displaying dynamic dates in widgets](https://developer.apple.com/documentation/widgetkit/displaying-dynamic-dates)
- Apple, [Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)
- Apple, [Animating data updates in widgets and Live Activities](https://developer.apple.com/documentation/widgetkit/animating-data-updates-in-widgets-and-live-activities)
- Apple, [SwiftUI views for widgets](https://developer.apple.com/documentation/widgetkit/swiftui-views) — the allowlist
- Apple, [Adding interactivity to widgets and Live Activities](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities)
- Apple, [Optimizing your widget for accented rendering mode and Liquid Glass](https://developer.apple.com/documentation/WidgetKit/optimizing-your-widget-for-accented-rendering-mode-and-liquid-glass)
- Apple, [ActivityKit](https://developer.apple.com/documentation/activitykit)
- WWDC20 [10028 Meet WidgetKit](https://developer.apple.com/videos/play/wwdc2020/10028/) · [10033 Build SwiftUI views for widgets](https://developer.apple.com/videos/play/wwdc2020/10033/)
- WWDC21 [10048 Principles of great widgets](https://developer.apple.com/videos/play/wwdc2021/10048/)
- WWDC23 [10028 Bring widgets to life](https://developer.apple.com/videos/play/wwdc2023/10028/)
- WWDC25 [278 What's new in widgets](https://developer.apple.com/videos/play/wwdc2025/278/)
- WWDC26 [277 WidgetKit foundations](https://developer.apple.com/videos/play/wwdc2026/277/) · [223 Live Activities essentials](https://developer.apple.com/videos/play/wwdc2026/223/) · [322 Compose advanced graphics effects with SwiftUI](https://developer.apple.com/videos/play/wwdc2026/322/)
- Forums: [671476](https://developer.apple.com/forums/thread/671476) chronod sandbox denial · [659332](https://developer.apple.com/forums/thread/659332) / [654408](https://developer.apple.com/forums/thread/654408) graphics-font archiving error · [715159](https://developer.apple.com/forums/thread/715159) Live Activity font embedding · [768169](https://developer.apple.com/forums/thread/768169) / [710745](https://developer.apple.com/forums/thread/710745) image area cap · [779546](https://developer.apple.com/forums/thread/779546) 10 MB / 72 refreshes / unlimited entries · [713561](https://developer.apple.com/forums/thread/713561) 30 MB jetsam · [766932](https://developer.apple.com/forums/thread/766932) TimelineView fires twice · [652946](https://developer.apple.com/forums/thread/652946) background reloads · [731715](https://developer.apple.com/forums/thread/731715) Live Activity budget recovery · [763797](https://developer.apple.com/forums/thread/763797) sizing modifiers degenerate
- Bryce Bostwick, [WidgetAnimation](https://github.com/brycebostwick/WidgetAnimation) (MIT) — the fully-public-API font technique this project is built on
- Old SDK interfaces where `_ClockHandRotationEffect` was public:
  [iPhoneOS14.5](https://raw.githubusercontent.com/xybp888/iOS-SDKs/master/iPhoneOS14.5.sdk/System/Library/Frameworks/WidgetKit.framework/Modules/WidgetKit.swiftmodule/arm64e-apple-ios.swiftinterface) ·
  [iPhoneOS15.6](https://raw.githubusercontent.com/xybp888/iOS-SDKs/master/iPhoneOS15.6.sdk/System/Library/Frameworks/WidgetKit.framework/Modules/WidgetKit.swiftmodule/arm64e-apple-ios.swiftinterface) ·
  [MacOSX11.3](https://github.com/phracker/MacOSX-SDKs/blob/master/MacOSX11.3.sdk/System/Library/Frameworks/WidgetKit.framework/Versions/A/Modules/WidgetKit.swiftmodule/arm64e.swiftinterface)
- Prior art for arbitrary-imagery widget animation:
  [tangtiancheng/DouYinComment](https://github.com/tangtiancheng/DouYinComment) —
  `GifVideoPlay.swift` (wedge-mask GIF playback), `ScrolPick.swift`, `Fan.swift`, `Shake.swift` ·
  [TopWidgets/SwingAnimation](https://github.com/TopWidgets/SwingAnimation) (rotation → linear pan; ships in App Store app Top Widgets⁺) ·
  [octree/ClockHandRotationKit](https://github.com/octree/ClockHandRotationKit) ·
  [everettjf/Xcode13ClockHandRotationEffectModifier](https://github.com/everettjf/Xcode13ClockHandRotationEffectModifier) ·
  [pawello2222/WidgetExamples](https://github.com/pawello2222/WidgetExamples) ·
  [giljihun/ClockHandKit](https://github.com/giljihun/ClockHandKit) (runtime `_typeByName` bridge, experimental)
- This repo: `RESEARCH.md`, `docs/ORIGINAL_TECHNIQUE_NOTES.txt`; and the Motionary
  sibling project's `Shared/FontLab.swift`, `Shared/RuntimeFontRegistry.swift`,
  `Shared/CompositionView.swift`, `Shared/Pipeline/FrameEncoder.swift`
