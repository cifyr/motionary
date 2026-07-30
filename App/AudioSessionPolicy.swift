import AVFoundation
import os

/// What the app tells the process audio session before anything can play.
///
/// The preview loop is silent twice over - `PreviewVideoWriter` only ever adds a
/// video track, and the player is muted - and yet opening the app still stopped
/// whatever the phone was already playing. Muting was never the lever: an
/// `AVPlayer` activates the process's audio session when playback starts, and
/// the category it inherits is the app default, measured on the simulator as
/// `AVAudioSessionCategorySoloAmbient`. Solo-ambient is non-mixable, so
/// activating it takes the audio route off Spotify or a podcast regardless of
/// whether a single sample is ever produced.
enum AudioSessionPolicy {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "AudioSession")

    /// Ambient mixes with other apps instead of interrupting them, and stays
    /// silent under the Ring/Silent switch. Deliberately no `setActive(true)`:
    /// nothing here needs the session, and it is activation that seizes the
    /// route - the category only decides what activation costs everyone else.
    static func configureForSilentPlayback() {
        let session = AVAudioSession.sharedInstance()
        logger.info("audio session category was \(session.category.rawValue, privacy: .public)")
        do {
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            logger.info("audio session set to ambient, mixing with others")
        } catch {
            // Not fatal - the loop still plays, silently - but it means the app
            // is back to interrupting other audio, which is the entire bug, so
            // it has to be named rather than swallowed.
            logger.error("""
            could not set the ambient audio category, so playback may still \
            interrupt other audio: \(String(describing: error), privacy: .public)
            """)
        }
    }
}
