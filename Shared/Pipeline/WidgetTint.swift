import CoreGraphics
import Foundation
import os

/// Matches the widget's colour to the wallpaper around it.
///
/// The same picture reads warmer inside the widget than outside it. Measured
/// across both side boundaries of a real Home Screen - where the picture is
/// continuous and, unlike the top and bottom, no rim line is drawn, so strips a
/// few pixels either side of the edge are directly comparable - the widget's
/// content came back about 1% up in red, 3% down in green and 7% down in blue.
/// Consistent at five separate places down each side, on wood, on shadow and on
/// the bright Polaroid border.
///
/// It is not the files: both the wallpaper and the backdrop are written from the
/// same composed frame, both untagged, and both read as sRGB. The difference is
/// in the two display paths - the Home Screen's wallpaper pipeline and the widget
/// renderer - so the fix is the same trick as the edge line: apply the inverse to
/// what the widget draws, and the two agree on screen.
enum WidgetTint {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "WidgetTint")

    /// What to multiply the widget's content by. The inverse of the measured
    /// difference, so the display path lands back on the wallpaper's colour.
    ///
    /// Refined once against a screenshot taken with the first gain in place,
    /// which cut the difference from (+1.6, -3.5, -7.1) to (+0.8, -0.6, -1.4);
    /// this folds in the rest. What is left after that varies by a few units
    /// down the height of the widget rather than being a single offset, so it is
    /// the average that goes to zero, not every row.
    static let gain = (r: 0.984, g: 1.035, b: 1.096)

    /// Clamped rather than gamut-mapped. On the design measured, 2.4% of the
    /// widget's pixels would exceed 255 in some channel, all of them already at
    /// or near 255 before the gain - highlights that stay white either way.
    static func applied(to image: CGImage) -> CGImage {
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
            logger.error("could not read a \(width)x\(height) frame back; it ships untinted")
            return image
        }

        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = scale(pixels[index], gain.r)
            pixels[index + 1] = scale(pixels[index + 1], gain.g)
            pixels[index + 2] = scale(pixels[index + 2], gain.b)
        }

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
            logger.error("tinted frame could not be rebuilt; shipping it untinted")
            return image
        }
        return made
    }

    private static func scale(_ value: UInt8, _ factor: Double) -> UInt8 {
        UInt8(max(0, min(255, (Double(value) * factor).rounded())))
    }
}
