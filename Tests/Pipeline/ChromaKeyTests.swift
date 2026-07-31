import CoreGraphics
import XCTest

/// Each case here is a way the corner-pixel keyer failed on real art. They are
/// written as the failure, not as the feature, so a regression reads plainly.
///
/// `ChromaKeyTests` in Tests/Studio covers the behaviour `SkinLibrary.keyingOut`
/// promised before this existed; those still pass against the new keyer, which
/// is what says the replacement did not lose anything.
final class ChromaKeyerTests: XCTestCase {

    // MARK: - Fixtures

    /// Builds an RGBA image from a closure, straight alpha.
    private func image(
        width: Int,
        height: Int,
        pixel: (Int, Int) -> (Double, Double, Double, Double)
    ) -> CGImage {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let (r, g, b, a) = pixel(x, y)
                let index = (y * width + x) * 4
                data[index] = UInt8(min(255, max(0, r * 255)))
                data[index + 1] = UInt8(min(255, max(0, g * 255)))
                data[index + 2] = UInt8(min(255, max(0, b * 255)))
                data[index + 3] = UInt8(min(255, max(0, a * 255)))
            }
        }
        let context = CGContext(
            data: &data, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    private func alpha(of image: CGImage, x: Int, y: Int) -> Double {
        pixel(of: image, x: x, y: y).3
    }

    private func pixel(of image: CGImage, x: Int, y: Int) -> (Double, Double, Double, Double) {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let index = (y * image.width + x) * 4
        return (
            Double(data[index]) / 255, Double(data[index + 1]) / 255,
            Double(data[index + 2]) / 255, Double(data[index + 3]) / 255
        )
    }

    /// A green screen with a red square in the middle.
    private func greenScreen(
        side: Int = 32,
        shade: @escaping (Int, Int) -> Double = { _, _ in 1 }
    ) -> CGImage {
        image(width: side, height: side) { x, y in
            let middle = (side / 4) ..< (side * 3 / 4)
            if middle.contains(x), middle.contains(y) { return (0.8, 0.1, 0.1, 1) }
            let level = shade(x, y)
            return (0.05 * level, 0.75 * level, 0.1 * level, 1)
        }
    }

    // MARK: - The failures that motivated the rewrite

    /// The old keyer read the key from pixel 0 and measured across R, G and B,
    /// so a lit screen only keyed wherever it happened to match that corner.
    func testAShadedBackdropKeysAllTheWayAcross() {
        let side = 32
        // Half brightness on the left, full on the right.
        let shaded = greenScreen(side: side) { x, _ in 0.45 + 0.55 * Double(x) / Double(side) }

        guard let keyed = ChromaKey.apply(to: shaded, settings: .default) else {
            return XCTFail("nothing keyed")
        }

        XCTAssertEqual(alpha(of: keyed, x: 1, y: 1), 0, accuracy: 0.02, "dark corner survived")
        XCTAssertEqual(alpha(of: keyed, x: side - 2, y: 1), 0, accuracy: 0.02, "lit corner survived")
        XCTAssertEqual(alpha(of: keyed, x: 1, y: side - 2), 0, accuracy: 0.02)
    }

    /// A half-covered edge pixel has to come out half transparent. Measuring
    /// brightness put these far from the key, so they stayed fully opaque and
    /// the cut looked like a staircase with a green rim.
    func testAHalfCoveredEdgePixelKeepsPartialAlpha() {
        let side = 16
        // A subject band down the middle, so the border stays backdrop, with
        // one column blended 50/50 between the two as an antialiased edge is.
        let backdrop = (0.05, 0.75, 0.1)
        let subject = (0.8, 0.1, 0.1)
        let blended = image(width: side, height: side) { x, _ in
            switch x {
            case 6:
                return ((backdrop.0 + subject.0) / 2, (backdrop.1 + subject.1) / 2,
                        (backdrop.2 + subject.2) / 2, 1)
            case 7 ... 11:
                return (subject.0, subject.1, subject.2, 1)
            default:
                return (backdrop.0, backdrop.1, backdrop.2, 1)
            }
        }

        // Softness spans most of the distance between the two hues, which on
        // the normalised chroma scale is about 2.5.
        guard let keyed = ChromaKey.apply(
            to: blended,
            settings: ChromaKey.Settings(tolerance: 0.30, softness: 1.8)
        ) else { return XCTFail("nothing keyed") }

        let edge = alpha(of: keyed, x: 6, y: 8)
        XCTAssertGreaterThan(edge, 0.05, "the soft edge was punched through")
        XCTAssertLessThan(edge, 0.95, "the soft edge stayed fully opaque")
        XCTAssertEqual(alpha(of: keyed, x: 1, y: 8), 0, accuracy: 0.02)
        XCTAssertEqual(alpha(of: keyed, x: 9, y: 8), 1, accuracy: 0.02)
    }

    func testTheSubjectSurvivesKeying() {
        guard let keyed = ChromaKey.apply(to: greenScreen(), settings: .default) else {
            return XCTFail("nothing keyed")
        }
        XCTAssertEqual(alpha(of: keyed, x: 16, y: 16), 1, accuracy: 0.02)
        let (r, _, _, _) = pixel(of: keyed, x: 16, y: 16)
        XCTAssertGreaterThan(r, 0.5, "the subject lost its own colour")
    }

    /// Spill is backdrop light bouncing onto the subject. It has to come off
    /// pixels that stay fully visible, not only the ones on the alpha ramp.
    func testSpillIsPulledOutOfAVisiblePixel() {
        let side = 16
        // A subject tinted toward the backdrop, as a bounce would leave it.
        let spilled = image(width: side, height: side) { x, y in
            let middle = 4 ..< 12
            if middle.contains(x), middle.contains(y) { return (0.45, 0.62, 0.30, 1) }
            return (0.05, 0.75, 0.1, 1)
        }

        let before = pixel(of: spilled, x: 8, y: 8)
        guard let keyed = ChromaKey.apply(to: spilled, settings: .default) else {
            return XCTFail("nothing keyed")
        }
        let after = pixel(of: keyed, x: 8, y: 8)

        XCTAssertGreaterThan(alpha(of: keyed, x: 8, y: 8), 0.5, "the spilled subject was keyed away")
        XCTAssertLessThan(after.1, before.1, "the green cast was not reduced")
    }

    func testSpillOffLeavesTheCastAlone() {
        let side = 16
        let spilled = image(width: side, height: side) { x, y in
            let middle = 4 ..< 12
            if middle.contains(x), middle.contains(y) { return (0.45, 0.62, 0.30, 1) }
            return (0.05, 0.75, 0.1, 1)
        }

        var settings = ChromaKey.Settings.default
        settings.spill = 0
        guard let keyed = ChromaKey.apply(to: spilled, settings: settings) else {
            return XCTFail("nothing keyed")
        }
        XCTAssertEqual(pixel(of: keyed, x: 8, y: 8).1, 0.62, accuracy: 0.02)
    }

    // MARK: - Key colour detection

    func testTheKeyComesFromTheBorderNotTheFirstPixel() {
        let side = 24
        // One stray bright magenta pixel at the origin, on a green border.
        let stray = image(width: side, height: side) { x, y in
            if x == 0, y == 0 { return (0.9, 0.0, 0.9, 1) }
            let middle = 8 ..< 16
            if middle.contains(x), middle.contains(y) { return (0.8, 0.1, 0.1, 1) }
            return (0.05, 0.75, 0.1, 1)
        }

        guard let key = ChromaKey.detectKeyColor(in: stray) else {
            return XCTFail("no key colour found")
        }
        XCTAssertGreaterThan(key.g, key.r, "the stray corner pixel was taken as the key")
        XCTAssertGreaterThan(key.g, key.b)
    }

    /// White and parchment paddings are the trimmer's job. Keying those would
    /// eat any pale part of the picture.
    func testAPaleBorderIsNotTreatedAsAKey() {
        let side = 16
        let paper = image(width: side, height: side) { x, y in
            let middle = 4 ..< 12
            if middle.contains(x), middle.contains(y) { return (0.2, 0.2, 0.7, 1) }
            return (0.97, 0.96, 0.94, 1)
        }

        XCTAssertNil(ChromaKey.detectKeyColor(in: paper))
        XCTAssertNil(ChromaKey.apply(to: paper, settings: .default))
    }

    func testABusyBorderIsNotTreatedAsAKey() {
        let side = 16
        let busy = image(width: side, height: side) { x, y in
            switch (x + y) % 4 {
            case 0: return (0.9, 0.1, 0.1, 1)
            case 1: return (0.1, 0.9, 0.1, 1)
            case 2: return (0.1, 0.1, 0.9, 1)
            default: return (0.9, 0.9, 0.1, 1)
            }
        }
        XCTAssertNil(ChromaKey.detectKeyColor(in: busy))
    }

    func testAnExplicitKeyColourOverridesDetection() {
        let side = 16
        // Green border, blue block. Keying blue explicitly must cut the block.
        let both = image(width: side, height: side) { x, y in
            let middle = 4 ..< 12
            if middle.contains(x), middle.contains(y) { return (0.1, 0.15, 0.85, 1) }
            return (0.05, 0.75, 0.1, 1)
        }

        var settings = ChromaKey.Settings.default
        settings.setKeyColor(ChromaKey.RGB(r: 0.1, g: 0.15, b: 0.85))
        guard let keyed = ChromaKey.apply(to: both, settings: settings) else {
            return XCTFail("nothing keyed")
        }

        XCTAssertEqual(alpha(of: keyed, x: 8, y: 8), 0, accuracy: 0.02, "the chosen key survived")
        XCTAssertEqual(alpha(of: keyed, x: 1, y: 1), 1, accuracy: 0.02, "the border was keyed instead")
    }

    func testDisabledKeyingReturnsNothingToDo() {
        var settings = ChromaKey.Settings.default
        settings.enabled = false
        XCTAssertNil(ChromaKey.apply(to: greenScreen(), settings: settings))
    }

    func testSettingsRoundTripThroughCoding() throws {
        var settings = ChromaKey.Settings.default
        settings.setKeyColor(ChromaKey.RGB(r: 0.2, g: 0.8, b: 0.3))
        settings.tolerance = 0.21
        settings.softness = 0.05
        settings.spill = 0.4

        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(ChromaKey.Settings.self, from: data), settings)
    }
}
