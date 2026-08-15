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

    /// The phone's export path: effective tiles composed onto the tile-free
    /// wallpaper, so the background continues whatever occupant each slot
    /// holds - not the authored one the shipped wallpaper was baked with.
    func testTheExportBakesTheChosenOccupantNotTheAuthoredOne() throws {
        let base = try Self.solid(red: 0, green: 0, blue: 1, size: screen)
        let tile = skinnedTile(at: CGPoint(x: frame.minX, y: frame.midY), size: 120)
        var swappable = tile
        swappable.alternates = [TileAlternate(appID: "apple-music", skin: "alt-skin.png")]

        let composed = WallpaperComposer.compose(
            frame: base,
            tiles: SlotChoices.apply(
                to: [swappable],
                choices: [swappable.id.uuidString: "apple-music"]
            ),
            screenSize: screen,
            // Red for the authored app's artwork, green for the alternate's -
            // whichever colour lands is whichever occupant was baked.
            artwork: { tile in
                try? tile.appID == "apple-music"
                    ? Self.solid(red: 0, green: 1, blue: 0, size: CGSize(width: 64, height: 64))
                    : Self.solid(red: 1, green: 0, blue: 0, size: CGSize(width: 64, height: 64))
            }
        )

        let pixels = try Pixels(composed)
        XCTAssertTrue(
            pixels.isGreen(x: Int(frame.minX) - 40, y: Int(frame.midY)),
            "the half outside the widget frame does not show the chosen occupant"
        )
        XCTAssertTrue(pixels.isGreen(x: Int(frame.minX) + 40, y: Int(frame.midY)))
    }

    /// A hidden slot exports as background, not as a picture of a tile that no
    /// longer exists on the widget.
    func testAHiddenSlotIsNotBakedIntoTheExport() throws {
        let base = try Self.solid(red: 0, green: 0, blue: 1, size: screen)
        let tile = skinnedTile(at: CGPoint(x: frame.minX, y: frame.midY), size: 120)

        let composed = WallpaperComposer.compose(
            frame: base,
            tiles: SlotChoices.apply(
                to: [tile],
                choices: [tile.id.uuidString: SlotChoices.hiddenValue]
            ),
            screenSize: screen,
            artwork: { _ in try? Self.solid(red: 1, green: 0, blue: 0, size: CGSize(width: 64, height: 64)) }
        )

        XCTAssertTrue(
            try Pixels(composed).isBlue(x: Int(frame.minX), y: Int(frame.midY)),
            "a hidden slot still left a tile in the exported wallpaper"
        )
    }

    // MARK: - Onto a phone the design was not authored for

    func testTheWallpaperComesOutTheSizeOfTheScreen() throws {
        let authored = try Self.solid(red: 0, green: 0, blue: 1, size: CGSize(width: 1206, height: 2622))
        let scaled = WallpaperComposer.rescaled(authored, to: CGSize(width: 1170, height: 2532))
        XCTAssertEqual(scaled.width, 1170)
        XCTAssertEqual(scaled.height, 2532)
    }

    func testAWallpaperAlreadyTheRightSizeIsNotRedrawn() throws {
        let authored = try Self.solid(red: 0, green: 0, blue: 1, size: screen)
        XCTAssertTrue(
            WallpaperComposer.rescaled(authored, to: screen) === authored,
            "a wallpaper that already fits was re-encoded for nothing"
        )
    }

    /// A size that cannot be drawn is refused rather than half-applied - a zero
    /// screen would otherwise take the wallpaper with it.
    func testAnImpossibleSizeKeepsTheWallpaperIntact() throws {
        let authored = try Self.solid(red: 0, green: 0, blue: 1, size: screen)
        XCTAssertTrue(WallpaperComposer.rescaled(authored, to: .zero) === authored)
    }

    /// The one that matters. A tile baked at the widget frame's corner on the
    /// authored canvas has to still be at that corner once the picture is on
    /// another phone, because the widget will draw its live half exactly there
    /// - at the frame `DeviceModel.derived` works out for that screen.
    func testABakedTileStaysUnderTheWidgetFrameOnAnotherPhone() throws {
        let authoredScreen = DeviceModel.iPhone17Pro.screenPixelSize
        let authoredFrame = DeviceModel.iPhone17Pro.widgetRect
        let base = try Self.solid(red: 0, green: 0, blue: 1, size: authoredScreen)

        let composed = WallpaperComposer.compose(
            frame: base,
            tiles: [skinnedTile(at: CGPoint(x: authoredFrame.minX, y: authoredFrame.midY), size: 240)],
            screenSize: authoredScreen,
            artwork: { _ in try? Self.solid(red: 1, green: 0, blue: 0, size: CGSize(width: 64, height: 64)) }
        )

        let other = CGSize(width: 1170, height: 2532)
        let derived = DeviceModel.matching(screenPixelSize: other, scale: 3)
        let pixels = try Pixels(WallpaperComposer.rescaled(composed, to: other))

        // Either side of the derived frame's edge: the wallpaper carries the
        // half the widget cannot draw, and both halves have to meet at the seam.
        XCTAssertTrue(
            pixels.isRed(x: Int(derived.widgetRect.minX) - 40, y: Int(derived.widgetRect.midY)),
            "the outside half is not under the widget frame this phone will use"
        )
        XCTAssertTrue(
            pixels.isRed(x: Int(derived.widgetRect.minX) + 40, y: Int(derived.widgetRect.midY)),
            "the inside half moved out from under the frame"
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

        func isGreen(x: Int, y: Int) -> Bool {
            let pixel = at(x: x, y: y)
            return pixel.g > 150 && pixel.r < 90 && pixel.b < 90
        }
    }

    /// A placed picture has to survive the whole way to the baked wallpaper,
    /// not merely appear in the editor. It is the wallpaper that ships.
    func testAPlacedAssetIsBakedIntoTheWallpaper() throws {
        let base = try Self.solid(red: 0, green: 0, blue: 1, size: screen)
        let asset = PlacedAsset(
            fileName: "sticker.png",
            center: CGPoint(x: 200, y: 400),
            size: CGSize(width: 100, height: 100)
        )

        let composed = WallpaperComposer.compose(
            frame: base,
            tiles: [],
            assets: [asset],
            screenSize: screen,
            assetArtwork: { _ in
                try? Self.solid(red: 1, green: 0, blue: 0, size: CGSize(width: 64, height: 64))
            }
        )

        let pixels = try Pixels(composed)
        XCTAssertTrue(pixels.isRed(x: 200, y: 400), "the asset was not baked in")
        XCTAssertTrue(pixels.isBlue(x: 20, y: 20), "the asset covered pixels it does not occupy")
    }

    /// Decoration under launchers: a picture must never cover the thing that
    /// answers a tap, whatever order they were added in.
    func testATileDrawsOverAnAssetInTheSamePlace() throws {
        let base = try Self.solid(red: 0, green: 0, blue: 1, size: screen)
        let centre = CGPoint(x: 200, y: 400)
        let asset = PlacedAsset(
            fileName: "sticker.png",
            center: centre,
            size: CGSize(width: 200, height: 200)
        )

        let composed = WallpaperComposer.compose(
            frame: base,
            tiles: [skinnedTile(at: centre, size: 120)],
            assets: [asset],
            screenSize: screen,
            artwork: { _ in try? Self.solid(red: 0, green: 1, blue: 0, size: CGSize(width: 64, height: 64)) },
            assetArtwork: { _ in try? Self.solid(red: 1, green: 0, blue: 0, size: CGSize(width: 64, height: 64)) }
        )

        let pixels = try Pixels(composed)
        XCTAssertTrue(pixels.isGreen(x: 200, y: 400), "the asset was drawn over the tile")
        // Just outside the tile but inside the asset, the asset still shows.
        XCTAssertTrue(pixels.isRed(x: 200, y: 480))
    }
}
