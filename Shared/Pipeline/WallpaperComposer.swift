import CoreGraphics
import SwiftUI
import os

/// Bakes the placed app tiles into the still wallpaper.
///
/// The widget draws the tiles, and it can only draw inside its own frame, so a
/// tile that crosses that edge is cut off there. The wallpaper is the other
/// half: with the tiles baked in, a tile straddling the edge reads whole, and
/// the part that falls inside the frame is the part that answers a tap.
///
/// Only the wallpaper gets them. The widget's own baked backdrop must not, or
/// every tile inside the frame would be drawn twice - once as a picture and
/// once as the live, tappable tile over it.
enum WallpaperComposer {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "Wallpaper")

    /// Artwork for a tile, or nil to let it fall back to its SF Symbol exactly
    /// as the widget does when an icon is missing from the bundle.
    /// `@Sendable` because the bake happens on the main actor - `ImageRenderer`
    /// is main-actor-only - while the build that asks for it does not.
    typealias ArtworkProvider = @Sendable (PlacedTile) -> CGImage?

    @MainActor
    static func compose(
        frame: CGImage,
        tiles: [PlacedTile],
        screenSize: CGSize,
        artwork: @escaping ArtworkProvider = { _ in nil }
    ) -> CGImage {
        guard !tiles.isEmpty else { return frame }

        let layer = TileLayer(
            tiles: tiles,
            screenSize: screenSize,
            artwork: { artwork($0).map { Image(decorative: $0, scale: 1) } }
        )
        // Laid out at one point per screen pixel, so the tile geometry the
        // widget expresses in points at 3x lands on the same pixels here.
        let renderer = ImageRenderer(content: layer.environment(\.displayScale, 1))
        renderer.scale = 1
        renderer.isOpaque = false

        guard let overlay = renderer.cgImage else {
            logger.error("tile layer did not rasterise; the wallpaper ships without its \(tiles.count) tiles")
            return frame
        }

        // Same recipe as the compositor that produced this frame, so redrawing
        // it does not shift its colours.
        guard let context = CGContext(
            data: nil,
            width: Int(screenSize.width),
            height: Int(screenSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            logger.error("no bitmap context for \(Int(screenSize.width))x\(Int(screenSize.height)); wallpaper ships without tiles")
            return frame
        }

        let bounds = CGRect(origin: .zero, size: screenSize)
        context.interpolationQuality = .high
        context.draw(frame, in: bounds)
        context.draw(overlay, in: bounds)

        guard let composed = context.makeImage() else {
            logger.error("composed wallpaper could not be read back; shipping the untiled frame")
            return frame
        }
        logger.info("baked \(tiles.count) tiles into the wallpaper")
        return composed
    }
}

/// The tiles alone, on nothing, positioned the way `CompositionView` positions
/// them - from `tile.rect` in screen pixels, at one point per pixel.
private struct TileLayer: View {
    let tiles: [PlacedTile]
    let screenSize: CGSize
    let artwork: (PlacedTile) -> Image?

    var body: some View {
        // An overlay cannot enlarge its base, so a tile bigger than the screen
        // or hanging off an edge cannot grow the canvas and drag every other
        // tile out of place with it.
        Color.clear
            .frame(width: screenSize.width, height: screenSize.height)
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: screenSize.width, height: screenSize.height)
                    ForEach(tiles) { tile in
                        TileView(tile: tile, side: tile.size, iconImage: artwork(tile))
                            .frame(width: tile.size, height: tile.size)
                            .offset(x: tile.rect.minX, y: tile.rect.minY)
                    }
                }
            }
    }
}
