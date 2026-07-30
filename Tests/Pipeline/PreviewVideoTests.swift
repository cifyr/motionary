import AVFoundation
import CoreGraphics
import XCTest

/// The in-app loop is meant to be silent. Muting the player is one layer; the
/// other is that the file it plays has nothing to mute, and that only holds while
/// the preview is written frame by frame. Anyone who swaps this for an export of
/// the source clip brings its soundtrack along, so the absence of an audio track
/// is asserted rather than assumed.
final class PreviewVideoTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("motionary-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testWrittenPreviewHasVideoAndNoAudioTrack() async throws {
        let url = directory.appendingPathComponent("preview.mp4")
        let size = CGSize(width: 64, height: 48)
        let frames = try [0.1, 0.5, 0.9].map { try frame(grey: $0, size: size) }

        try await PreviewVideoWriter(size: size, framesPerSecond: 15).write(frames: frames, to: url)

        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(video.count, 1, "the preview stopped carrying picture, so this test proves nothing")
        XCTAssertTrue(audio.isEmpty, "an audio track in the preview is audible in the app no matter how the player is set up")
    }

    private func frame(grey: Double, size: CGSize) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: grey, green: grey, blue: grey, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        return try XCTUnwrap(context.makeImage())
    }
}
