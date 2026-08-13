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

        var isComplete: Bool { loaded == requested && requested > 0 }
        /// A gap in the stack is a lane with nothing in it, which plays as a
        /// black flash once per loop rather than as an error.
        var summary: String {
            "\(loaded)/\(requested) frames, \(bytes / 1024)KB"
                + (missing.isEmpty ? "" : ", missing \(missing.prefix(4).map(String.init).joined(separator: ","))")
        }
    }

    static func load(designID: UUID, count: Int, store: DesignStore) -> (frames: [Image], report: Report) {
        var images: [Image] = []
        var missing: [Int] = []
        var bytes = 0
        for index in 0 ..< count {
            let url = store.frameURL(for: designID, index: index)
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let image = UIImage(data: data)
            else {
                missing.append(index)
                continue
            }
            bytes += data.count
            images.append(Image(uiImage: image))
        }
        let report = Report(requested: count, loaded: images.count, bytes: bytes, missing: missing)
        if report.isComplete {
            logger.info("loaded \(report.summary, privacy: .public)")
        } else {
            logger.error("incomplete frame set: \(report.summary, privacy: .public)")
        }
        return (images, report)
    }
}
