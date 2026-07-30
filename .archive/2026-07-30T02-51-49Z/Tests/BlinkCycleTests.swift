import XCTest

/// The slot arithmetic, checked against a model of what the bundled blink font
/// does, so the widget only has to answer the question the model cannot: does
/// the system re-render the mask often enough for the slots to be visible.
final class BlinkCycleTests: XCTestCase {
    /// Matches what the widget uses, and is 2-second aligned because 30 is.
    private let reference = TimerFontSpec.cycleAlignedReference(
        at: Date(timeIntervalSince1970: 1_800_000_000)
    )

    private func date(offsetIntoCycle phase: TimeInterval) -> Date {
        // Somewhere inside the reference's own cycle, so the elapsed time stays
        // in the M:SS shape the ligature table is built around.
        Date(timeIntervalSince1970: 1_800_000_000 + phase)
    }

    func testASinglePulseIsOpaqueForOneSecondInTwo() {
        for step in 0 ..< 40 {
            let phase = Double(step) / 20
            let opaque = BlinkCycle.pulseIsOpaque(
                offset: 0,
                at: date(offsetIntoCycle: phase),
                reference: reference
            )
            XCTAssertEqual(opaque, phase < 1, "phase \(phase)")
        }
    }

    func testAnOffsetPulseMovesItsEdges() {
        for step in 0 ..< 40 {
            let phase = Double(step) / 20
            let opaque = BlinkCycle.pulseIsOpaque(
                offset: 0.5,
                at: date(offsetIntoCycle: phase),
                reference: reference
            )
            XCTAssertEqual(opaque, phase >= 0.5 && phase < 1.5, "phase \(phase)")
        }
    }

    /// The whole mechanism in one assertion: at every instant of the cycle
    /// exactly one frame is showing, and it is the frame whose slot the instant
    /// falls in.
    func testEverySlotOwnsExactlyItsShareOfTheCycle() {
        for count in [2, 4, 16, 32, 64, 96] {
            let width = BlinkCycle.slotWidth(count: count)
            // Sampled off the boundaries: a sample landing exactly on an edge is
            // a question about floating point, not about the mask.
            for slot in 0 ..< count {
                for fraction in [0.1, 0.5, 0.9] {
                    let phase = BlinkCycle.slotStart(index: slot, count: count) + width * fraction
                    XCTAssertEqual(
                        BlinkCycle.opaqueSlots(
                            count: count,
                            at: date(offsetIntoCycle: phase),
                            reference: reference
                        ),
                        [slot],
                        "count \(count) phase \(phase)"
                    )
                }
            }
        }
    }

    /// The app draws one picture instead of masking N, and it has to pick the
    /// same one. Otherwise opening the app jumps the loop.
    func testTheDirectSlotAgreesWithTheMask() {
        for count in [2, 8, 32, 64] {
            let width = BlinkCycle.slotWidth(count: count)
            for slot in 0 ..< count {
                for fraction in [0.1, 0.5, 0.9] {
                    let phase = BlinkCycle.slotStart(index: slot, count: count) + width * fraction
                    let now = date(offsetIntoCycle: phase)
                    XCTAssertEqual(
                        BlinkCycle.slot(count: count, at: now, reference: reference),
                        BlinkCycle.opaqueSlots(count: count, at: now, reference: reference).first,
                        "count \(count) phase \(phase)"
                    )
                }
            }
        }
    }

    func testTheDirectSlotStaysInRangeAcrossManyCycles() {
        for step in 0 ..< 200 {
            let slot = BlinkCycle.slot(
                count: 64,
                at: date(offsetIntoCycle: Double(step) * 0.37),
                reference: reference
            )
            XCTAssertTrue(slot >= 0 && slot < 64, "step \(step) gave \(slot)")
        }
    }

    func testTheCycleRepeatsEveryTwoSeconds() {
        for step in 0 ..< 20 {
            let phase = Double(step) / 10
            XCTAssertEqual(
                BlinkCycle.opaqueSlots(count: 8, at: date(offsetIntoCycle: phase), reference: reference),
                BlinkCycle.opaqueSlots(
                    count: 8,
                    at: date(offsetIntoCycle: phase + BlinkCycle.cycleDuration),
                    reference: reference
                ),
                "phase \(phase)"
            )
        }
    }

    /// The ceiling this whole route cannot get past, and the reason the Mac path
    /// has to keep working. The blink font's ligature keys on nothing but
    /// whether the seconds count is even, so no arrangement of it can tell one
    /// two-second window from the next.
    func testNothingBuiltFromTheBlinkFontCanOutlastTwoSeconds() {
        for offset in stride(from: 0.0, to: 2.0, by: 0.25) {
            let now = date(offsetIntoCycle: 0.4)
            XCTAssertEqual(
                BlinkCycle.pulseIsOpaque(offset: offset, at: now, reference: reference),
                BlinkCycle.pulseIsOpaque(
                    offset: offset,
                    at: now.addingTimeInterval(BlinkCycle.cycleDuration),
                    reference: reference
                ),
                "offset \(offset)"
            )
        }
    }

    func testTrailingOffsetStaysInsideTheCycle() {
        for count in [2, 4, 16, 64] {
            for slot in 0 ..< count {
                let start = BlinkCycle.slotStart(index: slot, count: count)
                let trailing = BlinkCycle.trailingOffset(
                    start: start,
                    width: BlinkCycle.slotWidth(count: count)
                )
                XCTAssertTrue(
                    trailing >= 0 && trailing < BlinkCycle.cycleDuration,
                    "count \(count) slot \(slot) -> \(trailing)"
                )
            }
        }
    }

    // MARK: - Frame counts

    func testFramesTileTheCycleTwoPerFrameRate() {
        XCTAssertEqual(BlinkCycle.frameCount(framesPerSecond: 32), 64)
        XCTAssertEqual(BlinkCycle.frameCount(framesPerSecond: 8), 16)
    }

    /// One frame cannot be masked into a two-second cycle by windows that are at
    /// most a second wide, so a nonsense rate is clamped rather than allowed to
    /// draw a widget that is blank half the time.
    func testAnImpossibleFrameRateIsClamped() {
        XCTAssertEqual(BlinkCycle.clampedFramesPerSecond(0), BlinkCycle.minimumFramesPerSecond)
        XCTAssertEqual(BlinkCycle.clampedFramesPerSecond(-4), BlinkCycle.minimumFramesPerSecond)
        XCTAssertEqual(BlinkCycle.clampedFramesPerSecond(9_000), BlinkCycle.maximumFramesPerSecond)
        XCTAssertGreaterThanOrEqual(BlinkCycle.frameCount(framesPerSecond: 0), 2)
    }

    // MARK: - Fitting a source loop

    /// The two lengths the designs this was built for actually are. Neither
    /// divides two seconds, and the point of the fit is that neither has to.
    func testTheRealLoopLengthsLandExactlyOnTheCycle() {
        let threeQuarters = BlinkCycle.fit(sourceLoop: 0.75)
        XCTAssertEqual(threeQuarters.repeats, 3)
        XCTAssertEqual(threeQuarters.speed, 1.125, accuracy: 0.0001)

        let fiveQuarters = BlinkCycle.fit(sourceLoop: 1.25)
        XCTAssertEqual(fiveQuarters.repeats, 2)
        XCTAssertEqual(fiveQuarters.speed, 1.25, accuracy: 0.0001)
    }

    /// The property that makes the fit worth doing: whatever the source's own
    /// length, the repeats fill the cycle exactly, so the wrap never cuts
    /// mid-motion.
    func testEveryFitFillsTheCycleExactly() {
        for milliseconds in stride(from: 100, through: 6_000, by: 50) {
            let source = Double(milliseconds) / 1000
            let fit = BlinkCycle.fit(sourceLoop: source)
            XCTAssertEqual(
                fit.playedLoop * Double(fit.repeats),
                BlinkCycle.cycleDuration,
                accuracy: 0.0001,
                "source \(source)s"
            )
            // The played length is the source's own length divided by the speed
            // that was chosen, or the motion would be wrong as well as seamless.
            XCTAssertEqual(fit.playedLoop, source / fit.speed, accuracy: 0.0001, "source \(source)s")
        }
    }

    func testAShortLoopIsPlayedMoreOftenThanALongOne() {
        XCTAssertGreaterThan(
            BlinkCycle.fit(sourceLoop: 0.25).repeats,
            BlinkCycle.fit(sourceLoop: 1.0).repeats
        )
    }

    /// A clip longer than the cycle can only be played once, and is slowed to
    /// fit. That is the one case where the two-second cap is genuinely visible,
    /// and it should be reported rather than hidden.
    func testALongClipIsSlowedRatherThanCut() {
        let fit = BlinkCycle.fit(sourceLoop: 6)
        XCTAssertEqual(fit.repeats, 1)
        XCTAssertEqual(fit.speed, 3, accuracy: 0.0001)
        XCTAssertGreaterThan(fit.drift, 1)
    }

    func testAZeroLengthSourceDoesNotDivideByZero() {
        let fit = BlinkCycle.fit(sourceLoop: 0)
        XCTAssertEqual(fit.repeats, 1)
        XCTAssertEqual(fit.speed, 1)
    }
}
