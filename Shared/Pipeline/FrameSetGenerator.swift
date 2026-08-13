import CoreGraphics
import Foundation
import os

/// Builds a design's animation as pictures instead of as fonts.
///
/// The font engine's frames are colour glyphs, and a font only draws in a
/// widget if it was in the extension's bundle at install time - which is why a
/// design has to be compiled on a Mac and installed. Pictures have no such
/// rule: a live timer mask gates an `Image` decoded from bytes that arrived
/// afterwards, measured on device and written up in
/// `docs/widget-animation-surface.md`. So a design built this way can be
/// delivered to an app that is already on a phone.
///
/// The price is the loop. One picture per lane means the whole animation is
/// `laneCount / fps` long - two seconds - where fifteen glyphs per lane stretch
/// the same lane cycle to thirty. This does not replace the font engine; it is
/// the body a design gets when it has to travel.
struct FrameSetGenerator {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "FrameSet")

    let store: DesignStore
    var tileArtwork: WallpaperComposer.ArtworkProvider = { _ in nil }
    var assetArtwork: WallpaperComposer.AssetProvider = { _ in nil }

    enum Stage: Equatable, Sendable {
        case decoding(progress: Double)
        case encoding(progress: Double)
        case writingFrames(completed: Int, total: Int)
        case writingWallpaper

        var label: String {
            switch self {
            case .decoding: "Reading the clip"
            case .encoding: "Encoding frames"
            case .writingFrames(let done, let total): "Writing frame \(done) of \(total)"
            case .writingWallpaper: "Composing the wallpaper"
            }
        }
    }

    /// The loop a picture-built design can hold, in frames.
    ///
    /// One frame per lane and one mask phase per lane: the stack is the loop.
    /// Taken from the design's own start frame at its own speed, so the motion
    /// runs at the speed it was authored at and the design is the first two
    /// seconds of its loop rather than all of it played fifteen times too fast.
    static func frameCount(for spec: TimerFontSpec) -> Int { spec.laneCount }

    static func loopDuration(for spec: TimerFontSpec) -> TimeInterval {
        Double(frameCount(for: spec)) / Double(spec.framesPerSecond)
    }

    /// Crops, tints, edge-corrects and encodes, shrinking a frame first when it
    /// is over the renderer's pixel-area cap.
    ///
    /// Over that cap the render is dropped rather than refused: the frame comes
    /// out blank and the widget looks broken with nothing logged anywhere. On
    /// the calibrated phone a crop cannot reach it - the widget frame is 1.75M
    /// px against a cap around 2.1M - so this is what keeps that true on a
    /// device whose frame is larger.
    private func encode(
        frames: [CGImage],
        design: DesignDocument,
        crop: CGRect,
        quality: Double
    ) throws -> [Data] {
        let encoder = FrameEncoder(crop: crop, quality: quality, widgetRect: design.widgetRect)
        let scale = FramePayloadPlan.scale(for: crop.size)
        guard scale < 1 else { return try encoder.frameData(frames) }

        Self.logger.warning("""
        a \(Int(crop.width))x\(Int(crop.height)) frame is over the renderer's pixel cap; \
        shrinking by \(Int(scale * 100))%
        """)
        let longest = Int(max(crop.width, crop.height) * scale)
        return try encoder.frameData(frames).map { data in
            guard let shrunk = ImageLoader.load(data: data, maxPixelSize: longest),
                  let reduced = FrameEncoder.jpegData(shrunk, quality: quality)
            else { return data }
            return reduced
        }
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
        // Never more than the design's own loop: a clip with six frames in it
        // has six, and asking the extractor for the whole stack fails the build
        // rather than producing a short loop. The lanes repeat around whatever
        // arrives, which plays that loop several times per cycle at the speed
        // it was authored at - the lane cycle is fixed either way.
        let count = max(1, min(design.loopFrameCount, Self.frameCount(for: spec)))

        Self.logger.info("""
        frame build design=\(design.id.uuidString, privacy: .public) frames=\(count) \
        fps=\(spec.framesPerSecond) crop=\(String(describing: crop), privacy: .public)
        """)
        // Not an error, the same way an ill-fitting loop is not one for the
        // fonts: it costs one jump per lane cycle at the wrap, which is often
        // invisible. Say so and carry on rather than refusing to build.
        if !spec.laneCount.isMultiple(of: count) {
            Self.logger.warning(
                "\(count) frames do not divide \(spec.laneCount) lanes; the loop will jump once per cycle"
            )
        }

        try store.clearFrames(for: design.id)

        onStage(.decoding(progress: 0))
        let extractor = MediaFrameExtractor(
            url: store.sourceVideoURL(for: design),
            transform: design.mediaTransform,
            background: design.backgroundName.flatMap {
                ImageLoader.load(
                    at: store.backgroundURL(for: design.id, name: $0),
                    maxPixelSize: Int(max(
                        DeviceGeometry.screenPixelSize.width,
                        DeviceGeometry.screenPixelSize.height
                    ))
                )
            },
            clipRect: design.backgroundName == nil ? nil : design.widgetRect,
            clipCornerRadius: design.effectiveCornerRadius
        )
        let frames = try await extractor.composedFrames(
            startFrame: design.loopStartFrame,
            count: count,
            frameRate: spec.framesPerSecond,
            speed: design.playbackSpeed,
            progress: { onStage(.decoding(progress: $0)) }
        )
        guard let first = frames.first else {
            throw GeneratorError.emptyCrop(design: design.name)
        }

        onStage(.encoding(progress: 0))
        // Not `design.jpegQuality`: that was chosen to fit a font payload,
        // where one frame is base64'd into every one of `lanes x 15` glyph
        // selections. Written once, the same frames have several times the
        // budget - see FramePayloadPlan.
        var quality = FramePayloadPlan.bestQuality
        var data = try encode(frames: frames, design: design, crop: crop, quality: quality)
        while let lower = FramePayloadPlan.retry(
            totalBytes: data.reduce(0) { $0 + $1.count },
            at: quality
        ) {
            Self.logger.info("""
            frame set is \(data.reduce(0) { $0 + $1.count } / 1_048_576)MB at quality \
            \(Int(quality * 100))%; trying \(Int(lower * 100))%
            """)
            quality = lower
            data = try encode(frames: frames, design: design, crop: crop, quality: quality)
            try Task.checkCancellation()
        }
        onStage(.encoding(progress: 1))

        var totalBytes = 0
        for (index, frame) in data.enumerated() {
            onStage(.writingFrames(completed: index, total: data.count))
            let url = store.frameURL(for: design.id, index: index)
            do {
                try frame.write(to: url, options: DesignStore.writingOptions)
            } catch {
                throw GeneratorError.laneWriteFailed(lane: index, path: url.path, underlying: error)
            }
            totalBytes += frame.count
            try Task.checkCancellation()
            await Task.yield()
        }
        onStage(.writingFrames(completed: data.count, total: data.count))

        onStage(.writingWallpaper)
        let backdropRect = try await DesignArtWriter(
            store: store,
            tileArtwork: tileArtwork,
            assetArtwork: assetArtwork
        ).write(design: design, poster: first)

        let manifest = BuildManifest(
            designID: design.id,
            buildGeneration: design.buildGeneration + 1,
            fontFamilyBase: design.fontFamilyBase,
            laneCount: spec.laneCount,
            framesPerSecond: spec.framesPerSecond,
            loopFrameCount: data.count,
            animationCrop: crop,
            widgetRect: design.widgetRect,
            screenSize: DeviceGeometry.screenPixelSize,
            wallpaperName: store.wallpaperURL(for: design.id).lastPathComponent,
            totalFontBytes: totalBytes,
            builtAt: Date(),
            backdropRect: backdropRect,
            frameCount: data.count,
            tiles: design.tiles,
            assets: design.assets,
            readouts: design.readouts
        )
        try store.save(manifest)
        Self.logger.info("""
        frame build done design=\(design.id.uuidString, privacy: .public) \
        frames=\(data.count) bytes=\(totalBytes)
        """)
        return manifest
    }
}
