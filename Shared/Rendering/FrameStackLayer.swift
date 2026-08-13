import SwiftUI

/// The animated layer for a design built as pictures: one frame per lane,
/// stacked, with the blink mask making exactly one of them visible at a time.
///
/// The same mechanism as `TimerFontLayer` with the glyphs taken out. There, a
/// lane is a timer text whose font supplies fifteen frames and the mask picks
/// the lane; here a lane is a picture and the mask picks the picture. That
/// costs the fifteen - the loop is the stack, so `frames.count / fps` seconds -
/// and buys the only thing a font cannot do, which is arrive after the app was
/// installed.
///
/// Measured on device before it was written: 64 frames at 1620px archive clean
/// with the extension under 12MB, because `Image(uiImage:)` does not decode
/// until the render server draws it. See
/// `docs/widget-animation-surface.md` 4.1.1.
struct FrameStackLayer: View {
    let frames: [Image]
    /// How many mask phases the stack is spread over, which is not always how
    /// many frames there are: a clip shorter than the stack repeats around it
    /// rather than leaving the remaining lanes black. The lane cycle is fixed,
    /// so repeating plays the short loop several times per cycle at exactly the
    /// speed it was authored at.
    let laneCount: Int
    let framesPerSecond: Int
    /// The mask font, and how long it takes to repeat.
    ///
    /// The shipped mask is solid on even seconds, so it repeats every two - and
    /// that was the whole loop a picture-built design could have. A mask solid
    /// one second in `period` repeats every `period` seconds instead, which is
    /// how a clip longer than two seconds plays as long as it is.
    var maskFont = FontSetGenerator.blinkFontResourceName
    var maskPeriod: TimeInterval = 2

    /// Which frame a lane shows. Its own function because getting it wrong
    /// shows as a loop playing in the wrong order, which looks like a bad clip
    /// rather than like arithmetic.
    static func frameIndex(lane: Int, frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        return ((lane % frameCount) + frameCount) % frameCount
    }

    var body: some View {
        GeometryReader { geometry in
            // The mask's glyph is centred in a square canvas, so the square has
            // to cover the layer's long side. Only the mask needs this - a
            // picture is drawn at the layer's own aspect, where a glyph had to
            // be unsquashed afterwards.
            let side = max(geometry.size.width, geometry.size.height)
            let reference = TimerFontSpec.cycleAlignedReference()
            let lanes = max(1, laneCount)
            let half = max(1, lanes / 2)

            ZStack {
                if maskPeriod > 2 {
                    // One stack, drawn in phase order. Every mask is solid for
                    // a second, so several lanes are unmasked at once and the
                    // last one to have turned on is the one on top - the same
                    // ordering the two-second engine relies on, over a longer
                    // cycle. No half-split: that exists because a mask solid on
                    // every even second cannot tell the two halves of a
                    // two-second cycle apart, and one solid a second in ten can.
                    stack(0 ..< lanes, side: side, reference: reference, size: geometry.size)
                } else {
                    stack(0 ..< half, side: side, reference: reference, size: geometry.size)
                    // Split into two halves masked against each other: the blink
                    // mask can only isolate one lane within a half, so the second
                    // half is gated as a group.
                    stack(half ..< lanes, side: side, reference: reference, size: geometry.size)
                        .mask {
                            BlinkMask(reference: reference, blinkOffset: 1)
                                .frame(width: side, height: side)
                        }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .clipped()
        .accessibilityHidden(true)
    }

    private func stack(
        _ lanes: Range<Int>,
        side: CGFloat,
        reference: Date,
        size: CGSize
    ) -> some View {
        let frameDuration = 1 / Double(max(1, framesPerSecond))
        return ZStack {
            ForEach(Array(lanes), id: \.self) { lane in
                frames[Self.frameIndex(lane: lane, frameCount: frames.count)]
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
                    .mask {
                        BlinkMask(
                            reference: reference,
                            blinkOffset: Double(-lane) * frameDuration,
                            font: maskFont
                        )
                        .frame(width: side, height: side)
                    }
            }
        }
    }
}
