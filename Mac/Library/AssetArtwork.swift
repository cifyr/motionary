import CoreGraphics
import Foundation
import ImageIO
import os

/// Loads a design's placed picture and applies its keying.
///
/// Keying happens here, on the way to being drawn, rather than at import: the
/// file on disk stays exactly what was dropped in, so a key can be retuned or
/// switched off at any point without reimporting.
enum AssetArtwork {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "AssetArtwork")

    /// Keyed results are cached by asset id and settings, because the editor
    /// asks for the same picture on every redraw and keying a large image on
    /// each one makes dragging it feel broken.
    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        private var entries: [String: CGImage] = [:]
        private let lock = NSLock()

        func value(for key: String) -> CGImage? {
            lock.lock()
            defer { lock.unlock() }
            return entries[key]
        }

        func set(_ image: CGImage, for key: String) {
            lock.lock()
            defer { lock.unlock() }
            // Bounded: a design with hundreds of assets should not pin every
            // keyed copy in memory for the life of the process.
            if entries.count > 64 { entries.removeAll() }
            entries[key] = image
        }
    }

    static func image(for asset: PlacedAsset, designID: UUID, store: DesignStore) -> CGImage? {
        let url = store.assetURL(for: designID, name: asset.fileName)
        let key = cacheKey(for: asset)
        if let cached = cache.value(for: key) { return cached }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let loaded = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            logger.error("could not read asset \(asset.fileName, privacy: .public) at \(url.path, privacy: .public)")
            return nil
        }

        let result: CGImage
        if let settings = asset.chroma, settings.enabled {
            result = ChromaKey.apply(to: loaded, settings: settings) ?? loaded
        } else {
            result = loaded
        }

        cache.set(result, for: key)
        return result
    }

    /// Reads the colour under a point in the asset's own pixels, for picking a
    /// key by eye. Coordinates are unit-space so a caller can hand over a tap
    /// in the editor without knowing the file's resolution.
    static func sampleColor(
        in asset: PlacedAsset,
        designID: UUID,
        store: DesignStore,
        at unitPoint: CGPoint
    ) -> ChromaKey.RGB? {
        let url = store.assetURL(for: designID, name: asset.fileName)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let x = Int((unitPoint.x * CGFloat(image.width)).rounded())
        let y = Int((unitPoint.y * CGFloat(image.height)).rounded())
        guard (0 ..< image.width).contains(x), (0 ..< image.height).contains(y) else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(
            x: -CGFloat(x), y: -CGFloat(image.height - 1 - y),
            width: CGFloat(image.width), height: CGFloat(image.height)
        ))

        let alpha = Double(pixel[3]) / 255
        guard alpha > 0 else { return nil }
        // Un-premultiply, so a sampled edge pixel reports its own colour.
        return ChromaKey.RGB(
            r: Double(pixel[0]) / 255 / alpha,
            g: Double(pixel[1]) / 255 / alpha,
            b: Double(pixel[2]) / 255 / alpha
        )
    }

    private static func cacheKey(for asset: PlacedAsset) -> String {
        guard let chroma = asset.chroma else { return "\(asset.id.uuidString):none" }
        return [
            asset.id.uuidString,
            chroma.enabled ? "on" : "off",
            String(format: "%.3f", chroma.tolerance),
            String(format: "%.3f", chroma.softness),
            String(format: "%.3f", chroma.spill),
            chroma.keyColor.map { String(format: "%.3f,%.3f,%.3f", $0.r, $0.g, $0.b) } ?? "auto",
        ].joined(separator: ":")
    }
}
