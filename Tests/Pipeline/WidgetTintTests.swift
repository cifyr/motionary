import CoreGraphics
import XCTest

/// The widget has to agree with the wallpaper it sits in, or the frame reads as a
/// panel laid over the picture rather than part of it.
@MainActor
final class WidgetTintTests: XCTestCase {
    /// Measured cleanly - between the icon rows, and on the side clear of the
    /// animated crop - the two display paths agree, so the correction is
    /// identity. Both earlier gains reproduced themselves in the residual,
    /// which is what a correction for a difference that is not there does.
    func testThereIsNoCorrectionToApply() {
        XCTAssertEqual(WidgetTint.gain.r, 1)
        XCTAssertEqual(WidgetTint.gain.g, 1)
        XCTAssertEqual(WidgetTint.gain.b, 1)
    }

    /// Small enough to be a colour match rather than a look, whatever it is set
    /// to. This is the guard on any future re-measurement, not on today's value.
    func testTheGainStaysSubtle() {
        for factor in [WidgetTint.gain.r, WidgetTint.gain.g, WidgetTint.gain.b] {
            XCTAssertGreaterThan(factor, 0.9)
            XCTAssertLessThan(factor, 1.1)
        }
    }

    func testEachChannelIsScaledByItsOwnGain() throws {
        let image = try solid(r: 100, g: 100, b: 100, side: 8)
        let before = try Pixels(image).at(x: 4, y: 4)
        let after = try Pixels(WidgetTint.applied(to: image)).at(x: 4, y: 4)

        XCTAssertEqual(Double(after.r), Double(before.r) * WidgetTint.gain.r, accuracy: 1.5)
        XCTAssertEqual(Double(after.g), Double(before.g) * WidgetTint.gain.g, accuracy: 1.5)
        XCTAssertEqual(Double(after.b), Double(before.b) * WidgetTint.gain.b, accuracy: 1.5)
    }

    /// The whole picture survives an identity gain. A pass that quietly dropped
    /// the alpha layout, or rounded every level, would still satisfy a check on
    /// one pixel of flat colour.
    func testAnIdentityGainReturnsThePictureUnchanged() throws {
        let image = try solid(r: 37, g: 149, b: 220, side: 8)
        let before = try Pixels(image)
        let after = try Pixels(WidgetTint.applied(to: image))
        for y in 0 ..< 8 {
            for x in 0 ..< 8 {
                XCTAssertEqual(after.at(x: x, y: y).r, before.at(x: x, y: y).r)
                XCTAssertEqual(after.at(x: x, y: y).g, before.at(x: x, y: y).g)
                XCTAssertEqual(after.at(x: x, y: y).b, before.at(x: x, y: y).b)
            }
        }
    }

    /// White stays white, whatever the gain is: a highlight that clipped in one
    /// channel only would come out tinted.
    func testHighlightsStayNeutral() throws {
        let image = try solid(r: 255, g: 255, b: 255, side: 8)
        let after = try Pixels(WidgetTint.applied(to: image)).at(x: 4, y: 4)
        XCTAssertEqual(after.r, 255)
        XCTAssertEqual(after.g, 255)
        XCTAssertEqual(after.b, 255)
    }

    func testBlackStaysBlack() throws {
        let image = try solid(r: 0, g: 0, b: 0, side: 8)
        let after = try Pixels(WidgetTint.applied(to: image)).at(x: 4, y: 4)
        XCTAssertEqual(after.r, 0)
        XCTAssertEqual(after.g, 0)
        XCTAssertEqual(after.b, 0)
    }

    private func solid(r: Int, g: Int, b: Int, side: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(
            red: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: 1
        ))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return try XCTUnwrap(context.makeImage())
    }

    private struct Pixels {
        let bytes: [UInt8]
        let width: Int

        init(_ image: CGImage) throws {
            let width = image.width
            let height = image.height
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            let drew = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(
                    data: raw.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                ) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            XCTAssertTrue(drew)
            bytes = buffer
            self.width = width
        }

        func at(x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
            let index = (y * width + x) * 4
            return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
        }
    }
}
