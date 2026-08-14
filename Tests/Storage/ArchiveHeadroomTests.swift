import XCTest

/// There are two numbers, not one. `byteBudget` is what a build aims at;
/// `archiveLimit` is where the widget stops being drawn. Everything between
/// them used to ship without a word, which is how a twenty-second loop measured
/// 8.9MB against a 9.4MB black screen and reported nothing at all.
final class ArchiveHeadroomTests: XCTestCase {
    private func weight(_ bytes: Int) -> DesignPackage.ClipWeight {
        DesignPackage.ClipWeight(clip: "primary", frames: bytes, companions: 0)
    }

    func testAComfortableArchiveIsQuiet() {
        let clip = weight(FramePayloadPlan.byteBudget - 1)
        XCTAssertEqual(clip.headroom, .comfortable)
        XCTAssertTrue(clip.fits)
        XCTAssertFalse(clip.summary.contains("LIMIT"))
    }

    func testTheGapBetweenTheTwoNumbersIsCalledOut() {
        let clip = weight(FramePayloadPlan.byteBudget + 1)
        XCTAssertEqual(clip.headroom, .tight)
        XCTAssertTrue(clip.fits, "it still ships - that is the point of saying so")
        XCTAssertTrue(clip.summary.contains("CLOSE TO THE ARCHIVE LIMIT"))
    }

    func testTheMeasuredTwentySecondLoopLandsInThatGap() {
        // 8.9MB per archive, measured on a 20s loop and confirmed drawing on a
        // phone. Four per cent under the size that has been photographed black.
        let clip = weight(Int(8.9 * 1_048_576))
        XCTAssertEqual(clip.headroom, .tight)
    }

    func testOverTheLimitStillReadsAsOver() {
        let clip = weight(FramePayloadPlan.archiveLimit + 1)
        XCTAssertEqual(clip.headroom, .over)
        XCTAssertFalse(clip.fits)
        XCTAssertTrue(clip.summary.contains("OVER THE ARCHIVE LIMIT"))
    }
}
