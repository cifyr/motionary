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
///   where the composition's own frame ends, because the system hands over
///   1645px of widget where the cut frame is 1632. The padded backdrop covers
///   those rows, so the correction can reach them;
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
///
/// The numbers come from `Resources/edge-profile.json`, which
/// `Tools/edge-calibrate.py` measures and writes: recalibrating is a measurement
/// and should not need a code edit. `shipped` below is the fallback.
enum EdgeCompensation {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "EdgeCompensation")

    /// The numbers as shipped, from three measure-adjust rounds against the
    /// Polaroid design at full resolution.
    ///
    /// Kept in source as well as in the file so that a missing or malformed
    /// `edge-profile.json` cannot ship a design with no correction: that failure
    /// looks exactly like the artefact this exists to remove, which is the worst
    /// way for it to fail.
    ///
    /// The two edges are not symmetric: the top's core is two rows, the bottom's
    /// three, and the bottom peaks one row below where the composition's own frame
    /// ends. Both fade into a tail of a few units over the next several rows.
    static let shipped = EdgeProfile(
        top: [
            (68, 70, 63),
            (54, 45, 47),
            (40, 32, 23),
            (14, 13, 10),
            (11, 10, 8),
            (11, 7, 6),
            (7, 7, 5),
            (6, 6, 4),
            (5, 5, 4),
        ],
        bottom: [
            (86, 75, 68),
            (64, 67, 68),
            (47, 39, 45),
            (19, 14, 17),
            (16, 12, 6),
            (11, 10, 5),
            (12, 7, 6),
            (9, 6, 5),
            (8, 5, 3),
        ],
        strength: 1.0,
        measuredAt: "2026-07-29"
    )

    /// What this build will subtract: the calibration file, or `shipped` if it
    /// cannot be read. Resolved once, because a per-row disk read would run
    /// millions of times over one backdrop.
    static let profile = EdgeProfileStore.load(
        deviceID: DeviceGeometry.model.id,
        fallback: shipped
    )

    /// Brightness the system adds, per channel, by distance in pixels inward from
    /// the edge.
    static var topAdded: [(r: Double, g: Double, b: Double)] { profile.top }
    static var bottomAdded: [(r: Double, g: Double, b: Double)] { profile.bottom }

    /// A scale on the whole profile. 1.0 applies what was measured; anything less
    /// deliberately under-corrects.
    ///
    /// What is left after it cannot be fixed from here. The system adds light, and
    /// light can only be taken out of content that has some: where a design's own
    /// top or bottom row is nearly black, the subtraction hits zero with the line
    /// still showing. On the Polaroid design that was three of nine columns across
    /// the top and five of nine across the bottom.
    static var strength: Double { profile.strength }

    /// The widget's real height in screen pixels. From the geometry table rather
    /// than a constant of its own: the bottom line lands on the last row the
    /// system hands over (1914), not on the last row of the cut frame (1901), and
    /// two copies of that height are two things to get out of step.
    static var renderedHeightPixels: Int { Int(DeviceGeometry.renderedWidgetRect.height) }

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
