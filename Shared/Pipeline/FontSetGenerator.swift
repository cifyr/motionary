import CoreGraphics
import Foundation
import os

enum GeneratorError: Error, CustomStringConvertible {
    case templateMissing(name: String)
    case emptyCrop(design: String)
    case loopDoesNotDivideCycle(loopFrames: Int, totalFrames: Int)
    case payloadTooLarge(estimated: Int, limit: Int)
    case laneWriteFailed(lane: Int, path: String, underlying: Error)

    var description: String {
        switch self {
        case .templateMissing(let name):
            "generate: shaping template \(name) is missing from the bundle"
        case .emptyCrop(let design):
            "generate: design \"\(design)\" has no animated area inside its widget frame. "
                + "Tap Reset animated area under Quality, then build again."
        case .loopDoesNotDivideCycle(let loop, let total):
            "generate: a \(loop)-frame loop does not divide the \(total)-selection cycle, so the wrap would visibly cut"
        case .payloadTooLarge(let estimated, let limit):
            "generate: estimated payload \(estimated) bytes exceeds the \(limit)-byte hard limit; shrink the crop or lower quality"
        case .laneWriteFailed(let lane, let path, let underlying):
            "generate: could not write lane \(lane) to \(path): \(underlying)"
        }
    }
}

/// Builds a design's lane fonts and wallpaper into the shared container.
struct FontSetGenerator {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "Generator")

    static let templateResourceName = "MotionTemplate-Regular"
    static let blinkFontResourceName = "Custom-Regular"

    enum Stage: Equatable, Sendable {
        case decoding(progress: Double)
        case analysing
        case encoding(progress: Double)
        case writingFonts(completed: Int, total: Int)
        case writingWallpaper
        case done(manifest: BuildManifest)

        var caption: String {
            switch self {
            case .decoding: "Decoding video"
            case .analysing: "Measuring motion"
            case .encoding: "Encoding frames"
            case .writingFonts(let completed, let total): "Building fonts (\(completed)/\(total))"
            case .writingWallpaper: "Saving wallpaper"
            case .done: "Done"
            }
        }

        var fraction: Double {
            switch self {
            case .decoding(let progress): 0.05 + progress * 0.20
            case .analysing: 0.28
            case .encoding(let progress): 0.30 + progress * 0.15
            case .writingFonts(let completed, let total):
                0.45 + (total > 0 ? Double(completed) / Double(total) : 0) * 0.50
            case .writingWallpaper: 0.97
            case .done: 1
            }
        }
    }

    let store: DesignStore
    let bundle: Bundle

    init(store: DesignStore, bundle: Bundle = .main) {
        self.store = store
        self.bundle = bundle
    }

    func build(
        design: DesignDocument,
        onStage: @Sendable @escaping (Stage) -> Void
    ) async throws -> BuildManifest {
        let spec = design.spec
        let crop = design.effectiveCrop
        guard crop.width >= 2, crop.height >= 2 else {
            throw GeneratorError.emptyCrop(design: design.name)
        }
        // A loop that does not divide the cycle is not an error: it costs one
        // jump every 30 seconds at the wrap, which is often invisible. Say so
        // and carry on rather than refusing to build.
        if !spec.divides(loopFrameCount: design.loopFrameCount) {
            Self.logger.warning(
                "loop of \(design.loopFrameCount) does not divide \(spec.totalFrames); the 30s wrap will jump"
            )
        }
        guard let templateURL = bundle.url(forResource: Self.templateResourceName, withExtension: "ttf") else {
            throw GeneratorError.templateMissing(name: Self.templateResourceName)
        }

        Self.logger.info("""
        build start design=\(design.id.uuidString, privacy: .public) \
        lanes=\(spec.laneCount) loop=\(design.loopFrameCount) \
        crop=\(String(describing: crop), privacy: .public) quality=\(design.jpegQuality)
        """)

        onStage(.decoding(progress: 0))
        let extractor = MediaFrameExtractor(
            url: store.sourceVideoURL(for: design),
            transform: design.mediaTransform,
            background: design.backgroundName.flatMap {
                ImageLoader.load(
                    at: store.backgroundURL(for: design.id, name: $0),
                    maxPixelSize: Int(max(DeviceGeometry.screenPixelSize.width, DeviceGeometry.screenPixelSize.height))
                )
            },
            clipRect: design.backgroundName == nil ? nil : design.widgetRect,
            clipCornerRadius: design.effectiveCornerRadius
        )
        let frames = try await extractor.composedFrames(
            startFrame: design.loopStartFrame,
            count: design.loopFrameCount,
            frameRate: spec.framesPerSecond,
            speed: design.playbackSpeed,
            progress: { onStage(.decoding(progress: $0)) }
        )

        onStage(.analysing)
        let encoder = FrameEncoder(crop: crop, quality: design.jpegQuality)

        onStage(.encoding(progress: 0))
        let encodedFrames = try encoder.encodedFrames(frames)
        // base64 costs 4 characters per 3 source bytes; recover the JPEG size.
        let base64Characters: Int = encodedFrames.reduce(into: 0) { total, frame in
            total += frame.count
        }
        let decodedBytes: Int = base64Characters * 3 / 4
        let averageBytes: Int = decodedBytes / max(1, encodedFrames.count)
        let budget = PayloadBudget(spec: spec, averageEncodedFrameBytes: averageBytes)
        guard !budget.exceedsHardLimit else {
            throw GeneratorError.payloadTooLarge(
                estimated: budget.estimatedTotalBytes,
                limit: PayloadBudget.hardMaximumBytes
            )
        }
        onStage(.encoding(progress: 1))

        let builder = try LaneFontBuilder(
            templateData: try Data(contentsOf: templateURL),
            spec: spec,
            factory: SVGGlyphFactory(cropRect: crop, screenSize: DeviceGeometry.screenPixelSize)
        )

        try store.clearFonts(for: design.id)
        var totalBytes = 0
        for lane in 0 ..< spec.laneCount {
            onStage(.writingFonts(completed: lane, total: spec.laneCount))
            let url = store.fontURL(for: design.id, familyBase: design.fontFamilyBase, lane: lane)
            do {
                let data = try builder.font(
                    lane: lane,
                    familyBase: design.fontFamilyBase,
                    encodedFrames: encodedFrames
                )
                try data.write(to: url, options: DesignStore.writingOptions)
                totalBytes += data.count
            } catch {
                throw GeneratorError.laneWriteFailed(lane: lane, path: url.path, underlying: error)
            }
            // 64 multi-megabyte writes would otherwise starve the UI entirely.
            await Task.yield()
        }
        onStage(.writingFonts(completed: spec.laneCount, total: spec.laneCount))

        onStage(.writingWallpaper)
        let wallpaper = try FrameEncoder.pngData(frames[0])
        try wallpaper.write(to: store.wallpaperURL(for: design.id), options: DesignStore.writingOptions)

        // The full screen costs about 12.6MB decompressed and the widget only
        // ever shows its own frame. On this phone the extension peaked at
        // 46.7MB against a working reference of 43.3MB and its render was
        // dropped, which is what a black widget looks like from outside.
        //
        // Padded, because the system hands over 359x548pt where the
        // calibration says 358x544: cropping to the exact frame would leave a
        // few unpainted pixels down the right and bottom edges.
        let padding: CGFloat = 24
        let backdropRect = design.widgetRect
            .insetBy(dx: -padding, dy: -padding)
            .intersection(CGRect(origin: .zero, size: DeviceGeometry.screenPixelSize))
            .integral
        var bakedBackdrop: CGRect?
        if !backdropRect.isNull, let cropped = frames[0].cropping(to: backdropRect) {
            let data = try FrameEncoder.jpegData(cropped, quality: 0.9)
                ?? FrameEncoder.pngData(cropped)
            try data.write(to: store.widgetBackdropURL(for: design.id), options: DesignStore.writingOptions)
            bakedBackdrop = backdropRect
            Self.logger.info("""
            widget backdrop \(Int(backdropRect.width))x\(Int(backdropRect.height)), \
            \(data.count) bytes, saving \
            \(Int((DeviceGeometry.screenPixelSize.width * DeviceGeometry.screenPixelSize.height
                - backdropRect.width * backdropRect.height) * 4 / 1_000_000))MB when decoded
            """)
        }

        // The in-app preview plays this rather than the lane fonts: only the
        // system widget renderer advances timer text fast enough for those.
        try await PreviewVideoWriter(
            size: DeviceGeometry.screenPixelSize,
            framesPerSecond: spec.framesPerSecond
        ).write(frames: frames, to: store.previewVideoURL(for: design.id))

        let manifest = BuildManifest(
            designID: design.id,
            buildGeneration: design.buildGeneration + 1,
            fontFamilyBase: design.fontFamilyBase,
            laneCount: spec.laneCount,
            framesPerSecond: spec.framesPerSecond,
            loopFrameCount: design.loopFrameCount,
            animationCrop: crop,
            widgetRect: design.widgetRect,
            screenSize: DeviceGeometry.screenPixelSize,
            wallpaperName: "wallpaper.png",
            totalFontBytes: totalBytes,
            builtAt: Date(),
            backdropRect: bakedBackdrop,
            tiles: design.tiles
        )
        try store.save(manifest)

        Self.logger.info("""
        build done design=\(design.id.uuidString, privacy: .public) \
        bytes=\(totalBytes) estimated=\(budget.estimatedTotalBytes)
        """)
        onStage(.done(manifest: manifest))
        return manifest
    }
}
