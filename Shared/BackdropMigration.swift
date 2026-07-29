import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
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
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            logger.error("could not decode \(url.lastPathComponent, privacy: .public) at \(maxPixelSize)px")
            return nil
        }
        return image
    }
}

/// Backfills the widget-sized backdrop for designs built before it existed.
///
/// Without it those designs make the widget decode a full-screen image, and a
/// rebuild is a slow thing to demand for a crop that takes milliseconds.
enum BackdropMigration {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "Migration")

    @discardableResult
    static func run(store: DesignStore, designs: [DesignDocument]) -> Int {
        var created = 0
        for design in designs {
            let backdrop = store.widgetBackdropURL(for: design.id)
            guard !FileManager.default.fileExists(atPath: backdrop.path) else { continue }

            let wallpaper = store.wallpaperURL(for: design.id)
            guard FileManager.default.fileExists(atPath: wallpaper.path) else { continue }

            // Decode at full size here: the app has the headroom the extension
            // does not, and the point is to spare the extension.
            guard let source = CGImageSourceCreateWithURL(wallpaper as CFURL, nil),
                  let full = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                logger.error("could not read wallpaper for \(design.id.uuidString, privacy: .public)")
                continue
            }

            let rect = design.widgetRect.integral
            let bounds = CGRect(x: 0, y: 0, width: full.width, height: full.height)
            let cropRect = rect.intersection(bounds)
            guard !cropRect.isNull, cropRect.width >= 2, cropRect.height >= 2,
                  let cropped = full.cropping(to: cropRect),
                  let data = FrameEncoder.jpegData(cropped, quality: 0.9)
            else { continue }

            do {
                try data.write(to: backdrop, options: .atomic)
                created += 1
                logger.info("backfilled backdrop for \(design.id.uuidString, privacy: .public), \(data.count) bytes")
            } catch {
                logger.error("could not write backdrop: \(String(describing: error), privacy: .public)")
            }
        }
        return created
    }
}
