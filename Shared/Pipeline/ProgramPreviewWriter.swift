import AVFoundation
import Foundation

/// Joins the already-built preview clips without decoding or re-encoding.
struct ProgramPreviewWriter {
    let framesPerSecond: Int

    func write(
        segments: [ClipProgram.Segment],
        source: (UUID?) -> URL,
        to destination: URL
    ) async throws {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw PreviewVideoError.noFrames }
        var cursor = CMTime.zero
        for segment in segments {
            let asset = AVURLAsset(url: source(segment.clipID))
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .video).first else {
                throw PreviewVideoError.noFrames
            }
            let duration = CMTime(value: CMTimeValue(segment.frameCount), timescale: CMTimeScale(framesPerSecond))
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceTrack, at: cursor)
            cursor = cursor + duration
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw PreviewVideoError.noFrames
        }
        try await exporter.export(to: destination, as: .mp4)
    }
}
