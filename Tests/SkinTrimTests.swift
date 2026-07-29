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
