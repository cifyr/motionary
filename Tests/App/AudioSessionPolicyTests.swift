import AVFoundation
import XCTest

/// Whether the app steals the audio route is not visible in a screenshot and not
/// audible in a test, so what is asserted is the one thing that decides it: the
/// category the session is left in before any player exists.
///
/// Measured on the simulator, an untouched session reports
/// `AVAudioSessionCategorySoloAmbient` with no options - non-mixable, so
/// activating it silences other apps. These tests start from that state
/// explicitly rather than relying on it, because any earlier test in the process
/// could have moved it.
final class AudioSessionPolicyTests: XCTestCase {
    private let session = AVAudioSession.sharedInstance()

    func testReplacesTheNonMixableDefaultWithAmbient() throws {
        try session.setCategory(.soloAmbient)
        XCTAssertEqual(session.category, .soloAmbient)

        AudioSessionPolicy.configureForSilentPlayback()

        XCTAssertEqual(session.category, .ambient)
        XCTAssertTrue(
            session.categoryOptions.contains(.mixWithOthers),
            "without mixWithOthers, opening the app takes the route off whatever was playing"
        )
    }

    /// A category that interrupts is exactly what the fix removes, so setting one
    /// and configuring again has to undo it - the app configures once per launch
    /// and cannot assume where the session has been.
    func testOverridesAnInterruptingCategory() throws {
        try session.setCategory(.playback, mode: .default, options: [])
        XCTAssertFalse(session.categoryOptions.contains(.mixWithOthers))

        AudioSessionPolicy.configureForSilentPlayback()

        XCTAssertEqual(session.category, .ambient)
        XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers))
    }
}
