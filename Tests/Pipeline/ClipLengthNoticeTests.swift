import XCTest

/// Two ceilings cut a clip - the loop sizing at import and the generator's
/// seconds budget - and neither used to say anything. A 45-second clip was
/// delivered as its first ten seconds under a summary line that read exactly
/// like a clip which fitted.
final class ClipLengthNoticeTests: XCTestCase {
    private func design(sourceSeconds: TimeInterval, loopFrames: Int, speed: Double = 1) -> DesignDocument {
        var document = DesignDocument.new(name: "Test", sourceVideoName: "source.mov")
        document.sourceDuration = sourceSeconds
        document.loopFrameCount = loopFrames
        document.playbackSpeed = speed
        return document
    }

    func testAClipThatFitsSaysNothing() {
        // 2s of source against a 2s loop at 32fps.
        let notice = FrameSetGenerator.lengthNotice(for: design(sourceSeconds: 2, loopFrames: 64))
        XCTAssertNil(notice)
    }

    func testALongClipSaysHowMuchIsLost() throws {
        let notice = try XCTUnwrap(
            FrameSetGenerator.lengthNotice(for: design(sourceSeconds: 45, loopFrames: 1440))
        )
        XCTAssertEqual(notice.sourceSeconds, 45)
        XCTAssertEqual(
            notice.builtSeconds,
            FrameSetGenerator.loopSecondsBudget,
            accuracy: 0.01,
            "the generator's budget is the ceiling that bites"
        )
        XCTAssertEqual(notice.lostSeconds, 35, accuracy: 0.01)
        XCTAssertTrue(notice.text.contains("45.0s"))
        XCTAssertTrue(notice.text.contains("not built"))
    }

    func testSpeedingUpFitsMoreOfTheClip() throws {
        // The same source, played at three times the speed, covers three times
        // as much of itself per second of loop.
        let slow = try XCTUnwrap(
            FrameSetGenerator.lengthNotice(for: design(sourceSeconds: 45, loopFrames: 1440))
        )
        let fast = try XCTUnwrap(
            FrameSetGenerator.lengthNotice(for: design(sourceSeconds: 45, loopFrames: 1440, speed: 3))
        )
        XCTAssertGreaterThan(fast.builtSeconds, slow.builtSeconds)
        XCTAssertLessThan(fast.lostSeconds, slow.lostSeconds)
    }

    func testAClipFastEnoughToFitSaysNothing() {
        // 30s at 3x is ten seconds of loop, which is the whole clip.
        XCTAssertNil(
            FrameSetGenerator.lengthNotice(for: design(sourceSeconds: 30, loopFrames: 960, speed: 3))
        )
    }

    func testAnUnmeasuredSourceSaysNothing() {
        // Before the extractor has reported, every number here is zero and a
        // notice built from that would say the clip loses all of itself.
        XCTAssertNil(FrameSetGenerator.lengthNotice(for: design(sourceSeconds: 0, loopFrames: 320)))
        XCTAssertNil(
            FrameSetGenerator.lengthNotice(for: design(sourceSeconds: 45, loopFrames: 320, speed: 0))
        )
    }
}

/// Speeding a clip up shortens what the source can supply. The extractor
/// refuses rather than short-changes, so the loop has to be sized against it.
final class AffordableLoopTests: XCTestCase {
    private let spec = TimerFontSpec(laneCount: 32, framesPerSecond: 16)

    func testAnOrdinaryClipAffordsItsWholeLoop() {
        // 5s at 16fps is 80 frames, which is what the design asks for.
        XCTAssertEqual(
            FrameSetGenerator.affordableLoopFrames(duration: 5, spec: spec, playbackSpeed: 1),
            80
        )
    }

    func testSpeedingUpShortensWhatTheSourceHolds() {
        // The case that failed the whole build: 60s at 10x is six seconds of
        // material, and the loop was asking for ten.
        XCTAssertEqual(
            FrameSetGenerator.affordableLoopFrames(duration: 60, spec: spec, playbackSpeed: 10),
            96
        )
    }

    func testSlowingDownAffordsMore() {
        XCTAssertEqual(
            FrameSetGenerator.affordableLoopFrames(duration: 60, spec: spec, playbackSpeed: 0.5),
            1920
        )
    }

    func testAnUnmeasuredSourceCapsNothing() {
        // Before the extractor reports, the document's duration is zero, and
        // clamping the loop to one frame on that would be worse than the bug.
        XCTAssertEqual(
            FrameSetGenerator.affordableLoopFrames(duration: 0, spec: spec, playbackSpeed: 1),
            .max
        )
    }

    func testAClipTooShortToFillOneFrameStillGetsOne() {
        XCTAssertEqual(
            FrameSetGenerator.affordableLoopFrames(duration: 0.01, spec: spec, playbackSpeed: 1),
            1
        )
    }
}
