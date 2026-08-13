import CoreGraphics
import Foundation
import os

enum GeneratorError: Error, CustomStringConvertible {
    case templateMissing(name: String)
    case emptyCrop(design: String)
    case loopDoesNotDivideCycle(loopFrames: Int, totalFrames: Int)
    case payloadTooLarge(estimated: Int, limit: Int)
    case laneWriteFailed(lane: Int, path: String, underlying: Error)
    case variantFailed(name: String, underlying: Error)
    case clipProgramImpossible

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
        case .variantFailed(let name, let underlying):
            "generate: variant \"\(name)\" failed: \(underlying)"
        case .clipProgramImpossible:
            "generate: these complete clip lengths cannot fill the animation cycle without cutting or immediately repeating a clip"
        }
    }
}

/// Builds a design's lane fonts and wallpaper into the shared container.
struct FontSetGenerator {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "Generator")

    static let templateResourceName = "MotionTemplate-Regular"
    static let blinkFontResourceName = "Custom-Regular"

    /// Blink masks with longer periods, for designs whose frames are pictures.
    ///
    /// The shipped mask keys on the timer's seconds and is solid on even ones,
    /// so it repeats every two seconds - which is exactly why a picture-built
    /// design could only be two seconds long. These are solid one second in
    /// four, six, ten and thirty, so a design's loop can be any of those.
    /// Verified in the mask lab: ten cards gated a second apart step through
    /// ten distinct cards in order and wrap.
    ///
    /// Made by `Tools/blink-font.py`, which rewrites the substitution table of
    /// the font above without changing its length. The period has to divide 60
    /// because the substitution keys on the seconds digits, and thirty is the
    /// longest useful one: the timer reference is anchored to a thirty-second
    /// cycle, so a longer mask would not repeat with the picture.
    static let blinkPeriods: [(seconds: Int, resource: String)] = [
        (4, "Blnk04-Regular"),
        (6, "Blnk06-Regular"),
        (10, "Blnk10-Regular"),
        (30, "Blnk30-Regular"),
    ]

    /// The shortest mask that covers a clip, because every second of period
    /// costs `framesPerSecond` more pictures whether the clip fills them or
    /// not - the stack has to cover the whole cycle or the widget goes black
    /// for the seconds nothing was drawn into.
    static func blinkPeriod(covering seconds: TimeInterval) -> (seconds: Int, resource: String) {
        blinkPeriods.first { Double($0.seconds) >= seconds - 0.001 } ?? blinkPeriods[blinkPeriods.count - 1]
    }

    static func blinkResource(forPeriod seconds: Int) -> String? {
        blinkPeriods.first { $0.seconds == seconds }?.resource
    }

    enum Stage: Equatable, Sendable {
        case decoding(progress: Double)
        case analysing
        case encoding(progress: Double)
        case writingFonts(completed: Int, total: Int)
        case writingWallpaper
        /// The stages after this repeat per variant; the name is what says
        /// which clip the restarted progress belongs to.
        case buildingVariant(name: String)
        case done(manifest: BuildManifest)

        var caption: String {
            switch self {
            case .decoding: "Decoding video"
            case .analysing: "Measuring motion"
            case .encoding: "Encoding frames"
            case .writingFonts(let completed, let total): "Building fonts (\(completed)/\(total))"
            case .writingWallpaper: "Saving wallpaper"
            case .buildingVariant(let name): "Building variant \"\(name)\""
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
            case .buildingVariant: 0.02
            case .done: 1
            }
        }
    }

    let store: DesignStore
    let bundle: Bundle
    /// Artwork for a tile, so the icons baked into the wallpaper are the same
    /// ones the widget draws over it. Whoever owns the skin library and the icon
    /// cache supplies it; the default bakes SF Symbol fallbacks.
    let tileArtwork: WallpaperComposer.ArtworkProvider

    /// Keyed artwork for a placed picture. Supplied by the caller for the same
    /// reason `tileArtwork` is: reading and keying the file belongs to whoever
    /// owns the store, not to the generator.
    let assetArtwork: WallpaperComposer.AssetProvider

    init(
        store: DesignStore,
        bundle: Bundle = .main,
        tileArtwork: @escaping WallpaperComposer.ArtworkProvider = { _ in nil },
        assetArtwork: @escaping WallpaperComposer.AssetProvider = { _ in nil }
    ) {
        self.store = store
        self.bundle = bundle
        self.tileArtwork = tileArtwork
        self.assetArtwork = assetArtwork
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
        lanes=\(spec.laneCount) loop=\(design.loopFrameCount) variants=\(design.variants.count) \
        crop=\(String(describing: crop), privacy: .public) quality=\(design.jpegQuality)
        """)

        // Once for the whole design, not per clip: every variant's lanes land
        // in this folder, and clearing between clips would delete the set the
        // previous one just wrote.
        try store.clearFonts(for: design.id)

        let clipCount = design.variants.count + 1
        let shuffledFrameCount: Int? = design.clipPlaybackMode == .shuffled && clipCount > 1
            && spec.totalFrames.isMultiple(of: clipCount)
            ? spec.totalFrames / clipCount
            : nil
        if design.clipPlaybackMode == .shuffled, clipCount > 1, shuffledFrameCount == nil {
            throw GeneratorError.clipProgramImpossible
        }

        // The primary clip is the default variant, and the only one that
        // writes the wallpapers - variants differ inside the widget frame, and
        // the wallpaper is everything outside it.
        let primary = try await buildClip(
            design: design,
            spec: spec,
            crop: crop,
            templateURL: templateURL,
            source: store.sourceVideoURL(for: design),
            familyBase: design.fontFamilyBase,
            variantID: nil,
            programFrameCount: shuffledFrameCount,
            onStage: onStage
        )

        var builtVariants: [BuildManifest.VariantBuild] = []
        var clipBuilds: [(id: UUID?, build: ClipBuild)] = [(nil, primary)]
        for variant in design.variants {
            try Task.checkCancellation()
            onStage(.buildingVariant(name: variant.name))
            do {
                let result = try await buildClip(
                    design: design,
                    spec: spec,
                    crop: crop,
                    templateURL: templateURL,
                    source: store.variantClipURL(for: design.id, name: variant.sourceVideoName),
                    familyBase: design.fontFamilyBase(for: variant),
                    variantID: variant.id,
                    programFrameCount: shuffledFrameCount,
                    onStage: onStage
                )
                builtVariants.append(.init(
                    id: variant.id,
                    name: variant.name,
                    fontFamilyBase: design.fontFamilyBase(for: variant),
                    totalFontBytes: result.totalBytes,
                    loopFrameCount: result.loopFrameCount
                ))
                clipBuilds.append((variant.id, result))
            } catch is CancellationError {
                // Rethrown bare: wrapped in `variantFailed` a stopped build
                // would be reported as a crash in whichever clip it reached.
                throw CancellationError()
            } catch {
                // Named, because five clips build in one run and "payload too
                // large" without a name points at the wrong one four times
                // out of five.
                throw GeneratorError.variantFailed(name: variant.name, underlying: error)
            }
        }

        var program: [ClipProgram.Segment]?
        var primaryBytes = primary.totalBytes
        if design.clipPlaybackMode == .shuffled, clipBuilds.count > 1 {
            program = ClipProgram.shuffled(
                clips: clipBuilds.map { .init(id: $0.id, frameCount: $0.build.loopFrameCount) },
                totalFrames: spec.totalFrames,
                seed: design.id
            )
            guard let program else { throw GeneratorError.clipProgramImpossible }
            do {
                let framesByID = Dictionary(uniqueKeysWithValues: clipBuilds.map { ($0.id, $0.build.encodedFrames) })
                let programmedFrames = program.flatMap { segment -> [String] in
                    Array((framesByID[segment.clipID] ?? []).prefix(segment.frameCount))
                }
                primaryBytes = try await writeFonts(
                    encodedFrames: programmedFrames,
                    familyBase: design.fontFamilyBase,
                    spec: spec,
                    crop: crop,
                    templateURL: templateURL,
                    designID: design.id,
                    onStage: onStage
                )
                let programmedPreview = store.programPreviewVideoURL(for: design.id)
                try await ProgramPreviewWriter(framesPerSecond: spec.framesPerSecond).write(
                    segments: program,
                    source: { clipID in
                        clipID.map { store.previewVideoURL(for: design.id, variant: $0) }
                            ?? store.previewVideoURL(for: design.id)
                    },
                    to: programmedPreview
                )
                let ordinaryPreview = store.previewVideoURL(for: design.id)
                try FileManager.default.removeItem(at: ordinaryPreview)
                try FileManager.default.moveItem(at: programmedPreview, to: ordinaryPreview)
            }
        }

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
            totalFontBytes: primaryBytes,
            builtAt: Date(),
            backdropRect: primary.bakedBackdrop,
            tiles: design.tiles,
            assets: design.assets.isEmpty ? nil : design.assets,
            readouts: design.readouts.isEmpty ? nil : design.readouts,
            clipVariants: builtVariants.isEmpty ? nil : builtVariants,
            // The resolved title, not the raw override: the phone has no
            // filename to fall back on, so an unnamed clip would arrive as
            // "Standard" there however it reads in the studio.
            primaryClipName: design.primaryClipTitle,
            // Only when it actually built. A default naming a variant whose
            // fonts are not in the bundle is a black widget on first install,
            // which is the failure this project can least afford.
            defaultVariantID: builtVariants.contains { $0.id == design.defaultVariantID }
                ? design.defaultVariantID
                : nil,
            clipProgram: program
        )
        try store.save(manifest)

        Self.logger.info("""
        build done design=\(design.id.uuidString, privacy: .public) \
        bytes=\(primary.totalBytes) variants=\(builtVariants.count)
        """)
        onStage(.done(manifest: manifest))
        return manifest
    }

    private struct ClipBuild {
        let totalBytes: Int
        let loopFrameCount: Int
        let bakedBackdrop: CGRect?
        let encodedFrames: [String]
    }

    /// A variant's loop, sized to its own clip - capped at the natural length,
    /// never past it, because video sampling does not wrap: overshooting would
    /// end the decode early and fail the whole build.
    static func variantLoopLength(
        duration: TimeInterval,
        spec: TimerFontSpec,
        playbackSpeed: Double
    ) -> Int {
        let natural = max(1, Int((
            duration * Double(spec.framesPerSecond) / max(playbackSpeed, 0.01)
        ).rounded(.down)))
        return spec.seamlessLoopLength(nearest: natural, maximum: min(TimerFontSpec.maximumLoopFrames, natural))
    }

    /// One clip's full output: fonts, backdrop, preview - and for the primary
    /// clip only, the wallpapers. Everything positional is the design's, so
    /// every variant lands on exactly the pixels the layout was authored on.
    private func buildClip(
        design: DesignDocument,
        spec: TimerFontSpec,
        crop: CGRect,
        templateURL: URL,
        source: URL,
        familyBase: String,
        variantID: UUID?,
        programFrameCount: Int?,
        onStage: @Sendable @escaping (Stage) -> Void
    ) async throws -> ClipBuild {
        onStage(.decoding(progress: 0))
        let extractor = MediaFrameExtractor(
            url: source,
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

        // A variant keeps its own length. The clips need not match: each loop
        // is sized to its own clip the way `retuneLoop` sizes the primary's.
        let summary = programFrameCount == nil && variantID == nil ? nil : try await extractor.summary()
        let loopFrameCount: Int
        if let programFrameCount {
            loopFrameCount = programFrameCount
        } else if variantID == nil {
            loopFrameCount = design.loopFrameCount
        } else {
            loopFrameCount = Self.variantLoopLength(
                duration: summary?.duration ?? 0,
                spec: spec,
                playbackSpeed: design.playbackSpeed
            )
        }

        // A shuffled bag gives every clip an equal share of the fixed table.
        // Sampling its complete duration into that share changes only playback
        // speed; dimensions, output FPS and JPEG quality remain unchanged.
        let samplingSpeed = programFrameCount.map { count in
            (summary?.duration ?? design.sourceDuration) * Double(spec.framesPerSecond) / Double(count)
        } ?? design.playbackSpeed

        let frames = try await extractor.composedFrames(
            startFrame: variantID == nil ? design.loopStartFrame : 0,
            count: loopFrameCount,
            frameRate: spec.framesPerSecond,
            speed: samplingSpeed,
            progress: { onStage(.decoding(progress: $0)) }
        )

        onStage(.analysing)
        let encoder = FrameEncoder(
            crop: crop,
            quality: design.jpegQuality,
            widgetRect: design.widgetRect
        )

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

        var totalBytes = 0
        for lane in 0 ..< spec.laneCount {
            onStage(.writingFonts(completed: lane, total: spec.laneCount))
            let url = store.fontURL(for: design.id, familyBase: familyBase, lane: lane)
            do {
                let data = try builder.font(
                    lane: lane,
                    familyBase: familyBase,
                    encodedFrames: encodedFrames
                )
                try data.write(to: url, options: DesignStore.writingOptions)
                totalBytes += data.count
            } catch {
                throw GeneratorError.laneWriteFailed(lane: lane, path: url.path, underlying: error)
            }
            // 64 multi-megabyte writes would otherwise starve the UI entirely,
            // and it is where a stopped build actually stops: without the
            // check, Escape would hide a run that kept writing fonts.
            try Task.checkCancellation()
            await Task.yield()
        }
        onStage(.writingFonts(completed: spec.laneCount, total: spec.laneCount))

        onStage(.writingWallpaper)
        // Shared with the picture-built body of a design: both have to produce
        // the same stills, and the backdrop's colour match and edge correction
        // are measurements of real hardware rather than anything a second copy
        // of this could be trusted to restate.
        let bakedBackdrop = try await DesignArtWriter(
            store: store,
            tileArtwork: tileArtwork,
            assetArtwork: assetArtwork
        ).write(design: design, poster: frames[0], variantID: variantID)

        // The in-app preview plays this rather than the lane fonts: only the
        // system widget renderer advances timer text fast enough for those.
        try await PreviewVideoWriter(
            size: DeviceGeometry.screenPixelSize,
            framesPerSecond: spec.framesPerSecond
        ).write(
            frames: frames,
            to: variantID.map { store.previewVideoURL(for: design.id, variant: $0) }
                ?? store.previewVideoURL(for: design.id)
        )

        Self.logger.info("""
        clip done family=\(familyBase, privacy: .public) \
        loop=\(loopFrameCount) bytes=\(totalBytes) estimated=\(budget.estimatedTotalBytes)
        """)
        return ClipBuild(
            totalBytes: totalBytes,
            loopFrameCount: loopFrameCount,
            bakedBackdrop: bakedBackdrop,
            encodedFrames: encodedFrames
        )
    }

    private func writeFonts(
        encodedFrames: [String],
        familyBase: String,
        spec: TimerFontSpec,
        crop: CGRect,
        templateURL: URL,
        designID: UUID,
        onStage: @Sendable @escaping (Stage) -> Void
    ) async throws -> Int {
        let builder = try LaneFontBuilder(
            templateData: try Data(contentsOf: templateURL),
            spec: spec,
            factory: SVGGlyphFactory(cropRect: crop, screenSize: DeviceGeometry.screenPixelSize)
        )
        var totalBytes = 0
        for lane in 0 ..< spec.laneCount {
            onStage(.writingFonts(completed: lane, total: spec.laneCount))
            let data = try builder.font(lane: lane, familyBase: familyBase, encodedFrames: encodedFrames)
            try data.write(
                to: store.fontURL(for: designID, familyBase: familyBase, lane: lane),
                options: DesignStore.writingOptions
            )
            totalBytes += data.count
            try Task.checkCancellation()
            await Task.yield()
        }
        onStage(.writingFonts(completed: spec.laneCount, total: spec.laneCount))
        return totalBytes
    }
}
