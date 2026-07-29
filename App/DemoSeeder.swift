#if DEBUG
import CoreGraphics
import Foundation
import os

/// Debug-only entry point that builds a design from a video dropped into the
/// app group root, so the whole pipeline can be exercised without driving the
/// photo picker by hand.
///
/// Copy a clip to `<group>/demo-source.mov`, then launch with the seed flag:
/// `xcrun simctl launch booted com.caden.Motionary -MotionaryDemoSeed 1`.
/// A launch argument rather than a URL, because an externally opened URL raises
/// a system confirmation dialog that cannot be answered from the command line.
enum DemoSeeder {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "Demo")
    static let sourceName = "demo-source.mov"
    private static let launchFlag = "-MotionaryDemoSeed"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchFlag)
    }

    /// Exercises the whole icon path: fetch from Iconify, rasterise locally,
    /// cache into the app group, and reference it from the tiles.
    private static let demoIcons = [
        "spotify": "simple-icons:spotify",
        "settings": "material-symbols:settings",
        "gmaps": "simple-icons:googlemaps",
        "clock": "material-symbols:schedule",
    ]

    private static func attachIcons(to design: inout DesignDocument, store: DesignStore) async {
        guard let cache = try? IconCache(store: store) else { return }
        let service = IconifyService()
        for index in design.tiles.indices {
            guard design.tiles[index].icon == nil,
                  let id = demoIcons[design.tiles[index].appID],
                  let icon = IconAsset(id: id)
            else { continue }
            do {
                if !cache.isCached(icon) {
                    let body = try await service.body(for: icon)
                    let image = try SVGIconRenderer(
                        viewBox: body.viewBox,
                        tint: CGColor(red: 1, green: 1, blue: 1, alpha: 1)
                    ).image(body: body.body, side: IconCache.renderedSide)
                    try cache.store(image, for: icon)
                }
                design.tiles[index].icon = icon
                logger.info("DEMO ICON \(icon.id, privacy: .public) attached")
            } catch {
                logger.error("demo icon \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        try? store.save(design)
    }

    enum Outcome {
        case success(BuildManifest)
        case failure(String)
    }

    static func run(store: DesignStore) async -> Outcome {
        // Reuse an already-built demo so repeated launches exercise the render
        // path without paying for a full regeneration each time.
        if var existing = store.loadAll().first(where: { $0.name == "Demo" }),
           let manifest = try? store.loadManifest(id: existing.id) {
            logger.info("reusing demo design \(existing.id.uuidString, privacy: .public)")
            await attachIcons(to: &existing, store: store)
            let report = RuntimeFontRegistry.register(manifest: manifest, store: store)
            logger.info("DEMO REUSE lanes=\(report.resolvable)/\(report.requested) usable=\(report.isUsable)")
            return .success(manifest)
        }

        let source = store.root.deletingLastPathComponent().appendingPathComponent(sourceName)
        guard FileManager.default.fileExists(atPath: source.path) else {
            return .failure("no demo clip at \(source.path)")
        }

        do {
            var design = DesignDocument.new(name: "Demo", sourceVideoName: "source.mov")
            design.widgetSize = .large
            design.smoothness = .light
            try store.createFolder(for: design.id)
            try FileManager.default.copyItem(at: source, to: store.sourceVideoURL(for: design))

            let extractor = VideoFrameExtractor(url: store.sourceVideoURL(for: design))
            let summary = try await extractor.summary()
            let available = max(1, min(summary.frameCount - 1, 32))
            design.loopFrameCount = design.spec.seamlessLoopLengths(maximum: available).last ?? 1

            let sample = try await extractor.composedFrames(startFrame: 0, count: min(8, design.loopFrameCount))
            let detection = MotionCropDetector().detect(frames: sample, screenSize: DeviceGeometry.screenPixelSize)
            design.animationCrop = detection.crop.isEmpty
                ? CGRect(origin: .zero, size: DeviceGeometry.screenPixelSize)
                : detection.crop

            design.tiles = [
                PlacedTile(appID: "spotify", center: CGPoint(x: 210, y: 460), size: 190),
                PlacedTile(appID: "settings", center: CGPoint(x: 990, y: 460), size: 190),
                PlacedTile(appID: "gmaps", center: CGPoint(x: 210, y: 900), size: 190),
                PlacedTile(appID: "clock", center: CGPoint(x: 990, y: 900), size: 190),
            ]
            try store.save(design)

            let manifest = try await FontSetGenerator(store: store).build(design: design) { stage in
                logger.info("demo \(stage.caption, privacy: .public)")
            }
            design.buildGeneration = manifest.buildGeneration
            await attachIcons(to: &design, store: store)
            try store.save(design)

            let report = RuntimeFontRegistry.register(manifest: manifest, store: store)
            logger.info("""
            DEMO RESULT design=\(design.id.uuidString, privacy: .public) \
            bytes=\(manifest.totalFontBytes) \
            lanes=\(report.resolvable)/\(report.requested) usable=\(report.isUsable)
            """)
            return .success(manifest)
        } catch {
            logger.error("demo failed: \(String(describing: error), privacy: .public)")
            return .failure(String(describing: error))
        }
    }
}
#endif
