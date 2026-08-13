import SwiftUI
import UIKit
import os

/// Reads the frames of a picture-built design for the widget to stack.
///
/// Deliberately `UIImage(data:)` over a mapped file, and deliberately not
/// `ImageLoader`: `UIImage` does not decode until something draws it, and what
/// draws these is the render server rather than the extension. That is the
/// whole reason 64 frames at full size cost the extension 12MB instead of the
/// 150 the arithmetic predicts, and it is the measurement the engine is built
/// on - see `docs/widget-animation-surface.md` 4.1.1. Anything here that
/// decodes eagerly, a thumbnail API included, spends the extension's entire
/// budget before the first frame is drawn.
enum FrameSetLoader {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "FrameSet")

    struct Report: Sendable {
        let requested: Int
        let loaded: Int
        let bytes: Int
        let missing: [Int]
        /// How many lanes each loaded frame covers. Above one, the set on disk
        /// was too big for one archive and has been thinned.
        var stride = 1

        var isComplete: Bool { loaded == requested && requested > 0 }
        /// A gap in the stack is a lane with nothing in it, which plays as a
        /// black flash once per loop rather than as an error.
        var summary: String {
            "\(loaded)/\(requested) frames, \(bytes / 1024)KB"
                + (stride > 1 ? ", 1 in \(stride) to fit the archive" : "")
                + (missing.isEmpty ? "" : ", missing \(missing.prefix(4).map(String.init).joined(separator: ","))")
        }
    }

    /// Reads the frames, skipping some when the whole set will not fit.
    ///
    /// Over the archive limit nothing is drawn at all - not a partial picture,
    /// not an error, a black widget with `ok` written beside it. A build now
    /// shrinks its frames to stay under, but a design delivered before that
    /// change is already sitting on the phone at whatever it was packed at, and
    /// the extension cannot re-encode it. Dropping lanes is what it can do:
    /// each remaining frame is held longer, so the clip keeps its length and
    /// its speed and loses smoothness.
    static func load(
        designID: UUID,
        count: Int,
        store: DesignStore,
        variant: UUID? = nil,
        limit: Int = FramePayloadPlan.archiveLimit
    ) -> (frames: [Image], report: Report) {
        let urls = (0 ..< count).map { store.frameURL(for: designID, index: $0, variant: variant) }
        // Sized from the file table rather than by reading them: the point is
        // to avoid holding a set this big, so measuring it by loading it would
        // be the same mistake one step earlier.
        let onDisk = urls.reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let stride = FramePayloadPlan.laneStride(forBytes: onDisk, limit: limit)

        var images: [Image] = []
        var missing: [Int] = []
        var bytes = 0
        for index in Swift.stride(from: 0, to: count, by: stride) {
            guard let data = try? Data(contentsOf: urls[index], options: .mappedIfSafe),
                  let image = UIImage(data: data)
            else {
                missing.append(index)
                continue
            }
            bytes += data.count
            images.append(Image(uiImage: image))
        }
        let wanted = Array(Swift.stride(from: 0, to: count, by: stride)).count
        let report = Report(
            requested: wanted, loaded: images.count, bytes: bytes, missing: missing, stride: stride
        )
        if stride > 1 {
            logger.warning("""
            \(count) frames come to \(onDisk / 1024)KB on disk, over the archive limit; \
            drawing 1 lane in \(stride). Send the design again to get the rest back.
            """)
        }
        if report.isComplete {
            logger.info("loaded \(report.summary, privacy: .public)")
        } else {
            logger.error("incomplete frame set: \(report.summary, privacy: .public)")
        }
        return (images, report)
    }
}
