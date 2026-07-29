import SwiftUI
import UIKit
import os

/// Reads rasterised icons out of the shared cache.
///
/// Both the app and the widget draw tiles, and neither should touch the network
/// at draw time, so this only ever looks at disk. A miss falls back to the
/// catalogue's SF Symbol rather than blocking the render.
@MainActor
final class IconImageLoader: ObservableObject {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "IconLoader")

    private let cache: IconCache?
    private var images: [String: Image] = [:]

    init(store: DesignStore?) {
        cache = store.flatMap { try? IconCache(store: $0) }
        if cache == nil {
            Self.logger.error("icon cache unavailable; tiles will fall back to symbols")
        }
    }

    func image(for tile: PlacedTile) -> Image? {
        guard let icon = tile.icon else { return nil }
        return image(for: icon)
    }

    func image(for icon: IconAsset) -> Image? {
        if let cached = images[icon.id] { return cached }
        guard let cache, let uiImage = UIImage(contentsOfFile: cache.url(for: icon).path) else {
            return nil
        }
        let image = Image(uiImage: uiImage)
        images[icon.id] = image
        return image
    }

    /// Called after a rebuild so a replaced icon is not served from memory.
    func forget(_ icon: IconAsset) {
        images[icon.id] = nil
    }
}

/// Non-observable variant for the widget, which builds its view tree once and
/// has no need to publish changes.
struct IconImageProvider {
    private let cache: IconCache?

    init(store: DesignStore?) {
        cache = store.flatMap { try? IconCache(store: $0) }
    }

    func image(for tile: PlacedTile) -> Image? {
        guard let icon = tile.icon, let cache,
              let uiImage = UIImage(contentsOfFile: cache.url(for: icon).path)
        else { return nil }
        return Image(uiImage: uiImage)
    }
}
