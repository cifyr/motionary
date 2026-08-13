import XCTest
import CoreGraphics

/// Shipping only the pixels that move.
///
/// A cut-out clip is a figure over nothing, and flattening it bakes the still
/// scene into every frame. Measured on Spidey Swing: two frames 150 apart differ
/// in 0.26% of their pixels, so 320 frames were 320 copies of one grey gradient
/// - the whole byte budget, which then forced the frames to be shrunk to 0.597
/// and made them soft. Cropped to their own contents they are about 12KB each
/// at full resolution.
final class SpriteFrameTests: XCTestCase {
    /// A canvas with one opaque block in it, at a known place.
    private func image(block: CGRect, size: CGSize) -> CGImage {
        let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(block)
        return context.makeImage()!
    }

    /// The box has to be found where the pixels actually are. A vertical flip
    /// here would put every frame's figure at the wrong end of the widget, and
    /// it is exactly the mistake a bitmap context invites.
    func testTheOpaqueBoxIsWhereTheContentIs() throws {
        let size = CGSize(width: 200, height: 400)
        // CGContext fills from the bottom left, so a block at y=0 is the bottom
        // of the picture - and the rect that comes back is in image order, top
        // left, so it should be near the bottom.
        let bottom = try XCTUnwrap(
            FrameEncoder.opaqueBounds(of: image(block: CGRect(x: 20, y: 0, width: 40, height: 50), size: size))
        )
        XCTAssertGreaterThan(bottom.minY, size.height / 2, "a block drawn at the bottom is not at the top")
        XCTAssertEqual(bottom.minX, 20, accuracy: 5)
        XCTAssertEqual(bottom.width, 40, accuracy: 8, "the pad is a few pixels, not a few dozen")

        let top = try XCTUnwrap(
            FrameEncoder.opaqueBounds(of: image(block: CGRect(x: 20, y: 350, width: 40, height: 50), size: size))
        )
        XCTAssertLessThan(top.minY, size.height / 2)
        XCTAssertLessThan(top.minY, bottom.minY, "the two blocks must not come back the same way up")
    }

    /// Nothing opaque is not an error: the figure swings off the crop and that
    /// lane still has to exist, or the stack loses its shape.
    func testAnEmptyFrameHasNoBox() {
        let blank = CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!.makeImage()!
        XCTAssertNil(FrameEncoder.opaqueBounds(of: blank))
    }

    /// Only a frame that keeps its transparency is worth cropping; a flattened
    /// one is opaque everywhere and its box is the whole crop.
    func testAFlattenedFrameIsNotASprite() {
        let opaque = CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!.makeImage()!
        XCTAssertFalse(FrameSetGenerator.hasAlpha(opaque))
        XCTAssertTrue(FrameSetGenerator.hasAlpha(image(block: .zero, size: CGSize(width: 8, height: 8))))
    }

    /// The rect is a fraction of the crop, so it survives the sprite being
    /// shrunk to fit and the widget being a different size from the screen the
    /// frames were cut for.
    func testTheRectIsNormalisedAndSurvivesARoundTrip() {
        let rect = CGRect(x: 0.25, y: 0.5, width: 0.1, height: 0.2)
        let coded = FrameRect(rect: rect)
        XCTAssertEqual(coded.cgRect, rect)

        let data = try! JSONEncoder().encode([coded])
        let back = try! JSONDecoder().decode([FrameRect].self, from: data)
        XCTAssertEqual(back.first?.cgRect, rect)
    }

    /// Both extensions are read back, because a design delivered before sprites
    /// existed is still on somebody's phone and its frames are JPEG.
    func testBothKindsOfFrameAreRecognised() {
        XCTAssertTrue(DesignStore.isFrameFile("frame-0000.png"))
        XCTAssertTrue(DesignStore.isFrameFile("frame-0123.jpg"))
        XCTAssertFalse(DesignStore.isFrameFile("rects.json"))
        XCTAssertFalse(DesignStore.isFrameFile("preview.mp4"))
    }
}
