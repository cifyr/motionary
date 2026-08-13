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

    /// Spidey Swing, which is the design this was built for: clips of 10.6, 8.0
    /// and 8.0 seconds over a thirty-second stack at 10fps.
    ///
    /// Split evenly they would get ten seconds each and the long one would be
    /// cut - which is exactly what the first version did, and what it was
    /// reported for. In proportion, every clip plays all the way through.
    func testEachClipGetsRoomForTheWholeOfItself() {
        let lengths = [10.6, 8.0, 8.0]
        let shares = FrameSetGenerator.programShares(lanes: 300, weights: lengths)
        XCTAssertEqual(shares, [120, 90, 90])
        XCTAssertEqual(shares.reduce(0, +), 300)

        // Every clip is stretched by the same factor, so nothing plays at a
        // different speed from anything else - the stretch is what takes 26.6
        // seconds of clip to a thirty-second loop with no gap at the end.
        let stretch = zip(shares, lengths).map { Double($0) / 10 / $1 }
        for factor in stretch {
            XCTAssertEqual(factor, stretch[0], accuracy: 0.02)
            XCTAssertEqual(factor, 30.0 / 26.6, accuracy: 0.02)
        }
    }

    /// Proportion must not starve a short clip: one lane is a frame, and zero
    /// is a hole in the stack.
    func testAVeryShortClipStillGetsALane() {
        let shares = FrameSetGenerator.programShares(lanes: 300, weights: [29.0, 0.5, 0.5])
        XCTAssertEqual(shares.reduce(0, +), 300)
        XCTAssertTrue(shares.allSatisfy { $0 > 0 })
    }

    /// Weights that say nothing fall back to an even split rather than to a
    /// stack of empty segments.
    func testUnmeasurableClipsSplitEvenly() {
        XCTAssertEqual(FrameSetGenerator.programShares(lanes: 300, weights: [0, 0, 0]).reduce(0, +), 300)
        XCTAssertEqual(FrameSetGenerator.programShares(lanes: 0, weights: [1, 2]), [])
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
