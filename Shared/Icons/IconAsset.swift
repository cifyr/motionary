import CoreGraphics
import Foundation
import os

/// One icon from the Iconify catalogue, identified the way Iconify does.
struct IconAsset: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// Icon set, e.g. `simple-icons`.
    var prefix: String
    /// Icon name within the set, e.g. `spotify`.
    var name: String

    var id: String { "\(prefix):\(name)" }

    /// Filename-safe key for the rasterised copy in the shared container.
    var cacheKey: String { "\(prefix)__\(name)" }

    init(prefix: String, name: String) {
        self.prefix = prefix
        self.name = name
    }

    init?(id: String) {
        let parts = id.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        prefix = String(parts[0])
        name = String(parts[1])
    }
}

/// Rasterised icons live in the app group so the widget can draw them without
/// a network request, which extensions cannot make reliably anyway.
struct IconCache {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "IconCache")

    /// Big enough for the largest tile on a 3x screen without resampling.
    static let renderedSide: CGFloat = 256

    let root: URL

    init(store: DesignStore) throws {
        root = store.root.deletingLastPathComponent().appendingPathComponent("Icons", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: DesignStore.directoryAttributes)
    }

    func url(for icon: IconAsset) -> URL {
        root.appendingPathComponent("\(icon.cacheKey).png")
    }

    func isCached(_ icon: IconAsset) -> Bool {
        FileManager.default.fileExists(atPath: url(for: icon).path)
    }

    func store(_ image: CGImage, for icon: IconAsset) throws {
        let data = try FrameEncoder.pngData(image)
        try data.write(to: url(for: icon), options: DesignStore.writingOptions)
        Self.logger.info("cached \(icon.id, privacy: .public) (\(data.count) bytes)")
    }

    /// Icons referenced by no design are removed, so a long browse through the
    /// picker does not leave hundreds of PNGs behind.
    @discardableResult
    func prune(keeping designs: [DesignDocument]) -> Int {
        let live = Set(designs.flatMap { $0.tiles.compactMap(\.icon?.cacheKey) })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var removed = 0
        for file in files where file.hasSuffix(".png") {
            let key = String(file.dropLast(4))
            guard !live.contains(key) else { continue }
            try? FileManager.default.removeItem(at: root.appendingPathComponent(file))
            removed += 1
        }
        if removed > 0 { Self.logger.info("pruned \(removed) unused icons") }
        return removed
    }
}
