import CoreGraphics
import XCTest

/// The widget has to agree with the wallpaper it sits in, or the frame reads as a
/// panel laid over the picture rather than part of it.
@MainActor
final class WidgetTintTests: XCTestCase {
    /// The measured difference was red up, green and blue down inside the widget,
    /// so the correction has to push the other way. A gain that lifted all three
    /// would only make the widget brighter, not match its colour.
    func testTheGainOpposesTheMeasuredWarmth() {
        XCTAssertLessThan(WidgetTint.gain.r, 1, "red was measured high inside the widget")
        XCTAssertGreaterThan(WidgetTint.gain.g, 1)
        XCTAssertGreaterThan(WidgetTint.gain.b, WidgetTint.gain.g, "blue was the furthest off")
    }

    /// Small enough to be a colour match rather than a look.
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
        XCTAssertGreaterThan(after.b, before.b, "blue has to come up or nothing was corrected")
    }

    /// White stays white: the gain would push blue past 255, and a highlight that
    /// clipped in one channel only would come out tinted.
    func testHighlightsStayNeutral() throws {
        let image = try solid(r: 255, g: 255, b: 255, side: 8)
        let after = try Pixels(WidgetTint.applied(to: image)).at(x: 4, y: 4)
        XCTAssertEqual(after.g, 255)
        XCTAssertEqual(after.b, 255)
        XCTAssertGreaterThan(after.r, 245, "red is only pulled down 1%; white must not go grey")
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
