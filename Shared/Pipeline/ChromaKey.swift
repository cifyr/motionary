import CoreGraphics
import Foundation

/// Keys a coloured backdrop out of an image.
///
/// Replaces the original corner-pixel keyer, which failed on most real art for
/// two reasons worth recording so they are not reintroduced:
///
/// 1. It read the key colour from pixel 0. A backdrop is never one colour --
///    it is lit -- so the lit and shadowed halves of the same screen measured
///    as different colours and only one of them keyed.
/// 2. It measured Chebyshev distance across R, G and B together. That mixes
///    brightness into the decision, so a shadowed backdrop looks "far" from the
///    key and survives, while any antialiased pixel -- part subject, part
///    backdrop -- also measures far and stays fully opaque. That is precisely
///    the hard edge and green fringe seen on soft edges.
///
/// This keys on *chroma only*, in the CbCr plane, discarding luma. A backdrop
/// keeps its hue as it is lit and shadowed, so the whole screen keys at once,
/// and a half-covered edge pixel lands half way along the ramp and gets a
/// half alpha, which is what a soft edge needs.
enum ChromaKey {
    struct Settings: Codable, Equatable, Sendable {
        var enabled: Bool = true
        /// Backdrop colour, sRGB 0...1. Nil asks for it to be detected.
        var keyRed: Double?
        var keyGreen: Double?
        var keyBlue: Double?
        /// Chroma distance fully transparent at or below this.
        ///
        /// Normalised chroma runs to about 3 across the whole hue circle, so
        /// these are on that scale rather than 0...1.
        var tolerance: Double = 0.30
        /// Width of the ramp from transparent to opaque, above tolerance.
        /// Larger is a softer edge; 0 is a hard cut.
        var softness: Double = 0.45
        /// How strongly to pull the backdrop's colour back out of pixels it
        /// bled onto. 0 leaves the fringe, 1 removes it completely.
        var spill: Double = 1

        static let `default` = Settings()

        var keyColor: RGB? {
            guard let keyRed, let keyGreen, let keyBlue else { return nil }
            return RGB(r: keyRed, g: keyGreen, b: keyBlue)
        }

        mutating func setKeyColor(_ color: RGB?) {
            keyRed = color?.r
            keyGreen = color?.g
            keyBlue = color?.b
        }
    }

    struct RGB: Equatable, Sendable {
        var r: Double
        var g: Double
        var b: Double

        /// Rec.601 chroma, divided through by luma.
        ///
        /// Luma is dropped because it is the component that varies as a
        /// backdrop is lit, and keeping it is what made the old keyer miss
        /// shadowed corners. Dividing matters as much as subtracting: raw
        /// `b - y` still scales with brightness, so a shadowed green and a lit
        /// green land in different places and only one of them keys. The ratio
        /// does not scale, so both land together.
        ///
        /// The floor keeps near-black pixels, where the ratio is meaningless
        /// and would otherwise explode, from reading as a wild hue.
        var chroma: (cb: Double, cr: Double) {
            let y = 0.299 * r + 0.587 * g + 0.114 * b
            let scale = max(y, 0.05)
            return (cb: (b - y) / scale, cr: (r - y) / scale)
        }

        var saturation: Double {
            let high = max(r, g, b)
            let low = min(r, g, b)
            return high <= 0 ? 0 : (high - low) / high
        }
    }

    /// Straight-alpha RGBA8 pixels, plus dimensions.
    private struct Bitmap {
        var data: [UInt8]
        let width: Int
        let height: Int
    }

    // MARK: - Key colour detection

    /// The dominant saturated colour around the image's border.
    ///
    /// The border is used because that is where a backdrop is; the *mode* of a
    /// coarse chroma histogram is used rather than a mean so that a subject
    /// touching one edge cannot drag the estimate, which an average would.
    /// Returns nil when the border is not saturated enough to be a deliberate
    /// backdrop -- white and parchment paddings are the trimmer's job, and
    /// keying those would eat any pale part of the picture.
    static func detectKeyColor(in image: CGImage, minimumSaturation: Double = 0.25) -> RGB? {
        guard let bitmap = read(image), bitmap.width > 2, bitmap.height > 2 else { return nil }

        let bins = 24
        var histogram: [Int: (count: Int, sum: RGB)] = [:]

        func consider(_ x: Int, _ y: Int) {
            let pixel = colour(in: bitmap, x: x, y: y)
            guard pixel.alpha > 0.5 else { return }
            let rgb = pixel.rgb
            guard rgb.saturation >= minimumSaturation else { return }
            let (cb, cr) = rgb.chroma
            // Chroma runs about -0.5...0.5; shift into 0...1 before binning.
            let key = Int((cb + 0.5) * Double(bins)) * bins + Int((cr + 0.5) * Double(bins))
            let existing = histogram[key] ?? (0, RGB(r: 0, g: 0, b: 0))
            histogram[key] = (
                existing.count + 1,
                RGB(r: existing.sum.r + rgb.r, g: existing.sum.g + rgb.g, b: existing.sum.b + rgb.b)
            )
        }

        for x in 0 ..< bitmap.width {
            consider(x, 0)
            consider(x, bitmap.height - 1)
        }
        for y in 0 ..< bitmap.height {
            consider(0, y)
            consider(bitmap.width - 1, y)
        }

        guard let best = histogram.values.max(by: { $0.count < $1.count }) else { return nil }

        // A backdrop occupies most of the border. Less than a third means the
        // border is busy, which is a picture that reaches its edges rather
        // than a subject on a screen.
        let border = 2 * (bitmap.width + bitmap.height)
        guard best.count * 3 > border else { return nil }

        let n = Double(best.count)
        return RGB(r: best.sum.r / n, g: best.sum.g / n, b: best.sum.b / n)
    }

    // MARK: - Keying

    /// Returns nil when there is nothing to key, so callers can keep the original.
    ///
    /// A detected key is a guess and may decline; an explicit one is an
    /// instruction and is always carried out.
    static func apply(to image: CGImage, settings: Settings) -> CGImage? {
        guard settings.enabled else { return nil }
        let chosen = settings.keyColor
        guard let key = chosen ?? detectKeyColor(in: image) else { return nil }
        guard var bitmap = read(image) else { return nil }

        let keyChroma = key.chroma
        let tolerance = max(0, settings.tolerance)
        let softness = max(0, settings.softness)
        let spill = min(max(settings.spill, 0), 1)
        var cleared = 0
        var retained = 0

        for index in stride(from: 0, to: bitmap.data.count, by: 4) {
            let alpha = Double(bitmap.data[index + 3]) / 255
            guard alpha > 0 else { continue }

            var rgb = RGB(
                r: Double(bitmap.data[index]) / 255,
                g: Double(bitmap.data[index + 1]) / 255,
                b: Double(bitmap.data[index + 2]) / 255
            )
            let (cb, cr) = rgb.chroma
            let distance = ((cb - keyChroma.cb) * (cb - keyChroma.cb)
                + (cr - keyChroma.cr) * (cr - keyChroma.cr)).squareRoot()

            // Alpha ramps 0 at the key's own chroma to 1 once clear of it. A
            // pixel that is half backdrop lands mid-ramp and keeps half alpha,
            // which is what makes hair and motion blur survive.
            let coverage: Double
            if distance <= tolerance {
                coverage = 0
            } else if softness <= 0 || distance >= tolerance + softness {
                coverage = 1
            } else {
                coverage = (distance - tolerance) / softness
            }

            // Despill every visible pixel, judged on its own colour rather than
            // on the alpha ramp. Bounced light reaches well inside the subject,
            // where the chroma distance is large and a ramp-gated despill --
            // which is what this was first written as -- does nothing at all.
            if spill > 0, coverage > 0 {
                rgb = desaturatingTowardKey(rgb, key: key, strength: spill)
            }

            bitmap.data[index] = channel(rgb.r)
            bitmap.data[index + 1] = channel(rgb.g)
            bitmap.data[index + 2] = channel(rgb.b)
            bitmap.data[index + 3] = channel(alpha * coverage)

            if coverage <= 0.01 { cleared += 1 } else if coverage >= 0.99 { retained += 1 }
        }

        if chosen == nil {
            // Two sanity checks on a guess. Keying almost nothing means the
            // detected colour was not a backdrop; keying almost everything
            // means the artwork itself was taken for one, which is what a
            // full-bleed picture with one vivid corner looks like.
            let total = bitmap.width * bitmap.height
            guard cleared * 50 > total, retained * 50 > total else { return nil }
        }

        return makeImage(bitmap)
    }

    /// Pulls the key's dominant channel back toward the other two.
    ///
    /// Only the channel the backdrop is actually made of moves, so a subject's
    /// own colour is untouched anywhere the key is not dominant -- a red coat
    /// in front of a green screen keeps its red.
    private static func desaturatingTowardKey(_ rgb: RGB, key: RGB, strength: Double) -> RGB {
        let channels = [rgb.r, rgb.g, rgb.b]
        let keyChannels = [key.r, key.g, key.b]
        guard let dominant = keyChannels.enumerated().max(by: { $0.element < $1.element })?.offset
        else { return rgb }

        let others = (0 ..< 3).filter { $0 != dominant }
        let reference = (channels[others[0]] + channels[others[1]]) / 2
        guard channels[dominant] > reference else { return rgb }

        var pulled = channels
        pulled[dominant] = channels[dominant] + (reference - channels[dominant]) * strength
        return RGB(r: pulled[0], g: pulled[1], b: pulled[2])
    }

    // MARK: - Pixel plumbing

    private static func channel(_ value: Double) -> UInt8 {
        UInt8(min(255, max(0, (value * 255).rounded())))
    }

    private static func colour(in bitmap: Bitmap, x: Int, y: Int) -> (rgb: RGB, alpha: Double) {
        let index = (y * bitmap.width + x) * 4
        return (
            RGB(
                r: Double(bitmap.data[index]) / 255,
                g: Double(bitmap.data[index + 1]) / 255,
                b: Double(bitmap.data[index + 2]) / 255
            ),
            Double(bitmap.data[index + 3]) / 255
        )
    }

    /// Reads to *straight* alpha, so a partly transparent pixel keeps a
    /// meaningful colour to measure chroma from. A premultiplied edge pixel has
    /// its colour scaled toward black by its own alpha, which would read as a
    /// different hue and key inconsistently.
    ///
    /// The context itself must be premultiplied -- CoreGraphics does not accept
    /// a straight-alpha bitmap context -- so it is un-premultiplied by hand.
    private static func read(_ image: CGImage) -> Bitmap? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        for index in stride(from: 0, to: data.count, by: 4) {
            let alpha = Int(data[index + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for offset in 0 ..< 3 {
                data[index + offset] = UInt8(min(255, Int(data[index + offset]) * 255 / alpha))
            }
        }
        return Bitmap(data: data, width: width, height: height)
    }

    private static func makeImage(_ bitmap: Bitmap) -> CGImage? {
        var data = bitmap.data
        for index in stride(from: 0, to: data.count, by: 4) {
            let alpha = Int(data[index + 3])
            guard alpha < 255 else { continue }
            for offset in 0 ..< 3 {
                data[index + offset] = UInt8(Int(data[index + offset]) * alpha / 255)
            }
        }

        guard let context = CGContext(
            data: &data,
            width: bitmap.width,
            height: bitmap.height,
            bitsPerComponent: 8,
            bytesPerRow: bitmap.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        return context.makeImage()
    }
}
