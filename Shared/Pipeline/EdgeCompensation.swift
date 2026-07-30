import CoreGraphics
import Foundation
import os

/// Cancels the bright line the Home Screen draws along the top and bottom of the
/// widget, by taking it out of the content first.
///
/// Measured from full-resolution screenshots of a real iPhone 17 Pro Home
/// Screen, against the design's own wallpaper as the reference, with the
/// picture's own edges subtracted out so only what the system added remains, and
/// then refined against a second screenshot taken with the first correction
/// already in place:
///
/// - a line on the widget's top row, screen row 270;
/// - a stronger one on its bottom row, screen row 1914 - thirteen rows below
///   where the composition's own frame ends, because the system hands over 548pt
///   of widget where the calibration says 544. The padded backdrop covers those
///   rows, so the correction can reach them;
/// - nothing down the left and right edges, which is why the lines read as top
///   and bottom rather than as a border. A useful check on the method, too: the
///   Polaroid edges in the picture itself cancelled to within two units while
///   these stood at sixty and more.
///
/// It adds rather than blends: the wallpaper behind the widget is the same
/// picture as the widget's own content there, so a blend would cancel itself and
/// be invisible, and this is not. That is what makes it invertible without
/// knowing anything about what is behind - subtract the same amount from the
/// content and the sum comes out at the picture.
///
/// Where the content has room to be darkened this now lands within about two
/// units. Where it does not, nothing here can help: the system adds light, and
/// light can only be removed from content that has some, so a design whose own
/// top or bottom row is nearly black keeps its line. The fix for that one is in
/// the design, not in the pipeline - move the clip or the background so the
/// widget's outermost rows are not the darkest part of the picture.
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
        (71, 71, 64),
        (57, 46, 47),
        (39, 32, 27),
        (14, 14, 12),
        (10, 11, 10),
        (10, 8, 8),
        (7, 7, 7),
        (6, 6, 6),
        (5, 5, 5),
    ]

    static let bottomAdded: [(r: Double, g: Double, b: Double)] = [
        (79, 68, 59),
        (63, 66, 65),
        (46, 38, 45),
        (18, 14, 18),
        (16, 12, 9),
        (10, 10, 7),
        (12, 7, 6),
        (9, 6, 5),
        (8, 5, 3),
    ]

    /// Full correction now that the profile was measured at full resolution
    /// rather than estimated through a 0.76 downscale.
    ///
    /// Refined once more against a screenshot taken with the previous profile in
    /// place: where the content had room to be darkened, the line came back
    /// within about two units of the picture, and those small remainders are
    /// folded in here.
    ///
    /// What is left cannot be fixed from here. The system adds light, and light
    /// can only be taken out of content that has some: where a design's own top
    /// or bottom row is nearly black, the subtraction hits zero with the line
    /// still showing. On the design measured, three of nine columns across the
    /// top and five of nine across the bottom were in that state.
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
        var ranOut = 0
        var total = 0
        for row in 0 ..< height {
            guard let correction = correction(screenRow: originY + row, widgetRect: widgetRect) else { continue }
            corrected += 1
            let start = row * bytesPerRow
            for column in 0 ..< width {
                let index = start + column * 4
                total += 1
                // Counted, not worked around: this is where the line survives,
                // and it is worth knowing how much of an edge is in that state
                // rather than wondering why a design still shows one.
                if Double(pixels[index]) < correction.r
                    || Double(pixels[index + 1]) < correction.g
                    || Double(pixels[index + 2]) < correction.b {
                    ranOut += 1
                }
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
        let share = total > 0 ? ranOut * 100 / total : 0
        logger.info("""
        took the edge line out of \(corrected) rows of the backdrop; \
        \(share)% of those pixels were too dark to take all of it \
        (the line still shows there)
        """)
        if share > 25 {
            logger.warning("""
            more than a quarter of the widget's edge is too dark to correct; \
            move the clip or the background so its outermost rows are brighter
            """)
        }
        return made
    }

    /// Clamped at black: where the content is already darker than the line the
    /// system adds, the sum cannot be brought all the way down and a trace of it
    /// stays. Nothing can be subtracted past zero.
    private static func subtract(_ value: UInt8, _ amount: Double) -> UInt8 {
        UInt8(max(0, min(255, Double(value) - amount)))
    }
}
