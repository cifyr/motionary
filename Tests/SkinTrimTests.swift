import CoreGraphics
import XCTest

/// Imported artwork arrives padded - the set this was built for is 1024x1536
/// with the icon floating in white - so trimming decides whether a tile shows
/// an icon or a letterboxed postage stamp.
final class SkinTrimTests: XCTestCase {
    /// Draws `inner` filled in the middle of a `border`-coloured canvas.
    private func padded(
        canvas: CGSize,
        inner: CGRect,
        border: CGColor,
        fill: CGColor
    ) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: Int(canvas.width),
            height: Int(canvas.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(border)
        context.fill(CGRect(origin: .zero, size: canvas))
        context.setFillColor(fill)
        context.fill(inner)
        return try XCTUnwrap(context.makeImage())
    }

    private let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    private let clear = CGColor(red: 0, green: 0, blue: 0, alpha: 0)
    private let art = CGColor(red: 0.4, green: 0.2, blue: 0.05, alpha: 1)

    /// The real shape of the artwork in question.
    func testTrimsWhitePaddingFromATallCanvas() throws {
        let image = try padded(
            canvas: CGSize(width: 1024, height: 1536),
            inner: CGRect(x: 112, y: 400, width: 800, height: 800),
            border: white,
            fill: art
        )
        let trimmed = try XCTUnwrap(SkinLibrary.trimmed(image), "nothing was trimmed")
        XCTAssertEqual(trimmed.width, 800)
        XCTAssertEqual(trimmed.height, 800)
    }

    /// Transparent padding has to work too: generated art comes both ways, and
    /// assuming white would trim nothing from a cut-out PNG.
    func testTrimsTransparentPadding() throws {
        let image = try padded(
            canvas: CGSize(width: 600, height: 600),
            inner: CGRect(x: 100, y: 150, width: 300, height: 200),
            border: clear,
            fill: art
        )
        let trimmed = try XCTUnwrap(SkinLibrary.trimmed(image))
        XCTAssertEqual(trimmed.width, 300)
        XCTAssertEqual(trimmed.height, 200)
    }

    /// Artwork that already fills its canvas must be left alone rather than
    /// having a row shaved off it.
    func testLeavesFullBleedArtworkAlone() throws {
        let image = try padded(
            canvas: CGSize(width: 256, height: 256),
            inner: CGRect(x: 0, y: 0, width: 256, height: 256),
            border: art,
            fill: art
        )
        XCTAssertNil(SkinLibrary.trimmed(image), "a full-bleed image should not be trimmed")
    }

    /// A tile is square, so a trimmed rectangle is padded back to square
    /// instead of being stretched to fit.
    func testSquaringKeepsProportions() throws {
        let image = try padded(
            canvas: CGSize(width: 300, height: 200),
            inner: CGRect(x: 0, y: 0, width: 300, height: 200),
            border: art,
            fill: art
        )
        let squared = try XCTUnwrap(SkinLibrary.squared(image))
        XCTAssertEqual(squared.width, 300)
        XCTAssertEqual(squared.height, 300)
    }

    func testScalingReachesTheRequestedSide() throws {
        let image = try padded(
            canvas: CGSize(width: 1024, height: 1024),
            inner: CGRect(x: 0, y: 0, width: 1024, height: 1024),
            border: art,
            fill: art
        )
        let scaled = try XCTUnwrap(SkinLibrary.scaled(image, to: SkinLibrary.renderedSide))
        XCTAssertEqual(scaled.width, SkinLibrary.renderedSide)
        XCTAssertEqual(scaled.height, SkinLibrary.renderedSide)
    }
}

/// Icon art often arrives on a green screen. Trimming alone would cut it from
/// the edges and leave it filling every gap inside the artwork.
final class ChromaKeyTests: XCTestCase {
    private func onGreen(inner: CGRect, canvas: CGSize, gap: CGRect? = nil) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: Int(canvas.width),
            height: Int(canvas.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.06, green: 0.88, blue: 0.05, alpha: 1))
        context.fill(CGRect(origin: .zero, size: canvas))
        context.setFillColor(CGColor(red: 0.5, green: 0.3, blue: 0.1, alpha: 1))
        context.fill(inner)
        if let gap {
            // A hole in the artwork, filled with the key colour: the case
            // trimming cannot handle.
            context.setFillColor(CGColor(red: 0.06, green: 0.88, blue: 0.05, alpha: 1))
            context.fill(gap)
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func alpha(_ image: CGImage, x: Int, y: Int) throws -> UInt8 {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &data,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data[(y * image.width + x) * 4 + 3]
    }

    func testGreenBecomesTransparentAndTheArtworkDoesNot() throws {
        let canvas = CGSize(width: 400, height: 400)
        let image = try onGreen(inner: CGRect(x: 100, y: 100, width: 200, height: 200), canvas: canvas)
        let keyed = try XCTUnwrap(SkinLibrary.keyingOut(image), "a green screen should be keyed")

        XCTAssertEqual(try alpha(keyed, x: 5, y: 5), 0, "the background should be gone")
        XCTAssertEqual(try alpha(keyed, x: 200, y: 200), 255, "the artwork should be untouched")
    }

    /// The reason keying exists rather than only trimming.
    func testGreenInsideTheArtworkGoesToo() throws {
        let canvas = CGSize(width: 400, height: 400)
        let image = try onGreen(
            inner: CGRect(x: 50, y: 50, width: 300, height: 300),
            canvas: canvas,
            gap: CGRect(x: 180, y: 180, width: 40, height: 40)
        )
        let keyed = try XCTUnwrap(SkinLibrary.keyingOut(image))
        XCTAssertEqual(try alpha(keyed, x: 200, y: 200), 0, "a keyed hole inside the artwork should be transparent")
        XCTAssertEqual(try alpha(keyed, x: 60, y: 60), 255)
    }

    /// White and parchment paddings are the trimmer's job. Keying those would
    /// eat any pale part of the picture.
    func testAPaperBackgroundIsLeftToTheTrimmer() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        context.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 60, y: 60, width: 80, height: 80))
        let image = try XCTUnwrap(context.makeImage())

        XCTAssertNil(SkinLibrary.keyingOut(image), "a white background must not be keyed")
        XCTAssertNotNil(SkinLibrary.trimmed(image), "it should be trimmed instead")
    }

    /// A picture that merely starts on a vivid pixel is not a green screen.
    func testAVividCornerAloneIsNotAKey() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.4, green: 0.25, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 195, width: 5, height: 5))
        let image = try XCTUnwrap(context.makeImage())
        XCTAssertNil(SkinLibrary.keyingOut(image), "one vivid corner is not a background")
    }
}
