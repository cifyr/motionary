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

    /// The mask a clip of this length needs, and how many pictures that costs.
    ///
    /// One frame per mask phase: the stack is the loop. The mask decides how
    /// long the loop can be - the shipped one repeats every two seconds, which
    /// is what limited a delivered design to two - so a longer clip is given a
    /// longer mask rather than being cut down to fit the short one.
    ///
    /// The shortest mask that covers the clip, because the stack has to fill
    /// the whole cycle: every second of period costs `framesPerSecond` more
    /// pictures whether the clip fills them or not, and a second nothing was
    /// drawn into is a second of black once per loop.
    /// The longest loop that has been seen to draw on real hardware.
    ///
    /// Two seconds, which is where this started. Longer masks are correct and
    /// the widget archives them happily - it reports `ok` at 80 and 96 lanes -
    /// but the picture is drawn by a separate process that this one cannot see
    /// and does not log to, and above the two-second stack that process stops
    /// producing a picture: WidgetKit asks for a timeline twice in four seconds
    /// with no render either time, which is what it does when the renderer dies.
    ///
    /// Notably it survived 96 lanes this morning - with a mask that turned out
    /// to gate everything out, so there was nothing to composite. The cost
    /// arrived with the fix, not with the count.
    ///
    /// So this is a measured ceiling and the measurement is "two seconds
    /// works". Raising it means measuring where the renderer actually stops,
    /// not assuming - which is the mistake that put a black widget on a Home
    /// Screen three times today.
    static let provenLoopSeconds: TimeInterval = 10

    /// `MOTIONARY_LOOP_SECONDS` caps the loop for one build, so which mask a
    /// design gets can be varied on its own. The masks are the one part of this
    /// that has never been isolated on a phone: the two-second one is the
    /// shipped font and the only one a Home Screen has been seen to animate.
    static var loopSecondsBudget: TimeInterval {
        ProcessInfo.processInfo.environment["MOTIONARY_LOOP_SECONDS"]
            .flatMap(Double.init)
            .map { max(0.1, $0) } ?? provenLoopSeconds
    }

    /// How many lanes a delivered design gets, which is not what makes a
    /// widget black.
    ///
    /// The black was `FramePayloadPlan.byteBudget`: a frame set over about
    /// 10MB is not drawn at all. Photographed on a Home Screen, lane counts of
    /// 60, 90, 120, 160, 190 and 240 all draw and all animate once the set
    /// fits, so seconds were never the ceiling and neither, within reach, is
    /// this.
    ///
    /// So the ceiling is where the *pictures* stop being worth having rather
    /// than where the widget stops drawing. The byte budget is shared across
    /// the lanes and `FramePayloadPlan.shrink(toFit:measured:)` spends
    /// resolution to keep them, down to half size; past 320 the frames are
    /// small enough that the loop would be better served by fewer of them.
    ///
    /// 320 is also ten seconds at the 32fps the font-built path gets, which is
    /// the rate this is measured against - a delivered design should not look
    /// slower than a compiled one for being delivered.
    static let provenLaneCount = 320

    /// `MOTIONARY_LANE_BUDGET` moves the ceiling for one build, so where it
    /// actually falls can be bisected without a recompile between points.
    static var laneBudget: Int {
        ProcessInfo.processInfo.environment["MOTIONARY_LANE_BUDGET"]
            .flatMap(Int.init)
            .map { max(2, $0) } ?? provenLaneCount
    }

    /// The mask a clip needs, and the frame rate that fits its lanes in the
    /// budget.
    ///
    /// Length is bought with smoothness, because those are the same axis: the
    /// stack has to cover the whole mask period, so lanes are `period x fps`
    /// and the budget is on lanes. A two-second clip keeps all 32fps; a
    /// ten-second one gets the same 64 lanes spread over five times as long,
    /// which is 6fps. Cutting the clip instead would be the one thing that
    /// cannot be undone by looking at it.
    static func plan(for spec: TimerFontSpec, clipSeconds: TimeInterval)
        -> (period: Int, resource: String, frames: Int, framesPerSecond: Int)
    {
        let mask = FontSetGenerator.blinkPeriod(
            covering: min(clipSeconds, loopSecondsBudget)
        )
        let fps = max(1, min(spec.framesPerSecond, laneBudget / mask.seconds))
        return (mask.seconds, mask.resource, mask.seconds * fps, fps)
    }

    /// What a design's own loop comes to in seconds, at the speed it plays.
    static func clipSeconds(for design: DesignDocument) -> TimeInterval {
        Double(design.loopFrameCount) / Double(design.spec.framesPerSecond)
    }

    static func frameCount(for spec: TimerFontSpec) -> Int { spec.laneCount }

    /// What travels in the widget's archive beside the frames: the still
    /// backdrop behind the animation, and the artwork on every placed tile and
    /// asset.
    ///
    /// Sized from the files rather than estimated, because the difference
    /// between designs is large - flat plates come to a megabyte, photographic
    /// ones to half as much again - and it is the whole reason one design drew
    /// and another did not.
    private func companionBytes(design: DesignDocument, variant: UUID?) -> Int {
        var total = 0
        if let backdrop = store.existingWidgetBackdropURL(for: design.id, variant: variant)
            ?? store.existingWidgetBackdropURL(for: design.id)
        {
            total += (try? backdrop.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        let art = store.artFolder(for: design.id)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: art.path)) ?? [] {
            total += (try? art.appendingPathComponent(name)
                .resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    static func loopDuration(for spec: TimerFontSpec) -> TimeInterval {
        Double(frameCount(for: spec)) / Double(spec.framesPerSecond)
    }

    /// Crops, tints, edge-corrects and encodes, shrinking a frame first when it
    /// is over the renderer's pixel-area cap or when the set as a whole will
    /// not fit the archive.
    ///
    /// Over the pixel cap the render is dropped rather than refused: the frame
    /// comes out blank and the widget looks broken with nothing logged
    /// anywhere. On the calibrated phone a crop cannot reach it - the widget
    /// frame is 1.75M px against a cap around 2.1M - so this is what keeps that
    /// true on a device whose frame is larger.
    ///
    /// `shrink` is the other reason: it is what a long clip spends to keep its
    /// frame rate. See `FramePayloadPlan.shrink(toFit:measured:)`.
    private func encode(
        frames: [CGImage],
        design: DesignDocument,
        crop: CGRect,
        quality: Double,
        shrink: Double = 1
    ) throws -> [Data] {
        let encoder = FrameEncoder(crop: crop, quality: quality, widgetRect: design.widgetRect)
        let scale = FramePayloadPlan.scale(for: crop.size) * shrink
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

    /// One clip: the design's own, or one of its variants.
    ///
    /// A variant is a whole alternate animation - its own frames, its own
    /// backdrop, its own preview - which is what makes switching on the phone
    /// free. Everything here is the same work for both; only the source clip
    /// and where it is written differ.
    private struct ClipBuild {
        let frameCount: Int
        let totalBytes: Int
        let firstFrame: CGImage
        let quality: Double
    }

    private func buildClip(
        design: DesignDocument,
        spec: TimerFontSpec,
        crop: CGRect,
        source: URL,
        variant: ClipVariant?,
        loopFrameCount: Int,
        onStage: @Sendable @escaping (Stage) -> Void
    ) async throws -> ClipBuild {
        let count = max(1, loopFrameCount)
        try store.clearFrames(for: design.id, variant: variant?.id)

        onStage(.decoding(progress: 0))
        let extractor = MediaFrameExtractor(
            url: source,
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
            // A variant plays from its own start: the loop point was chosen
            // against the design's own clip and means nothing in another.
            startFrame: variant == nil ? design.loopStartFrame : 0,
            count: count,
            frameRate: spec.framesPerSecond,
            speed: design.playbackSpeed,
            progress: { onStage(.decoding(progress: $0)) }
        )
        return try await write(
            frames: frames,
            design: design,
            spec: spec,
            crop: crop,
            variant: variant,
            onStage: onStage
        )
    }

    /// The pictures for one clip, without writing anything.
    ///
    /// A shuffled design's stack is cut from several clips into one frame set,
    /// so the segments are gathered first and encoded together - one archive,
    /// one budget.
    private func pictures(
        design: DesignDocument,
        spec: TimerFontSpec,
        source: URL,
        isPrimary: Bool,
        count: Int,
        onStage: @Sendable @escaping (Stage) -> Void
    ) async throws -> [CGImage] {
        let extractor = MediaFrameExtractor(
            url: source,
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
        return try await extractor.composedFrames(
            startFrame: isPrimary ? design.loopStartFrame : 0,
            count: max(1, count),
            frameRate: spec.framesPerSecond,
            speed: design.playbackSpeed,
            progress: { onStage(.decoding(progress: $0)) }
        )
    }

    /// One stack cut from every clip the design has, in an order drawn from the
    /// design's own id.
    ///
    /// The delivered path cannot do what the font path does here. There, the
    /// programme runs over the thirty-second timer cycle and every segment is a
    /// whole clip. Here the loop *is* the mask's period - ten seconds at the
    /// most, because that is the longest pattern the substitution table can
    /// express - so three clips get a third of it each and play the first
    /// three-and-a-bit seconds of themselves. Shortening them is the price of
    /// seeing all three; the alternative is seeing one.
    ///
    /// A clip shorter than its segment repeats inside it, the same way a short
    /// clip already repeats around the whole stack.
    private func programmedPictures(
        design: DesignDocument,
        spec: TimerFontSpec,
        program: [ClipProgram.Segment],
        onStage: @Sendable @escaping (Stage) -> Void
    ) async throws -> [CGImage] {
        var out: [CGImage] = []
        for segment in program {
            try Task.checkCancellation()
            let source = segment.clipID
                .flatMap { id in design.variants.first { $0.id == id } }
                .map { store.variantClipURL(for: design.id, name: $0.sourceVideoName) }
                ?? store.sourceVideoURL(for: design)
            let cut = try await pictures(
                design: design,
                spec: spec,
                source: source,
                isPrimary: segment.clipID == nil,
                count: segment.frameCount,
                onStage: onStage
            )
            guard !cut.isEmpty else {
                throw GeneratorError.emptyCrop(design: design.name)
            }
            for index in 0 ..< segment.frameCount {
                out.append(cut[index % cut.count])
            }
        }
        return out
    }

    /// How the cycle is divided between the clips.
    ///
    /// Evenly, with the remainder spread over the first few so the segments add
    /// up to the whole stack exactly - a lane nobody drew into is a black flash
    /// once per loop.
    static func programShares(lanes: Int, clips: Int) -> [Int] {
        guard clips > 0, lanes > 0 else { return [] }
        let base = lanes / clips
        let remainder = lanes % clips
        return (0 ..< clips).map { base + ($0 < remainder ? 1 : 0) }
    }

    /// Everything a clip needs once its pictures exist: the artwork that shares
    /// its archive, the budget that leaves, the encode, the files and the
    /// preview.
    ///
    /// Separate from the extraction because a shuffled design's frames do not
    /// come from one clip - they are cut from several - and the two have to be
    /// encoded against one budget, because they end up in one archive.
    private func write(
        frames: [CGImage],
        design: DesignDocument,
        spec: TimerFontSpec,
        crop: CGRect,
        variant: ClipVariant?,
        onStage: @Sendable @escaping (Stage) -> Void
    ) async throws -> ClipBuild {
        guard let first = frames.first else {
            throw GeneratorError.emptyCrop(design: design.name)
        }

        onStage(.writingWallpaper)
        // Written before the frames are encoded, not after, because it decides
        // how much room they get. The backdrop and the tile artwork go into the
        // same archive the frames do, and budgeting the frames alone is how a
        // design with photographic tiles went black while one with four times
        // as many frames drew.
        //
        // A variant gets its own backdrop and nothing else: the clips differ
        // inside the widget frame, and the wallpaper is everything outside it.
        try await DesignArtWriter(
            store: store,
            tileArtwork: tileArtwork,
            assetArtwork: assetArtwork
        ).write(design: design, poster: first, variantID: variant?.id)
        let companions = companionBytes(design: design, variant: variant?.id)
        let budget = FramePayloadPlan.frameBudget(companionBytes: companions)
        Self.logger.info("""
        \(companions / 1024)KB of backdrop and artwork travels in the archive; \
        \(budget / 1024)KB left for frames
        """)

        onStage(.encoding(progress: 0))
        var quality = FramePayloadPlan.bestQuality
        var data = try encode(frames: frames, design: design, crop: crop, quality: quality)
        func measured() -> Int { data.reduce(0) { $0 + $1.count } }

        // Size before compression. What will not fit is a long clip's frame
        // count, and the whole point of keeping the count is that the picture
        // moves - on a moving picture blocking is more visible than softness,
        // and the widget scales the frames back up anyway.
        let shrink = FramePayloadPlan.shrink(toFit: budget, measured: measured())
        if shrink < 1 {
            Self.logger.warning("""
            \(data.count) frames come to \(measured() / 1024)KB against a \(budget / 1024)KB \
            budget; shrinking them to \(Int(shrink * 100))% rather than dropping frames
            """)
            data = try encode(
                frames: frames, design: design, crop: crop, quality: quality, shrink: shrink
            )
        }
        // Then compression, for whatever is still over: a set at the smallest
        // size this will go to can still be too big for one archive.
        while let lower = FramePayloadPlan.retry(totalBytes: measured(), at: quality, budget: budget) {
            quality = lower
            data = try encode(
                frames: frames, design: design, crop: crop, quality: quality, shrink: shrink
            )
            try Task.checkCancellation()
        }
        onStage(.encoding(progress: 1))

        var totalBytes = 0
        for (index, frame) in data.enumerated() {
            onStage(.writingFrames(completed: index, total: data.count))
            let url = store.frameURL(for: design.id, index: index, variant: variant?.id)
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

        // The app plays this; only the widget renderer can animate the design
        // itself. One per clip, so switching variants switches the picture in
        // the app as well as on the Home Screen.
        try await PreviewVideoWriter(
            size: DeviceGeometry.screenPixelSize,
            framesPerSecond: spec.framesPerSecond
        ).write(
            frames: frames,
            to: variant.map { store.previewVideoURL(for: design.id, variant: $0.id) }
                ?? store.previewVideoURL(for: design.id)
        )


        return ClipBuild(
            frameCount: data.count,
            totalBytes: totalBytes,
            firstFrame: first,
            quality: quality
        )
    }

    func build(
        design: DesignDocument,
        onStage: @Sendable @escaping (Stage) -> Void
    ) async throws -> BuildManifest {
        var spec = design.spec
        let crop = design.effectiveCrop
        guard crop.width >= 2, crop.height >= 2 else {
            throw GeneratorError.emptyCrop(design: design.name)
        }

        Self.logger.info("""
        frame build design=\(design.id.uuidString, privacy: .public) \
        variants=\(design.variants.count) fps=\(spec.framesPerSecond) \
        crop=\(String(describing: crop), privacy: .public)
        """)

        // Every folder first, not each in turn: a rebuild that drops a variant
        // would otherwise leave its frames behind, and the phone would go on
        // offering a clip the design no longer has.
        try store.clearAllFrames(for: design.id)

        // The mask is chosen for the clip rather than the clip cut to the mask.
        let plan = Self.plan(for: spec, clipSeconds: Self.clipSeconds(for: design))
        Self.logger.info("""
        mask period \(plan.period)s (\(plan.resource, privacy: .public)) for a \
        \(String(format: "%.1f", Self.clipSeconds(for: design)))s clip, \(plan.frames) lanes \
        at \(plan.framesPerSecond)fps
        """)
        // Everything below builds at the planned rate, not the authored one:
        // the sampling, the preview video and the manifest all have to agree
        // with the stack the widget will draw, or the clip plays at a speed
        // nobody chose.
        spec = TimerFontSpec(laneCount: spec.laneCount, framesPerSecond: plan.framesPerSecond)

        // Shuffle turns every clip into one stack, so it replaces the whole
        // build rather than being applied after it: there is one frame set, the
        // clips are not separately selectable, and nothing else needs to know.
        if design.clipPlaybackMode == .shuffled, !design.variants.isEmpty,
           let manifest = try await buildShuffled(
               design: design, spec: spec, crop: crop, plan: plan, onStage: onStage
           )
        {
            return manifest
        }

        let primary = try await buildClip(
            design: design,
            spec: spec,
            crop: crop,
            source: store.sourceVideoURL(for: design),
            variant: nil,
            // Never more than the design's own loop: a clip with six frames in
            // it has six, and asking the extractor for more fails the build
            // rather than producing a short loop. The lanes repeat around
            // whatever arrives, which plays that loop as many times per cycle
            // as it fits, at the speed it was authored at.
            loopFrameCount: min(design.loopFrameCount, plan.frames),
            onStage: onStage
        )
        // Not an error, the same way an ill-fitting loop is not one for the
        // fonts: it costs one jump per cycle at the wrap, which is often
        // invisible.
        if !plan.frames.isMultiple(of: primary.frameCount) {
            Self.logger.warning(
                "\(primary.frameCount) frames do not divide \(plan.frames) lanes; the loop will jump once per cycle"
            )
        }

        var builtVariants: [BuildManifest.VariantBuild] = []
        var totalBytes = primary.totalBytes
        for variant in design.variants {
            try Task.checkCancellation()
            let source = store.variantClipURL(for: design.id, name: variant.sourceVideoName)
            guard FileManager.default.fileExists(atPath: source.path) else {
                // Skipped rather than fatal: one missing clip file should not
                // cost the design every other clip it has.
                Self.logger.error("variant \(variant.name, privacy: .public) has no clip at \(source.path, privacy: .public)")
                continue
            }
            // A variant keeps its own length, sized to its own clip the same
            // way the font path sizes it: asking a two-second clip for a
            // two-second stack is fine, asking a half-second one for it stops
            // the build on "yielded 8 frames but the loop needs 32".
            let summary = try? await MediaFrameExtractor(
                url: source,
                transform: design.mediaTransform
            ).summary()
            let own = FontSetGenerator.variantLoopLength(
                duration: summary?.duration ?? 0,
                spec: spec,
                playbackSpeed: design.playbackSpeed
            )
            // Capped at the design's mask, not at its own: every clip in a
            // design shares one stack of lanes, so a variant longer than the
            // period would run off the end of it.
            let built: ClipBuild
            do {
                built = try await buildClip(
                    design: design,
                    spec: spec,
                    crop: crop,
                    source: source,
                    variant: variant,
                    loopFrameCount: min(max(1, own), plan.frames),
                    onStage: onStage
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // One clip that will not decode should not cost the design
                // every other clip it has, and a variant missing from the
                // manifest is simply one the phone is not offered.
                Self.logger.error("variant \(variant.name, privacy: .public) would not build: \(String(describing: error), privacy: .public)")
                continue
            }
            totalBytes += built.totalBytes
            builtVariants.append(BuildManifest.VariantBuild(
                id: variant.id,
                name: variant.name,
                fontFamilyBase: design.fontFamilyBase(for: variant),
                totalFontBytes: built.totalBytes,
                loopFrameCount: built.frameCount,
                frameCount: built.frameCount
            ))
        }

        let backdropRect = DesignArtWriter.backdropRect(widgetRect: design.widgetRect)
        let manifest = BuildManifest(
            designID: design.id,
            buildGeneration: design.buildGeneration + 1,
            fontFamilyBase: design.fontFamilyBase,
            laneCount: spec.laneCount,
            framesPerSecond: spec.framesPerSecond,
            loopFrameCount: primary.frameCount,
            animationCrop: crop,
            widgetRect: design.widgetRect,
            screenSize: DeviceGeometry.screenPixelSize,
            wallpaperName: store.wallpaperURL(for: design.id).lastPathComponent,
            totalFontBytes: totalBytes,
            builtAt: Date(),
            backdropRect: backdropRect.isNull ? nil : backdropRect,
            frameCount: primary.frameCount,
            maskPeriod: plan.period,
            tiles: design.tiles,
            assets: design.assets,
            readouts: design.readouts,
            clipVariants: builtVariants.isEmpty ? nil : builtVariants,
            primaryClipName: design.primaryClipName
        )
        try store.save(manifest)
        Self.logger.info("""
        frame build done design=\(design.id.uuidString, privacy: .public) \
        clips=\(builtVariants.count + 1) frames=\(primary.frameCount) bytes=\(totalBytes)
        """)
        return manifest
    }

    /// Every clip in one stack, in a shuffled order, as the design's only frame
    /// set.
    ///
    /// Returns nil when the clips will not divide the cycle - fewer than two
    /// usable clips, or a stack too short to give each one a segment - and the
    /// caller builds the design the ordinary way rather than failing. A design
    /// that plays one clip is worth more than a build that stops.
    private func buildShuffled(
        design: DesignDocument,
        spec: TimerFontSpec,
        crop: CGRect,
        plan: (period: Int, resource: String, frames: Int, framesPerSecond: Int),
        onStage: @Sendable @escaping (Stage) -> Void
    ) async throws -> BuildManifest? {
        let usable = design.variants.filter {
            FileManager.default.fileExists(
                atPath: store.variantClipURL(for: design.id, name: $0.sourceVideoName).path
            )
        }
        let clipIDs: [UUID?] = [nil] + usable.map { $0.id as UUID? }
        let shares = Self.programShares(lanes: plan.frames, clips: clipIDs.count)
        guard clipIDs.count > 1, shares.allSatisfy({ $0 > 0 }) else {
            Self.logger.warning("""
            shuffle asked for on \(design.name, privacy: .public) but \(clipIDs.count) clips \
            will not divide \(plan.frames) lanes; building one clip instead
            """)
            return nil
        }
        guard let program = ClipProgram.shuffled(
            clips: zip(clipIDs, shares).map { .init(id: $0, frameCount: $1) },
            totalFrames: plan.frames,
            seed: design.id
        ) else {
            Self.logger.warning("no shuffled order fits \(plan.frames) lanes; building one clip instead")
            return nil
        }
        Self.logger.info("""
        shuffled \(program.count) segments over \(plan.frames) lanes: \
        \(program.map { "\($0.frameCount)" }.joined(separator: "+"), privacy: .public)
        """)

        let frames = try await programmedPictures(
            design: design, spec: spec, program: program, onStage: onStage
        )
        let built = try await write(
            frames: frames, design: design, spec: spec, crop: crop, variant: nil, onStage: onStage
        )

        let backdropRect = DesignArtWriter.backdropRect(widgetRect: design.widgetRect)
        // No `clipVariants`: with a programme there is nothing to switch
        // between, and offering a switch that the widget ignores is how a
        // stale choice used to survive a rebuild.
        let manifest = BuildManifest(
            designID: design.id,
            buildGeneration: design.buildGeneration + 1,
            fontFamilyBase: design.fontFamilyBase,
            laneCount: spec.laneCount,
            framesPerSecond: spec.framesPerSecond,
            loopFrameCount: built.frameCount,
            animationCrop: crop,
            widgetRect: design.widgetRect,
            screenSize: DeviceGeometry.screenPixelSize,
            wallpaperName: store.wallpaperURL(for: design.id).lastPathComponent,
            totalFontBytes: built.totalBytes,
            builtAt: Date(),
            backdropRect: backdropRect.isNull ? nil : backdropRect,
            frameCount: built.frameCount,
            maskPeriod: plan.period,
            tiles: design.tiles,
            assets: design.assets,
            readouts: design.readouts,
            clipVariants: nil,
            primaryClipName: design.primaryClipName,
            clipProgram: program
        )
        try store.save(manifest)
        Self.logger.info("""
        shuffled build done design=\(design.id.uuidString, privacy: .public) \
        clips=\(clipIDs.count) frames=\(built.frameCount) bytes=\(built.totalBytes)
        """)
        return manifest
    }
}
