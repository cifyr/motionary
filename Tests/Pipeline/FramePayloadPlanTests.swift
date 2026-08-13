import XCTest

/// What a delivered frame set is encoded at. The font path's answer is wrong
/// here by roughly the number of glyph selections a frame used to be copied
/// into, and both directions of getting it wrong are quiet: too low wastes
/// fidelity nobody can see is missing, too high sends a package that will not
/// arrive.
final class FramePayloadPlanTests: XCTestCase {
    /// The ladder only ever goes down, and it ends. A cycle here would re-encode
    /// a frame set forever inside a build.
    func testTheLadderDescendsAndTerminates() {
        var quality = FramePayloadPlan.bestQuality
        var seen: [Double] = [quality]
        while let next = FramePayloadPlan.nextQuality(after: quality) {
            XCTAssertLessThan(next, quality, "the ladder has to descend")
            quality = next
            seen.append(quality)
            XCTAssertLessThan(seen.count, 20, "the ladder does not terminate")
        }
        XCTAssertEqual(seen, FramePayloadPlan.qualityLadder)
    }

    /// Starts well above what the font path can afford: the whole finding is
    /// that a written-once frame has several hundred times the budget of one
    /// base64'd into every glyph selection.
    func testItStartsHigherThanTheFontPathCouldAfford() {
        XCTAssertGreaterThanOrEqual(FramePayloadPlan.bestQuality, 0.9)
    }

    /// The budget has to stay under the archive limit it was written against,
    /// which it did not: 12MB was called "well under" a figure of 10.
    ///
    /// Photographed rather than reasoned about - a 11.9MB frame set draws
    /// nothing on the Home Screen and the same design at 9.9MB draws, with the
    /// extension reporting `ok` either way, because all it does is hand over
    /// the bytes.
    func testTheBudgetStaysUnderTheArchiveLimit() {
        XCTAssertLessThanOrEqual(
            FramePayloadPlan.defaultByteBudget, 10 * 1_048_576,
            "over this the widget is black and nothing says so"
        )
    }

    func testASetThatFitsIsNotReEncoded() {
        XCTAssertNil(FramePayloadPlan.retry(totalBytes: 1_000_000, at: 0.92))
        XCTAssertTrue(FramePayloadPlan.fits(totalBytes: FramePayloadPlan.byteBudget))
    }

    func testASetOverBudgetStepsDownUntilTheLadderIsSpent() {
        let over = FramePayloadPlan.byteBudget + 1
        let next = FramePayloadPlan.retry(totalBytes: over, at: FramePayloadPlan.bestQuality)
        XCTAssertEqual(next, FramePayloadPlan.qualityLadder[1])

        // At the bottom it gives up rather than looping: a design slightly too
        // big to send is more use than no design.
        XCTAssertNil(
            FramePayloadPlan.retry(totalBytes: over, at: FramePayloadPlan.qualityLadder.last!)
        )
    }

    /// Over the renderer's cap the frame comes out blank with nothing logged,
    /// so the guard is on area and it has to actually get under it.
    func testAnOversizedFrameIsShrunkUnderTheCap() {
        let huge = CGSize(width: 3000, height: 2000)
        let scale = FramePayloadPlan.scale(for: huge)
        XCTAssertLessThan(scale, 1)
        let scaledArea = Double(huge.width * scale) * Double(huge.height * scale)
        XCTAssertLessThanOrEqual(scaledArea, FramePayloadPlan.maximumPixelArea + 1)
    }

    /// The calibrated phone's widget frame is 1074x1632, which is comfortably
    /// under - so the guard must not touch it. Shrinking a frame that fits
    /// would soften every delivered design on the one device this is measured
    /// against.
    func testTheCalibratedWidgetFrameIsLeftAlone() {
        XCTAssertEqual(FramePayloadPlan.scale(for: CGSize(width: 1074, height: 1632)), 1)
        XCTAssertEqual(FramePayloadPlan.scale(for: .zero), 1)
    }
}
