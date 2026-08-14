import XCTest

/// What the stack shows at the moment the loop wraps.
///
/// This is the one place in the engine where lanes are lit for a reason other
/// than the usual overlap, and it has cost two reported bugs. First the opening
/// of Spidey Swing came back as a flicker that a later clip then performed in
/// full, which reads as a replay. Then, once that was placed, a pause between
/// loops - most visible on a five-second clip, where a second of stillness is a
/// fifth of the whole thing.
///
/// Both are the same arithmetic. The mask is solid for a whole second and the
/// lane offsets span exactly one period, so during the first second after a
/// wrap the stack's last second is still solid from the previous pass, and
/// being last in the ZStack it is on top of the frames that should be playing.
final class LoopWrapTests: XCTestCase {
    private let lanes = 720
    private let fps = 24

    /// In the body of the cycle the visible lane is just the phase.
    func testTheVisibleLaneIsThePhase() {
        for second in [1.0, 5.5, 17.25, 29.9] {
            let top = FrameStackLayer.topLane(atCycleSecond: second, lanes: lanes, framesPerSecond: fps)
            XCTAssertEqual(top, Int(second * Double(fps)), "\(second)s")
        }
    }

    /// The whole point of the group gate: the stack steps through every lane
    /// once per period, in order, including across the wrap.
    ///
    /// Left flat this was 449 of 480 lanes for Spidey and 65 of 80 for the
    /// photo design, with the final frame held for a full second at each wrap.
    func testEveryLaneIsShownExactlyOnceAcrossThePeriod() {
        for (lanes, fps) in [(80, 16), (160, 16), (480, 32), (720, 24)] {
            let shown = (0 ..< lanes).map {
                FrameStackLayer.topLane(
                    atCycleSecond: Double($0) / Double(fps), lanes: lanes, framesPerSecond: fps
                )
            }
            XCTAssertEqual(
                shown, Array(0 ..< lanes),
                "\(lanes) lanes at \(fps)fps should walk the stack once, in order"
            )
        }
    }

    /// Said as the symptom rather than as the arithmetic, because the symptom
    /// is what gets reported: nothing is ever on screen for two steps running.
    func testTheLoopNeverStopsAtTheWrap() {
        let fps = 16
        let lanes = 80
        var previous: Int?
        for step in 0 ..< (lanes * 3) {
            let top = FrameStackLayer.topLane(
                atCycleSecond: Double(step) / Double(fps), lanes: lanes, framesPerSecond: fps
            )
            XCTAssertNotEqual(top, previous, "lane \(top) held for two steps at step \(step)")
            previous = top
        }
    }

    /// The last second of the stack is the part gated as a group, and at a
    /// two-second period that is the half the original engine has always split.
    func testTheGatedTailIsTheLastSecondOfThePeriod() {
        XCTAssertEqual(FrameStackLayer.tailStart(lanes: 80, framesPerSecond: 16), 64)
        XCTAssertEqual(FrameStackLayer.tailStart(lanes: 480, framesPerSecond: 32), 448)
        XCTAssertEqual(
            FrameStackLayer.tailStart(lanes: 64, framesPerSecond: 32), 32,
            "at a two-second period the tail is the second half, which is the original split"
        )
    }

    /// A stack short of the period is padded, and the padding goes first so the
    /// pause falls at the start of the cycle rather than in the middle of the
    /// last clip.
    func testThePauseIsAtTheFront() {
        let clip = Array(1 ... 600)                        // real frames, all non-zero
        let stack = FrameSetGenerator.paused(clip, lanes: lanes, blank: 0)
        XCTAssertEqual(stack.count, lanes)
        XCTAssertEqual(Array(stack.prefix(120)), Array(repeating: 0, count: 120))
        XCTAssertEqual(Array(stack.suffix(600)), clip, "the clips keep their order and their length")
    }

    /// A stack that already fills the period is handed back untouched - there
    /// is no pause to place, and prepending nothing must not shift the clips.
    func testAFullStackIsUnchanged() {
        let full = Array(0 ..< lanes)
        XCTAssertEqual(FrameSetGenerator.paused(full, lanes: lanes, blank: -1), full)
        XCTAssertEqual(FrameSetGenerator.paused(full, lanes: 100, blank: -1), full)
    }
}
