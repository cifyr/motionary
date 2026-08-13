import XCTest

/// The picture-built body of a design. What is testable here is the arithmetic
/// that decides which frame is on screen when, and it is worth testing because
/// every way of getting it wrong produces a plausible-looking loop rather than
/// an error.
final class FrameSetTests: XCTestCase {
    /// The stack is the loop: one picture per lane, so the length follows from
    /// the smoothness the design was built at and nothing else.
    func testTheLoopIsTheStackAndTheStackIsTwoSeconds() {
        for smoothness in MotionSmoothness.allCases {
            let spec = TimerFontSpec(smoothness: smoothness)
            XCTAssertEqual(FrameSetGenerator.frameCount(for: spec), spec.laneCount)
            XCTAssertEqual(
                FrameSetGenerator.loopDuration(for: spec),
                2.0,
                accuracy: 0.001,
                "\(smoothness) should still wrap with the lane cycle"
            )
        }
    }

    /// A clip shorter than the stack repeats around it rather than leaving the
    /// remaining lanes black, and the repeat has to start again from the first
    /// frame or the loop plays out of order.
    func testAShortLoopRepeatsAroundTheLanesInOrder() {
        let shown = (0 ..< 32).map { FrameStackLayer.frameIndex(lane: $0, frameCount: 5) }
        XCTAssertEqual(Array(shown.prefix(6)), [0, 1, 2, 3, 4, 0])
        XCTAssertEqual(shown.max(), 4)
        XCTAssertEqual(shown.min(), 0)
        // Consecutive lanes are consecutive frames, wrap aside: that is what
        // makes the stack read as a film rather than as a shuffle.
        for lane in 1 ..< 32 where shown[lane] != 0 {
            XCTAssertEqual(shown[lane], shown[lane - 1] + 1, "lane \(lane) skipped")
        }
    }

    func testEveryLaneShowsSomethingEvenWhenTheCountsAreAwkward() {
        for frameCount in [1, 3, 5, 7, 32, 64] {
            for lane in 0 ..< 64 {
                let index = FrameStackLayer.frameIndex(lane: lane, frameCount: frameCount)
                XCTAssertTrue((0 ..< frameCount).contains(index), "\(lane) of \(frameCount) -> \(index)")
            }
        }
    }

    /// An empty set must not index into nothing. The widget refuses to draw a
    /// partial stack, but the arithmetic is shared and has to hold anyway.
    func testNoFramesIsNotACrash() {
        XCTAssertEqual(FrameStackLayer.frameIndex(lane: 7, frameCount: 0), 0)
    }
}
