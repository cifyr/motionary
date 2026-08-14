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
    /// How many lanes each frame covers, when a set was too big to draw whole.
    ///
    /// The lanes that remain keep their own offsets rather than closing up, so
    /// the cycle still takes exactly as long - each frame is simply the one on
    /// top for `laneStride` phases instead of one. That is a lower frame rate,
    /// not a faster clip. See `FrameSetLoader.load`.
    var laneStride = 1
    /// Where each frame belongs inside the layer, as fractions of it.
    ///
    /// A cut-out design ships sprites - each frame cropped to the pixels that
    /// are actually in it - so the frames are different sizes and have to be
    /// put back rather than stretched across the whole crop. Nil for a design
    /// whose frames fill it, which is how they all used to be.
    var frameRects: [CGRect]?

    /// Which frame a lane shows. Its own function because getting it wrong
    /// shows as a loop playing in the wrong order, which looks like a bad clip
    /// rather than like arithmetic.
    static func frameIndex(lane: Int, frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        return ((lane % frameCount) + frameCount) % frameCount
    }

    /// Where the stack's last second begins.
    ///
    /// These lanes are gated as a group as well as individually, and that group
    /// gate is the whole reason a loop plays without stopping.
    ///
    /// The mask is solid for a whole second, so `framesPerSecond` lanes are
    /// unmasked at once and the highest wins - `stack` is one ZStack in lane
    /// order and later is on top. Lane `L` is solid when `floor(second - L/fps)`
    /// opens a period, and the lane offsets span exactly one period, so during
    /// the first second after a wrap the stack's last second is *still* solid
    /// from the previous pass. Being last, it sits on top of the frames that
    /// should be playing.
    ///
    /// Left flat that is a pause between loops. An 80-lane stack at 16fps held
    /// its final frame for fifteen steps and then jumped to lane fifteen: a
    /// second of stillness every five, and the first second of the clip never
    /// seen at all. Only 65 of its 80 frames ever reached the screen.
    ///
    /// The two-second engine has always split its stack in half for exactly
    /// this reason. This is that split generalised: at a two-second period the
    /// two are the same lanes and the same offset.
    static func tailStart(lanes: Int, framesPerSecond: Int) -> Int {
        max(1, max(1, lanes) - max(1, framesPerSecond))
    }

    /// The group gate's offset, in the terms `BlinkMask` takes it.
    ///
    /// `BlinkMask` draws `Text(reference - blinkOffset, style: .timer)`, so the
    /// seconds it reads are `cycleSecond + blinkOffset`: a *positive* offset
    /// makes the mask solid earlier in the period, not later. The tail wants
    /// the period's last second, which is `-(period - 1)`.
    ///
    /// This is the one line that has to be derived rather than copied. At a two
    /// second period `+1` and `-1` are the same second, so the sign was
    /// invisible in the only construction that had ever used it - and carrying
    /// the `+1` across to a five-second period gated the tail on second one
    /// instead of second four. That put a one-second freeze at the *end* of
    /// every loop: during the last second the tail is off and the low lanes
    /// have all gone quiet, so lane 63 held until the wrap.
    static func tailGateOffset(maskPeriod: TimeInterval) -> TimeInterval {
        1 - maskPeriod
    }

    /// Which lane is actually visible `second` into the cycle.
    ///
    /// Models both gates - the per-lane one and the group one over `tailStart`
    /// - and models the group one through `tailGateOffset` rather than through
    /// what it is meant to do, because the sign of that offset is exactly the
    /// thing that has been wrong.
    static func topLane(atCycleSecond second: Double, lanes: Int, framesPerSecond: Int) -> Int {
        let fps = Double(max(1, framesPerSecond))
        let lanes = max(1, lanes)
        let period = Double(lanes) / fps
        let tail = tailStart(lanes: lanes, framesPerSecond: framesPerSecond)
        // Read exactly as the mask reads it: the gate is solid while the timer
        // it drives shows a second that opens a period.
        let gateSecond = (second + tailGateOffset(maskPeriod: period)).rounded(.down)
        let tailDrawn = gateSecond.truncatingRemainder(dividingBy: period) == 0
        let solid = (0 ..< lanes).filter { lane in
            let shown = (second - Double(lane) / fps).rounded(.down)
            guard shown.truncatingRemainder(dividingBy: period) == 0 else { return false }
            return lane < tail || tailDrawn
        }
        return solid.max() ?? 0
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
            // Aligned to the stride so the strided lanes keep the frame indices
            // they would have had in one flat run.
            let step = max(1, laneStride)
            let tail = Self.tailStart(lanes: lanes, framesPerSecond: framesPerSecond) / step * step

            ZStack {
                stack(0 ..< tail, side: side, reference: reference, size: geometry.size)
                // The last second of the period, gated as a group as well as
                // per lane. Without it these lanes are still solid from the
                // previous pass during the first second after a wrap, and being
                // last in the stack they cover the frames that should be
                // playing - a pause between loops, and the opening second of
                // the clip never drawn. See `tailStart`.
                //
                // One extra offscreen buffer, not one per second of period.
                // Grouping every second was tried and rejected on that cost;
                // this is the two-second engine's own split, generalised, and
                // at a two-second period it is the identical construction.
                stack(tail ..< lanes, side: side, reference: reference, size: geometry.size)
                    .mask {
                        BlinkMask(
                            reference: reference,
                            blinkOffset: Self.tailGateOffset(maskPeriod: maskPeriod),
                            font: maskFont
                        )
                        .frame(width: side, height: side)
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
        let step = max(1, laneStride)
        let drawn = Array(Swift.stride(from: lanes.lowerBound, to: lanes.upperBound, by: step))
        return ZStack {
            ForEach(drawn, id: \.self) { lane in
                let index = Self.frameIndex(lane: lane / step, frameCount: frames.count)
                let rect = frameRects.flatMap { $0.indices.contains(index) ? $0[index] : nil }
                let gate = BlinkMask(
                    reference: reference,
                    blinkOffset: Double(-lane) * frameDuration,
                    font: maskFont
                )
                .frame(width: side, height: side)

                if let rect {
                    // Masked at the sprite's own size, then placed - not placed
                    // and then masked across the whole layer.
                    //
                    // This is what the frame rate was costing. A mask needs an
                    // offscreen buffer the size of what it masks, so gating a
                    // full-layer view gave every one of 320 lanes a full-crop
                    // buffer however small its picture was; the sprites made
                    // the images cheap and left the masks exactly as expensive.
                    // The glyph is a filled square covering its canvas, so a
                    // small view samples the middle of it and gates the same
                    // way.
                    frames[index]
                        .resizable()
                        .interpolation(.high)
                        .frame(width: rect.width * size.width, height: rect.height * size.height)
                        .mask { gate }
                        .offset(x: rect.minX * size.width, y: rect.minY * size.height)
                        .frame(width: size.width, height: size.height, alignment: .topLeading)
                } else {
                    frames[index]
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size.width, height: size.height)
                        .mask { gate }
                }
            }
        }
    }
}
