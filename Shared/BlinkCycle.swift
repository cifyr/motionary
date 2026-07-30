import Foundation

/// The two-second window the bundled blink font can express, and how a source
/// loop is fitted into it.
///
/// A design normally reaches the Home Screen by being compiled into the widget
/// extension's bundle, because the animation is drawn by generated OT-SVG
/// colour-glyph fonts and a widget renderer will only draw a font that was in
/// its bundle at install time. That is the whole reason a Mac app exists.
///
/// There is a second way that needs no toolchain: ordinary `Image` layers
/// loaded from the app group at render time, each revealed by a mask cut from
/// `Custom-Regular` - the blink font, which is design-independent and already
/// ships with the extension. Nothing is generated, registered or compiled, so
/// the phone can make a whole design by itself.
///
/// What that font can express is the cap, and it is worth stating plainly.
/// `Custom-Regular` carries one `liga` lookup: a pair of timer digits becomes a
/// filled em square when the seconds count is even and nothing when it is odd.
/// Six ligature sets exist, one per tens digit, and all six map identically, so
/// the tens digit carries no information. A single blink text is therefore a
/// square wave of period two seconds, and two seconds is the longest loop
/// anything built out of this font can have. `BlinkCycleTests` asserts it.
enum BlinkCycle {
    /// The blink font's period: one second opaque, one second clear.
    static let cycleDuration: TimeInterval = 2

    /// Frames tile the cycle two per second of frame rate, so the rate is what
    /// a design stores and the frame count follows from it. Keeping the rate
    /// the integer means the extractor can sample on the design's own timeline
    /// without a fractional frame rate to round.
    static func frameCount(framesPerSecond: Int) -> Int {
        2 * max(minimumFramesPerSecond, framesPerSecond)
    }

    /// A window is the overlap of two square waves, each opaque for exactly one
    /// second, so no window can be wider than a second and fewer than two slots
    /// cannot tile the cycle.
    static let minimumFramesPerSecond = 1

    /// Not a geometric limit - the slot arithmetic works at any count. It is
    /// how many pictures an extension can hold: the widget is killed a little
    /// above 45MB, and a measured sweep put 512 frames at 116MB.
    static let maximumFramesPerSecond = 48

    static func clampedFramesPerSecond(_ rate: Int) -> Int {
        min(max(rate, minimumFramesPerSecond), maximumFramesPerSecond)
    }

    // MARK: - Slot maths

    /// Where slot `index` of `count` starts within the two-second cycle.
    static func slotStart(index: Int, count: Int) -> TimeInterval {
        cycleDuration * Double(index) / Double(max(1, count))
    }

    static func slotWidth(count: Int) -> TimeInterval {
        cycleDuration / Double(max(1, count))
    }

    /// Whether a single blink text offset by `offset` is opaque at `date`.
    ///
    /// The model, not a reimplementation: the font turns the seconds count of
    /// the elapsed time into a filled square when that count is even. Written
    /// down here so the slot arithmetic can be tested without a widget.
    static func pulseIsOpaque(offset: TimeInterval, at date: Date, reference: Date) -> Bool {
        let elapsed = date.timeIntervalSince(reference.addingTimeInterval(offset))
        let whole = Int(floor(elapsed))
        return ((whole % 2) + 2) % 2 == 0
    }

    /// The second offset that, intersected with `start`, cuts the window down
    /// to `width`.
    ///
    /// A pulse at `s` is opaque on `[s, s + 1)`. Intersecting it with a pulse at
    /// `s + width - 1`, which is opaque on `[s + width - 1, s + width)`, leaves
    /// exactly `[s, s + width)`.
    static func trailingOffset(start: TimeInterval, width: TimeInterval) -> TimeInterval {
        let raw = start + width - 1
        return raw.truncatingRemainder(dividingBy: cycleDuration) + (raw < 0 ? cycleDuration : 0)
    }

    static func slotIsOpaque(index: Int, count: Int, at date: Date, reference: Date) -> Bool {
        let start = slotStart(index: index, count: count)
        let width = slotWidth(count: count)
        return pulseIsOpaque(offset: start, at: date, reference: reference)
            && pulseIsOpaque(
                offset: trailingOffset(start: start, width: width),
                at: date,
                reference: reference
            )
    }

    /// Which frames the stack has opaque at `date`. Exactly one, if the windows
    /// tile the cycle as intended.
    static func opaqueSlots(count: Int, at date: Date, reference: Date) -> [Int] {
        (0 ..< count).filter { slotIsOpaque(index: $0, count: count, at: date, reference: reference) }
    }

    /// The slot the cycle is in at `date`, worked out directly.
    ///
    /// The app needs this. It cannot draw the mask at all - only the system
    /// widget renderer advances timer text - so it shows one picture and swaps
    /// it on a timer. Deriving the index from the same phase the mask uses is
    /// what makes opening the app continue the widget's loop instead of
    /// restarting it, and `BlinkCycleTests` checks the two agree.
    static func slot(count: Int, at date: Date, reference: Date) -> Int {
        let slots = max(1, count)
        let elapsed = date.timeIntervalSince(reference)
        var phase = elapsed.truncatingRemainder(dividingBy: cycleDuration)
        if phase < 0 { phase += cycleDuration }
        return min(slots - 1, max(0, Int(phase / slotWidth(count: slots))))
    }

    // MARK: - Fitting a source loop to the cycle

    /// How a source's own loop is made to land exactly on the two-second cycle.
    ///
    /// This is the part the cap really costs. The mask repeats every two
    /// seconds whatever is drawn, so a loop that does not divide two seconds
    /// gets cut mid-motion at the wrap - a 0.75s loop would play two and
    /// two-thirds times and jump. Rather than accept the jump, the loop is
    /// played a whole number of times inside the cycle and the playback speed
    /// is nudged by whatever that costs: 0.75s three times is 1.125x, 1.25s
    /// twice is 1.25x. Small enough not to read as wrong, and seamless.
    struct LoopFit: Equatable, Sendable {
        /// How many times the source loop plays inside one cycle.
        let repeats: Int
        /// Playback speed that makes those repeats fill the cycle exactly.
        let speed: Double
        /// The source's own loop length, unchanged.
        let sourceLoop: TimeInterval

        /// How far from real time the result runs, as a fraction. 0.125 is
        /// 12.5% fast.
        var drift: Double { abs(speed - 1) }

        /// How long one repetition lasts on screen.
        var playedLoop: TimeInterval { BlinkCycle.cycleDuration / Double(max(1, repeats)) }
    }

    /// The whole-number repeat count that costs the least speed change.
    ///
    /// Rounding rather than flooring: a 1.9s loop played twice is 5% fast,
    /// played once it is 5% slow, and either is better than the 1.9-into-2
    /// seam. A source longer than the cycle can only be played once and is
    /// slowed to fit, which is the one case where the two-second cap is
    /// genuinely visible.
    static func fit(sourceLoop: TimeInterval, maximumRepeats: Int = 16) -> LoopFit {
        guard sourceLoop > 0 else {
            return LoopFit(repeats: 1, speed: 1, sourceLoop: cycleDuration)
        }
        let ideal = cycleDuration / sourceLoop
        let repeats = min(max(1, Int(ideal.rounded())), max(1, maximumRepeats))
        return LoopFit(
            repeats: repeats,
            speed: sourceLoop * Double(repeats) / cycleDuration,
            sourceLoop: sourceLoop
        )
    }
}
