import CoreGraphics
import Foundation
import os

/// Where a correction would go if the widget's colour ever needed one.
///
/// It does not. The wallpaper pipeline and the widget renderer were long
/// believed to disagree - "warmer inside", answered by a gain of
/// (0.984, 1.035, 1.096) - and that was measured by comparing strips either
/// side of the widget's edge. Both readings taken that way were contaminated:
/// the inside strip catches the drop shadows of the icon rows, which the
/// outside strip has none of, and on a design whose animated crop reaches the
/// left edge it also lands on content drawn from the glyph JPEGs rather than
/// from the backdrop. Sampling only between icon rows, and only on the side
/// clear of the crop, removes both.
///
/// Done that way across two screenshots of the same design taken under very
/// different gains, the residual came back as almost exactly the gain that had
/// been applied: (0.986, 1.029, 1.095) under the old one and
/// (1.024, 1.037, 1.039) under a later (1.026, 1.032, 1.029). Each therefore
/// asks for a gain of 1 - (0.998, 1.006, 1.001) and (1.002, 0.995, 0.990). A
/// correction that reproduces itself in the residual is the whole error, and
/// the uncorrected paths already agree.
///
/// Measured on a near-neutral grey over levels 60 to 108. The old figure came
/// off wood, shadow and a bright Polaroid border, so a difference that only
/// appears on saturated or bright content would not show here - if one is ever
/// measured cleanly, this is where it goes.
enum WidgetTint {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "WidgetTint")

    /// What to multiply the widget's content by. Identity, because nothing was
    /// found to correct - kept as a gain rather than deleted so a difference
    /// measured cleanly on some future design has somewhere to go.
    static let gain = (r: 1.0, g: 1.0, b: 1.0)

    /// Clamped rather than gamut-mapped, for when the gain is not identity: a
    /// highlight that clipped in one channel only would come out tinted.
    static func applied(to image: CGImage) -> CGImage {
        // Every frame of every build goes through here, so an identity gain
        // skips the round trip rather than paying for a copy that changes
        // nothing.
        guard gain != (r: 1, g: 1, b: 1) else { return image }
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
