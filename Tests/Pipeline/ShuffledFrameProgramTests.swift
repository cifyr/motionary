import XCTest

/// How a delivered design plays more than one clip.
///
/// The font path shuffles whole clips across the thirty-second timer cycle. The
/// delivered path cannot: its loop *is* the mask's period, ten seconds at the
/// most, because that is the longest pattern the substitution table can carry.
/// So the clips share the cycle and each plays the opening of itself, and the
/// whole programme is one frame set rather than several selectable ones.
final class ShuffledFrameProgramTests: XCTestCase {
    /// The segments have to add up to the stack exactly. A lane nobody drew
    /// into is not a gap in the clip, it is a black flash once per loop.
    func testTheSegmentsCoverEveryLane() {
        for (lanes, clips) in [(320, 3), (320, 4), (120, 3), (64, 2), (60, 7), (100, 3)] {
            let shares = FrameSetGenerator.programShares(lanes: lanes, clips: clips)
            XCTAssertEqual(shares.count, clips)
            XCTAssertEqual(shares.reduce(0, +), lanes, "\(clips) clips over \(lanes) lanes")
            XCTAssertTrue(shares.allSatisfy { $0 > 0 }, "no clip may get nothing")
            // Even to within one lane: an uneven split would show as one clip
            // lingering, which reads as a stutter rather than as a choice.
            XCTAssertLessThanOrEqual((shares.max() ?? 0) - (shares.min() ?? 0), 1)
        }
    }

    /// Spidey Swing, which is the design this was built for: three clips over a
    /// ten-second stack at 32fps.
    func testThreeClipsSplitTheTenSecondLoop() {
        let shares = FrameSetGenerator.programShares(lanes: 320, clips: 3)
        XCTAssertEqual(shares, [107, 107, 106])
        for share in shares {
            let seconds = Double(share) / 32
            XCTAssertEqual(seconds, 3.33, accuracy: 0.02, "each clip gets about a third of ten seconds")
        }
    }

    /// Asking for more clips than there are lanes cannot produce a segment of
    /// nothing, and the caller falls back to building one clip.
    func testItRefusesToSplitAStackTooShortToShare() {
        XCTAssertTrue(FrameSetGenerator.programShares(lanes: 2, clips: 3).contains(0))
        XCTAssertEqual(FrameSetGenerator.programShares(lanes: 0, clips: 3), [])
        XCTAssertEqual(FrameSetGenerator.programShares(lanes: 320, clips: 0), [])
    }

    /// The order is drawn from the design's own id, so it is stable across
    /// rebuilds of the same design and different between designs - a shuffle
    /// that changed every build would make two runs impossible to compare.
    func testTheOrderIsFixedByTheDesignRatherThanTheRun() {
        let seed = UUID()
        let clips = FrameSetGenerator.programShares(lanes: 320, clips: 3).enumerated().map {
            ClipProgram.Clip(id: $0.offset == 0 ? nil : UUID(), frameCount: $0.element)
        }
        let first = ClipProgram.shuffled(clips: clips, totalFrames: 320, seed: seed)
        let again = ClipProgram.shuffled(clips: clips, totalFrames: 320, seed: seed)
        XCTAssertEqual(first?.map(\.clipID), again?.map(\.clipID))
        XCTAssertEqual(first?.count, 3, "every clip appears once")
        XCTAssertEqual(first?.reduce(0) { $0 + $1.frameCount }, 320)

        // And the segments run end to end, because the stack is drawn in lane
        // order and a segment starting anywhere else would overlap its
        // neighbour.
        var cursor = 0
        for segment in first ?? [] {
            XCTAssertEqual(segment.startFrame, cursor)
            cursor += segment.frameCount
        }
    }
}
