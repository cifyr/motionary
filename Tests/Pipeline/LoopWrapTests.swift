import XCTest

/// What the stack shows at the moment the loop wraps.
///
/// This is the one place in the engine where two lanes are lit at once for a
/// reason other than the usual overlap, and it cost a reported bug: the first
/// clip of Spidey Swing came back as a flicker of a swing that a later clip
/// then performed in full, which reads as a replay.
final class LoopWrapTests: XCTestCase {
    private let lanes = 720
    private let fps = 24

    /// In the body of the cycle the visible lane is just the phase: the run of
    /// solid lanes ends there and nothing above it is lit.
    func testTheVisibleLaneIsThePhase() {
        for second in [1.0, 5.5, 17.25, 29.9] {
            let top = FrameStackLayer.topLane(atCycleSecond: second, lanes: lanes, framesPerSecond: fps)
            XCTAssertEqual(top, Int(second * Double(fps)), "\(second)s")
        }
    }

    /// The wrap: the solid run is split across both ends of the stack, and the
    /// end wins because the stack is drawn in lane order.
    ///
    /// So the last second of the stack is composited over the first second of
    /// it, and whatever sits in those top lanes is what the loop opens with.
    func testTheEndOfTheStackCoversTheStartOfIt() {
        // The run at the top of the stack shrinks as the second passes - lane
        // `L` is in it while `L > fps * (second - 1)` - so it is gone by the
        // time the second is up rather than handing over abruptly.
        for second in [30.0, 30.25, 30.5, 30.9] {
            let top = FrameStackLayer.topLane(atCycleSecond: second, lanes: lanes, framesPerSecond: fps)
            XCTAssertGreaterThanOrEqual(
                top, lanes - fps,
                "\(second)s into the cycle the top lane should still be in the last second of the stack"
            )
        }
        // And it lets go exactly one second in, not before.
        XCTAssertLessThan(
            FrameStackLayer.topLane(atCycleSecond: 31.0, lanes: lanes, framesPerSecond: fps),
            fps + 1
        )
    }

    /// Which is why the pause goes first. Padding the stack at the end put an
    /// opaque backdrop patch in the lanes that win the wrap, so it erased the
    /// opening of the first clip once per loop.
    func testThePauseIsAtTheFrontWhereItCannotCoverAClip() {
        let clip = Array(1 ... 600)                        // real frames, all non-zero
        let stack = FrameSetGenerator.paused(clip, lanes: lanes, blank: 0)
        XCTAssertEqual(stack.count, lanes)
        XCTAssertEqual(Array(stack.prefix(120)), Array(repeating: 0, count: 120))
        XCTAssertEqual(Array(stack.suffix(600)), clip, "the clips keep their order and their length")

        // The lanes the wrap draws on top carry clip, not pause.
        for second in stride(from: 30.0, to: 31.0, by: 0.1) {
            let top = FrameStackLayer.topLane(atCycleSecond: second, lanes: lanes, framesPerSecond: fps)
            XCTAssertNotEqual(stack[top], 0, "lane \(top) is a pause lane covering the loop's opening")
        }
    }

    /// A stack that already fills the period is handed back untouched - there
    /// is no pause to place, and prepending nothing must not shift the clips.
    func testAFullStackIsUnchanged() {
        let full = Array(0 ..< lanes)
        XCTAssertEqual(FrameSetGenerator.paused(full, lanes: lanes, blank: -1), full)
        XCTAssertEqual(FrameSetGenerator.paused(full, lanes: 100, blank: -1), full)
    }
}
