import CoreGraphics
import Foundation
import os

/// Cancels the bright line the Home Screen draws along the top and bottom of the
/// widget, by taking it out of the content first.
///
/// Measured from a screenshot of a real iPhone 17 Pro Home Screen, against the
/// design's own wallpaper as the reference, with the picture's own edges
/// subtracted out so only what the system added remains:
///
/// - a line at the widget's top row (screen row 270) about +60 brighter than the
///   picture, +40 one row in, then a tail of +13, +7, +3;
/// - the same at the bottom, at screen row 1913 - twelve rows below where the
///   composition's own frame ends, because the system hands over 548pt of widget
///   where the calibration says 544. The padded backdrop already covers it;
/// - nothing at all down the left and right edges, which is why the lines read as
///   top and bottom rather than as a border.
///
/// It adds rather than blends: the wallpaper behind the widget is the same
/// picture as the widget's own content there, so a blend would be invisible, and
/// this is not. That is what makes it invertible without knowing anything about
/// what is behind - subtract the same amount from the content and the sum comes
/// out at the picture.
///
/// The numbers came through a 0.76 downscale, so they are a floor rather than an
/// exact profile, and `strength` holds the correction below 1 deliberately:
/// under-correcting leaves a fainter bright line, over-correcting leaves a dark
/// one, and a dark line is a new artefact rather than a smaller old one. Run the
/// edge lab on the phone to replace these with an exact per-channel fit.
enum EdgeCompensation {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "EdgeCompensation")

    /// Brightness the system adds, per channel, by distance in pixels inward from
    /// the edge. Re-measured from a full-resolution screenshot after a first
    /// correction was already in place, by adding back what had been subtracted -
    /// which is why these are larger than the first pass through a downscale
    /// suggested, and why the two edges no longer share one profile.
    ///
    /// The two edges are not symmetric: the top's core is two rows, the bottom's
    /// three, and the bottom peaks one row below where the composition's own frame
    /// ends. Both fade into a tail of a few units over the next several rows.
    static let topAdded: [(r: Double, g: Double, b: Double)] = [
        (76, 71, 56),
        (60, 46, 42),
        (33, 30, 26),
        (12, 13, 11),
        (7, 9, 9),
        (8, 7, 6),
        (6, 6, 5),
        (5, 5, 4),
        (4, 4, 4),
    ]

    static let bottomAdded: [(r: Double, g: Double, b: Double)] = [
        (70, 58, 44),
        (60, 62, 56),
        (43, 34, 40),
        (16, 13, 17),
        (14, 11, 11),
        (8, 9, 8),
        (10, 7, 6),
        (8, 6, 5),
        (7, 5, 4),
    ]

    /// Full correction now that the profile was measured at full resolution
    /// rather than estimated through a 0.76 downscale.
    ///
    /// It still cannot cancel exactly. Measured across two different halves of
    /// the width, the same row differs by around eight units - so part of what
    /// the system adds depends on the content near the edge rather than being a
    /// fixed line. A single profile takes out the fixed part and leaves that.
    static let strength: Double = 1.0

    /// The widget's real height in screen pixels, from where the bottom line
    /// lands: row 1914, twelve past the 1901 the composition's frame ends at.
    static let renderedHeightPixels = 1645

    static func topEdgeRow(widgetRect: CGRect) -> Int { Int(widgetRect.minY) }

    static func bottomEdgeRow(widgetRect: CGRect) -> Int {
        Int(widgetRect.minY) + renderedHeightPixels - 1
    }

    /// Rows the correction touches, as screen pixels.
    static func bands(widgetRect: CGRect) -> [ClosedRange<Int>] {
        let top = topEdgeRow(widgetRect: widgetRect)
        let bottom = bottomEdgeRow(widgetRect: widgetRect)
        return [
            top ... (top + topAdded.count - 1),
            (bottom - bottomAdded.count + 1) ... bottom,
        ]
    }

    /// Whether a region includes rows the correction has to reach.
    ///
    /// The animated frames are encoded from their own crop, so if that crop
    /// reaches an edge band those rows carry the line and this cannot take it
    /// out of the backdrop alone.
    static func overlaps(_ rect: CGRect, widgetRect: CGRect) -> Bool {
        let rows = Int(rect.minY) ... Int(rect.maxY - 1)
        return bands(widgetRect: widgetRect).contains { $0.overlaps(rows) }
    }

    /// The correction for one screen row, or nil where the system adds nothing.
    static func correction(screenRow: Int, widgetRect: CGRect) -> (r: Double, g: Double, b: Double)? {
        let fromTop = screenRow - topEdgeRow(widgetRect: widgetRect)
        let fromBottom = bottomEdgeRow(widgetRect: widgetRect) - screenRow
        let value: (r: Double, g: Double, b: Double)
        if fromTop >= 0, fromTop < topAdded.count {
            value = topAdded[fromTop]
        } else if fromBottom >= 0, fromBottom < bottomAdded.count {
            value = bottomAdded[fromBottom]
        } else {
            return nil
        }
        return (value.r * strength, value.g * strength, value.b * strength)
    }

    /// Subtracts the line from an image that covers screen rows starting at
    /// `originY`.
    ///
    /// Applied to the widget's backdrop, not to the wallpaper: outside the widget
    /// the system draws no line, so taking one out there would leave a dark band
    /// down the picture the wallpaper is supposed to match.
    static func applied(to image: CGImage, originY: Int, widgetRect: CGRect) -> CGImage {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        let drew = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else {
            logger.error("could not read the backdrop back; it ships with the edge line in it")
            return image
        }

        var corrected = 0
        for row in 0 ..< height {
            guard let correction = correction(screenRow: originY + row, widgetRect: widgetRect) else { continue }
            corrected += 1
            let start = row * bytesPerRow
            for column in 0 ..< width {
                let index = start + column * 4
                pixels[index] = subtract(pixels[index], correction.r)
                pixels[index + 1] = subtract(pixels[index + 1], correction.g)
                pixels[index + 2] = subtract(pixels[index + 2], correction.b)
            }
        }
        guard corrected > 0 else { return image }

        let made: CGImage? = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return nil }
            return context.makeImage()
        }
        guard let made else {
            logger.error("corrected backdrop could not be rebuilt; shipping it uncorrected")
            return image
        }
        logger.info("took the edge line out of \(corrected) rows of the backdrop")
        return made
    }

    /// Clamped at black: where the content is already darker than the line the
    /// system adds, the sum cannot be brought all the way down and a trace of it
    /// stays. Nothing can be subtracted past zero.
    private static func subtract(_ value: UInt8, _ amount: Double) -> UInt8 {
        UInt8(max(0, min(255, Double(value) - amount)))
    }
}
