import CoreGraphics
import Foundation

/// Where a tile's artwork comes from, resolved once for everything that draws
/// one outside the editor.
///
/// A skin wins over a catalogue icon: it is the artwork someone chose, against a
/// default they did not. The bundling step and the wallpaper bake both go
/// through this, because the wallpaper completes tiles the widget cuts off at
/// its frame - and it can only do that if both are drawing the same picture.
struct TileArtwork {
    /// Rasterised catalogue icons in the shared container. Nil when the caller
    /// has no cache to offer, which leaves skins as the only source.
    let iconsFolder: URL?
    private let skins: SkinLibrary?

    init(iconsFolder: URL?) {
        self.iconsFolder = iconsFolder
        // A missing library is not fatal: tiles without skins still resolve.
        skins = try? SkinLibrary()
    }

    func url(for tile: PlacedTile) -> URL? {
        let candidate: URL?
        if let skin = tile.skin, let skins {
            candidate = skins.url(for: skin)
        } else if let icon = tile.icon, let iconsFolder {
            candidate = iconsFolder.appendingPathComponent("\(icon.cacheKey).png")
        } else {
            candidate = nil
        }
        guard let candidate, FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    func image(for tile: PlacedTile, maxPixelSize: Int = SkinLibrary.renderedSide) -> CGImage? {
        url(for: tile).flatMap { ImageLoader.load(at: $0, maxPixelSize: maxPixelSize) }
    }
}
