import CoreGraphics
import XCTest

/// The wallpaper is the only place a tile can be drawn outside the widget frame.
///
/// The widget draws the live, tappable tiles and clips them to its own frame, so
/// a tile placed half on is cut in half there. Baking the tiles into the still
/// wallpaper is what completes the other half.
@MainActor
final class WallpaperCompositionTests: XCTestCase {
    private let screen = CGSize(width: 400, height: 800)
    /// A stand-in widget frame, so a tile can be placed to straddle its edge.
    private let frame = CGRect(x: 100, y: 200, width: 200, height: 400)

    private func skinnedTile(at center: CGPoint, size: CGFloat) -> PlacedTile {
        var tile = PlacedTile(appID: "spotify", center: center, size: size)
        // A skin fills the tile edge to edge, so the pixels underneath it are a
        // flat colour this can assert on.
        tile.skin = "test-skin.png"
        tile.showsLabel = false
        return tile
    }

    func testATileStraddlingTheEdgeIsBakedOnBothSides() throws {
        let base = try Self.solid(red: 0, green: 0, blue: 1, size: screen)
        let tile = skinnedTile(at: CGPoint(x: frame.minX, y: frame.midY), size: 120)

        let composed = WallpaperComposer.compose(
            frame: base,
            tiles: [tile],
            screenSize: screen,
            artwork: { _ in try? Self.solid(red: 1, green: 0, blue: 0, size: CGSize(width: 64, height: 64)) }
        )

        let pixels = try Pixels(composed)
        // Outside the widget frame: the half the widget cannot draw at all.
        XCTAssertTrue(
            pixels.isRed(x: Int(frame.minX) - 40, y: Int(frame.midY)),
            "the half outside the widget frame was not baked into the wallpaper"
        )
        // Inside it: the wallpaper carries it too, and the widget draws its live
        // tile over the same pixels.
        XCTAssertTrue(pixels.isRed(x: Int(frame.minX) + 40, y: Int(frame.midY)))
        // Well clear of the tile, the frame is untouched.
        XCTAssertTrue(pixels.isBlue(x: 20, y: 20))
    }

    /// A tile that falls entirely outside the frame is still baked: it is a
    /// picture that cannot be tapped, not a tile that vanishes.
    func testATileFullyOutsideTheFrameIsStillBaked() throws {
        let base = try Self.solid(red: 0, green: 0, blue: 1, size: screen)
        let center = CGPoint(x: frame.midX, y: frame.minY - 100)
        let composed = WallpaperComposer.compose(
            frame: base,
            tiles: [skinnedTile(at: center, size: 100)],
            screenSize: screen,
            artwork: { _ in try? Self.solid(red: 1, green: 0, blue: 0, size: CGSize(width: 64, height: 64)) }
        )
        XCTAssertTrue(try Pixels(composed).isRed(x: Int(center.x), y: Int(center.y)))
    }

    /// The baked tile has to land on the pixels `tile.rect` names, or the
    /// wallpaper's half and the widget's half will not meet at the seam.
    func testTheBakedTileLandsWhereTheLayoutSaysItDoes() throws {
        let base = try Self.solid(red: 0, green: 0, blue: 1, size: screen)
        let center = CGPoint(x: 200, y: 400)
        let side: CGFloat = 120
        let composed = WallpaperComposer.compose(
            frame: base,
            tiles: [skinnedTile(at: center, size: side)],
            screenSize: screen,
            artwork: { _ in try? Self.solid(red: 1, green: 0, blue: 0, size: CGSize(width: 64, height: 64)) }
        )

        let pixels = try Pixels(composed)
        let rect = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        // Just inside each edge, at the midpoint - the corners are rounded away.
        XCTAssertTrue(pixels.isRed(x: Int(rect.minX) + 4, y: Int(rect.midY)), "left edge")
        XCTAssertTrue(pixels.isRed(x: Int(rect.maxX) - 4, y: Int(rect.midY)), "right edge")
        XCTAssertTrue(pixels.isRed(x: Int(rect.midX), y: Int(rect.minY) + 4), "top edge")
        XCTAssertTrue(pixels.isRed(x: Int(rect.midX), y: Int(rect.maxY) - 4), "bottom edge")
        // Beyond the plate's shadow, nothing was drawn.
        XCTAssertTrue(pixels.isBlue(x: Int(rect.midX), y: Int(rect.minY) - Int(side)))
    }

    func testAnEmptyLayoutLeavesTheFrameAlone() throws {
        let base = try Self.solid(red: 0, green: 0, blue: 1, size: screen)
        let composed = WallpaperComposer.compose(frame: base, tiles: [], screenSize: screen)
        XCTAssertTrue(composed === base, "an empty layout re-encoded the frame for nothing")
    }

    /// Missing artwork falls back to the catalogue's SF Symbol on a tinted
    /// plate, the same as in the widget - a tile is never a hole.
    func testATileWithoutArtworkStillDraws() throws {
        let base = try Self.solid(red: 0, green: 0, blue: 1, size: screen)
        var tile = PlacedTile(appID: "spotify", center: CGPoint(x: 200, y: 400), size: 120)
        tile.showsLabel = false
        let composed = WallpaperComposer.compose(frame: base, tiles: [tile], screenSize: screen)
        XCTAssertFalse(
            try Pixels(composed).isBlue(x: 200, y: 400),
            "nothing was drawn where the tile is"
        )
    }

    // MARK: - Helpers

    private nonisolated static func solid(red: CGFloat, green: CGFloat, blue: CGFloat, size: CGSize) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        return try XCTUnwrap(context.makeImage())
    }

    /// Read back into a known layout: row 0 at the top, four bytes per pixel, so
    /// a screen coordinate can be sampled directly.
    private struct Pixels {
        let bytes: [UInt8]
        let width: Int
        let height: Int

        init(_ image: CGImage) throws {
            // Locals, not the properties: the closure below would otherwise
            // capture a partly initialised self.
            let width = image.width
            let height = image.height
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            // The context must not outlive the buffer it draws into, so it is
            // created, used and dropped inside the access.
            let drew = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(
                    data: raw.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            XCTAssertTrue(drew, "could not read \(width)x\(height) back")
            self.width = width
            self.height = height
            bytes = buffer
        }

        func at(x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
            let index = (y * width + x) * 4
            return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
        }

        func isRed(x: Int, y: Int) -> Bool {
            let pixel = at(x: x, y: y)
            return pixel.r > 150 && pixel.g < 90 && pixel.b < 90
        }

        func isBlue(x: Int, y: Int) -> Bool {
            let pixel = at(x: x, y: y)
            return pixel.b > 150 && pixel.r < 90 && pixel.g < 90
        }
    }
}
