import CoreGraphics
import Foundation
import ImageIO
import os

/// Loads images without decoding more pixels than are needed.
///
/// `UIImage(contentsOfFile:)` decodes at full size: a 1206x2622 wallpaper costs
/// about 12.6MB uncompressed, which a widget extension holding tens of
/// megabytes of fonts may not have. A thumbnail decode caps that, and returning
/// nil quietly is what produced a black widget with no explanation.
enum ImageLoader {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "ImageLoader")

    static func load(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            logger.error("no image source for \(url.lastPathComponent, privacy: .public)")
            return nil
        }
        return thumbnail(from: source, maxPixelSize: maxPixelSize, describing: url.lastPathComponent)
    }

    /// The same capped decode for bytes already in hand, which is how a frame
    /// is shrunk on its way into a delivery.
    static func load(data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            logger.error("no image source for \(data.count) bytes")
            return nil
        }
        return thumbnail(from: source, maxPixelSize: maxPixelSize, describing: "\(data.count) bytes")
    }

    private static func thumbnail(
        from source: CGImageSource,
        maxPixelSize: Int,
        describing subject: String
    ) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            logger.error("could not decode \(subject, privacy: .public) at \(maxPixelSize)px")
            return nil
        }
        return image
    }
}
