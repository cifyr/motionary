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
    /// Already keyed, so the composer never has to know about `ChromaKey`.
    typealias AssetProvider = @Sendable (PlacedAsset) -> CGImage?

    @MainActor
    static func compose(
        frame: CGImage,
        tiles: [PlacedTile],
        assets: [PlacedAsset] = [],
        screenSize: CGSize,
        artwork: @escaping ArtworkProvider = { _ in nil },
        assetArtwork: @escaping AssetProvider = { _ in nil }
    ) -> CGImage {
        guard !tiles.isEmpty || !assets.isEmpty else { return frame }

        let layer = TileLayer(
            tiles: tiles,
            assets: assets.sorted { $0.zIndex < $1.zIndex },
            screenSize: screenSize,
            artwork: { artwork($0).map { Image(decorative: $0, scale: 1) } },
            assetArtwork: { assetArtwork($0).map { Image(decorative: $0, scale: 1) } }
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
        logger.info("baked \(tiles.count) tiles and \(assets.count) assets into the wallpaper")
        return composed
    }

    /// The composed wallpaper at the size the screen it is going onto actually
    /// is.
    ///
    /// A design is authored on one canvas - whatever the studio was cut for -
    /// and `DeviceModel.derived` puts it on another phone by scaling x with the
    /// width and y with the height. Doing the same two things to the picture is
    /// what keeps the baked tiles under the widget frame that gets drawn over
    /// them.
    ///
    /// Deliberately not an aspect-preserving fit. A fit would letterbox or
    /// crop, and either one slides the artwork out from under the icons it was
    /// drawn for - which is the single thing this bake exists to prevent. Every
    /// iPhone that can run this is within a percent of the same aspect ratio,
    /// so the distortion the honest transform costs is not visible.
    static func rescaled(_ image: CGImage, to size: CGSize) -> CGImage {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0 else {
            logger.error("asked for a \(Int(size.width))x\(Int(size.height)) wallpaper; keeping \(image.width)x\(image.height)")
            return image
        }
        guard width != image.width || height != image.height else { return image }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            logger.error("no bitmap context for \(width)x\(height); the wallpaper ships at \(image.width)x\(image.height)")
            return image
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

        guard let scaled = context.makeImage() else {
            logger.error("rescaled wallpaper could not be read back; shipping it at \(image.width)x\(image.height)")
            return image
        }
        logger.info("wallpaper rescaled from \(image.width)x\(image.height) to \(width)x\(height) for this screen")
        return scaled
    }
}

/// The tiles and assets alone, on nothing, positioned the way `CompositionView`
/// positions them - from `rect` in screen pixels, at one point per pixel.
private struct TileLayer: View {
    let tiles: [PlacedTile]
    /// Pre-sorted by `zIndex`.
    let assets: [PlacedAsset]
    let screenSize: CGSize
    let artwork: (PlacedTile) -> Image?
    let assetArtwork: (PlacedAsset) -> Image?

    var body: some View {
        // An overlay cannot enlarge its base, so a tile bigger than the screen
        // or hanging off an edge cannot grow the canvas and drag every other
        // tile out of place with it.
        Color.clear
            .frame(width: screenSize.width, height: screenSize.height)
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: screenSize.width, height: screenSize.height)
                    // Assets first: decoration sits under the launchers, so a
                    // picture can never cover the thing that answers a tap.
                    ForEach(assets) { asset in
                        if let image = assetArtwork(asset) {
                            image
                                .resizable()
                                .frame(width: asset.size.width, height: asset.size.height)
                                .rotationEffect(.degrees(asset.rotation))
                                .opacity(asset.opacity)
                                .offset(x: asset.rect.minX, y: asset.rect.minY)
                        }
                    }
                    ForEach(tiles) { tile in
                        TileView(tile: tile, side: tile.size, iconImage: artwork(tile))
                            .frame(width: tile.size, height: tile.size)
                            .offset(x: tile.rect.minX, y: tile.rect.minY)
                    }
                }
            }
    }
}
