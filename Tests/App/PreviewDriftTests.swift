import AVFoundation
import XCTest

/// The widget's animation is a pure function of wall-clock time; the app plays
/// the same loop as a video, and video playback is not held to real time. So the
/// app measures how far it has slipped and pulls itself back. Measured on this
/// machine, a 0.31s clip loses 7ms per second under `AVPlayerLooper` against
/// 0.3ms for a 6s one - which is the two running at visibly different speeds
/// once the difference has had a minute to add up.
final class PreviewDriftTests: XCTestCase {
    private func drift(playhead: TimeInterval, expected: TimeInterval, loop: TimeInterval) -> TimeInterval {
        LoopingVideoView.PlayerView.drift(playhead: playhead, expected: expected, loopDuration: loop)
    }

    func testInStepIsNoDrift() {
        XCTAssertEqual(drift(playhead: 0.25, expected: 0.25, loop: 1), 0, accuracy: 1e-9)
    }

    func testBehindReadsNegative() {
        XCTAssertEqual(drift(playhead: 0.2, expected: 0.3, loop: 1), -0.1, accuracy: 1e-9)
    }

    func testAheadReadsPositive() {
        XCTAssertEqual(drift(playhead: 0.4, expected: 0.3, loop: 1), 0.1, accuracy: 1e-9)
    }

    /// The measurement has to be the shorter way round the loop. Without that,
    /// a picture 10ms past the wrap reads as a whole loop behind and the player
    /// seeks backwards on every single check.
    func testTheWrapIsTheShortWayRound() {
        XCTAssertEqual(drift(playhead: 0.01, expected: 0.99, loop: 1), 0.02, accuracy: 1e-9)
        XCTAssertEqual(drift(playhead: 0.99, expected: 0.01, loop: 1), -0.02, accuracy: 1e-9)
    }

    /// The player's clock runs over the whole repeated composition, not one
    /// pass of it, so the phase is what its time means modulo the loop.
    func testALaterPassMeasuresTheSameAsTheFirst() {
        XCTAssertEqual(drift(playhead: 12.4, expected: 0.4, loop: 2), 0, accuracy: 1e-9)
        XCTAssertEqual(drift(playhead: 12.5, expected: 0.4, loop: 2), 0.1, accuracy: 1e-9)
    }

    func testDriftIsNeverMoreThanHalfALoop() {
        for playhead in stride(from: 0.0, to: 3.0, by: 0.017) {
            XCTAssertLessThanOrEqual(abs(drift(playhead: playhead, expected: 0.4, loop: 0.5)), 0.25 + 1e-9)
        }
    }

    /// Nothing to measure against, so nothing is claimed - a nonzero answer
    /// here would make the player seek on every check of a clip it cannot time.
    func testAZeroLengthLoopHasNoDrift() {
        XCTAssertEqual(drift(playhead: 3, expected: 1, loop: 0), 0)
    }
}
