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
    /// 320 was measured with full-crop layers, each of which cost the render
    /// server a full-crop offscreen buffer for its mask. A patch-built design's
    /// mask is applied at the patch's own size - about a tenth of the crop - so
    /// a lane is far cheaper than the one that number came from. 720 is 24fps
    /// over a thirty-second loop, which is what it takes to play Spidey's three
    /// clips end to end without cutting them and without dropping to 16.
    static let provenLaneCount = 720

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

    /// Whether this clip is worth shipping as sprites.
    ///
    /// Measured on one frame rather than assumed from the file: a ProRes 4444
    /// has an alpha channel whether or not anything in it is transparent, and
    /// what decides this is how much of the crop the moving part actually
    /// covers. Under two thirds and the sprites are the cheaper picture; above
    /// it they are the same bytes with a rect attached.
    private func prefersSprites(
        design: DesignDocument, spec: TimerFontSpec, source: URL, crop: CGRect
    ) async -> Bool {
        guard let probe = try? await pictures(
            design: design, spec: spec, source: source, isPrimary: true, count: 1,
            preservesAlpha: true, onStage: { _ in }
        ).first, Self.hasAlpha(probe), let cropped = probe.cropping(to: crop) else { return false }
        guard let box = FrameEncoder.opaqueBounds(of: cropped) else { return true }
        let covered = (box.width * box.height) / (crop.width * crop.height)
        Self.logger.info("cut-out probe: the moving part covers \(Int(covered * 100))% of the crop")
        return covered < 0.66
    }

    /// The still scene exactly as the widget will draw it, laid out on a
    /// screen-sized canvas so a crop of it lines up with a crop of a frame.
    ///
    /// Read back from the written file rather than rebuilt, because "the same
    /// picture" and "the same bytes" are different things here: the backdrop
    /// goes through its own colour match on the way to disk, and a patch cut
    /// from anything else leaves a visible rectangle.
    private func backdropPlate(design: DesignDocument, variant: UUID?) -> CGImage? {
        guard let url = variant.flatMap({ store.existingWidgetBackdropURL(for: design.id, variant: $0) })
            ?? store.existingWidgetBackdropURL(for: design.id),
            let backdrop = ImageLoader.load(at: url, maxPixelSize: Int(max(
                DeviceGeometry.screenPixelSize.width, DeviceGeometry.screenPixelSize.height
            )))
        else { return nil }
        let rect = DesignArtWriter.backdropRect(widgetRect: design.widgetRect)
        guard !rect.isNull else { return nil }
        let size = DeviceGeometry.screenPixelSize
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        // CGContext counts from the bottom; the rect is in screen order.
        context.draw(backdrop, in: CGRect(
            x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height
        ))
        return context.makeImage()
    }

    /// One sprite frame put back on the still scene, for anything that needs a
    /// picture rather than a layer - the app's preview, and the poster.
    static func flattened(_ image: CGImage, over plate: CGImage) -> CGImage {
        guard let context = CGContext(
            data: nil, width: plate.width, height: plate.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }
        let bounds = CGRect(x: 0, y: 0, width: plate.width, height: plate.height)
        context.draw(plate, in: bounds)
        context.draw(image, in: bounds)
        return context.makeImage() ?? image
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// Writes a cut-out clip as sprites, and records where each one belongs.
    ///
    /// The frames keep their full resolution here where a flattened set has to
    /// be shrunk to fit - a sprite is a few kilobytes because it is only the
    /// figure, so the budget buys sharpness instead of 320 copies of one
    /// gradient. Shrinking is still the fallback when even the sprites will not
    /// fit, and it shrinks the sprites rather than the crop, so the rects stay
    /// right.
    private func writeSprites(
        frames: [CGImage],
        design: DesignDocument,
        spec: TimerFontSpec,
        crop: CGRect,
        variant: ClipVariant?,
        companions: Int,
        budget: Int,
        plate: CGImage,
        onStage: @Sendable @escaping (Stage) -> Void
    ) async throws -> ClipBuild {
        guard let first = frames.first else { throw GeneratorError.emptyCrop(design: design.name) }
        let encoder = FrameEncoder(
            crop: crop, quality: FramePayloadPlan.bestQuality, widgetRect: design.widgetRect
        )
        // One second of lanes either side: that is how many are unmasked at
        // once, and the patch has to cover what they drew or they show through.
        let window = max(1, spec.framesPerSecond)
        // Cut from the backdrop the widget will actually draw, not from the
        // poster it was made out of. A patch is opaque, so wherever it does not
        // cover the figure it replaces the backdrop with its own idea of it -
        // and the two only have to disagree by a level or two for every patch
        // to show as a faint rectangle blinking on and off.
        let ground = backdropPlate(design: design, variant: variant?.id) ?? plate
        var sprites = try encoder.occludingPatches(frames, plate: ground, window: window)
        func measured() -> Int { sprites.reduce(0) { $0 + $1.data.count } }
        Self.logger.info("""
        \(sprites.count) sprites come to \(measured() / 1024)KB against a \(budget / 1024)KB budget \
        (flattened, this crop would be \(Int(crop.width))x\(Int(crop.height)) every frame)
        """)

        let shrink = FramePayloadPlan.shrink(toFit: budget, measured: measured())
        if shrink < 1 {
            Self.logger.warning("shrinking sprites to \(Int(shrink * 100))% to fit the archive")
            sprites = try encoder.occludingPatches(frames, plate: ground, window: window, shrink: shrink)
        }
        onStage(.encoding(progress: 1))

        try store.clearFrames(for: design.id, variant: variant?.id)
        var totalBytes = 0
        for (index, sprite) in sprites.enumerated() {
            onStage(.writingFrames(completed: index, total: sprites.count))
            let url = store.frameURL(for: design.id, index: index, variant: variant?.id)
            do {
                try sprite.data.write(to: url, options: DesignStore.writingOptions)
            } catch {
                throw GeneratorError.laneWriteFailed(lane: index, path: url.path, underlying: error)
            }
            totalBytes += sprite.data.count
            try Task.checkCancellation()
            await Task.yield()
        }
        onStage(.writingFrames(completed: sprites.count, total: sprites.count))

        // Where each sprite goes, normalised to the crop, so the widget can put
        // it back and the numbers survive any later shrink.
        let rects = sprites.map { FrameRect(rect: $0.rect) }
        try JSONEncoder().encode(rects).write(
            to: store.frameRectsURL(for: design.id, variant: variant?.id),
            options: DesignStore.writingOptions
        )

        // The preview the app plays is the flattened picture: the app draws one
        // video, not a backdrop with a stack over it, so the sprites have to be
        // put back onto the still scene before it is written.
        try await PreviewVideoWriter(
            size: DeviceGeometry.screenPixelSize,
            framesPerSecond: spec.framesPerSecond
        ).write(
            frames: frames.map { Self.flattened($0, over: plate) },
            to: variant.map { store.previewVideoURL(for: design.id, variant: $0.id) }
                ?? store.previewVideoURL(for: design.id)
        )

        return ClipBuild(
            frameCount: sprites.count,
            totalBytes: totalBytes,
            firstFrame: plate,
            quality: FramePayloadPlan.bestQuality
        )
    }

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
        let sprites = await prefersSprites(design: design, spec: spec, source: source, crop: crop)
        let frames = try await pictures(
            design: design,
            spec: spec,
            source: source,
            isPrimary: variant == nil,
            count: count,
            preservesAlpha: sprites,
            onStage: onStage
        )
        // One opaque frame for the backdrop, which is the still scene the
        // sprites are drawn over and cannot itself be transparent.
        let plate = sprites ? try? await pictures(
            design: design, spec: spec, source: source,
            isPrimary: variant == nil, count: 1, onStage: { _ in }
        ).first : nil
        return try await write(
            frames: frames,
            design: design,
            spec: spec,
            crop: crop,
            variant: variant,
            poster: plate ?? nil,
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
        speed: Double? = nil,
        preservesAlpha: Bool = false,
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
            clipCornerRadius: design.effectiveCornerRadius,
            preservesAlpha: preservesAlpha
        )
        return try await extractor.composedFrames(
            startFrame: isPrimary ? design.loopStartFrame : 0,
            count: max(1, count),
            frameRate: spec.framesPerSecond,
            speed: speed ?? design.playbackSpeed,
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
        fps: Int,
        clips: [ProgramClip],
        program: [ClipProgram.Segment],
        preservesAlpha: Bool,
        onStage: @Sendable @escaping (Stage) -> Void
    ) async throws -> [CGImage] {
        var out: [CGImage] = []
        for segment in program {
            try Task.checkCancellation()
            guard let clip = clips.first(where: { $0.id == segment.clipID }) else {
                throw GeneratorError.emptyCrop(design: design.name)
            }
            // At the speed the design sets, never fitted to the segment.
            // Stretching a 10.6-second clip over twelve seconds to make it tile
            // the loop plays it slower than it was authored and buys nothing
            // anybody asked for - a clip that ends early is the better trade.
            // Short of its segment it repeats inside it, the same way a short
            // clip already repeats around the whole stack.
            let own = max(1, Int((clip.wall * Double(fps)).rounded(.up)))
            let cut = try await pictures(
                design: design,
                spec: TimerFontSpec(laneCount: 1, framesPerSecond: fps),
                source: clip.source,
                isPrimary: segment.clipID == nil,
                count: min(segment.frameCount, own),
                preservesAlpha: preservesAlpha,
                onStage: onStage
            )
            guard !cut.isEmpty else { throw GeneratorError.emptyCrop(design: design.name) }
            for index in 0 ..< segment.frameCount {
                out.append(cut[index % cut.count])
            }
        }
        return out
    }

    /// How the cycle is divided between the clips.
    ///
    /// In proportion to how long each one runs, so every clip plays all the way
    /// through rather than being cut to an equal share - three clips of 10.6,
    /// 8.0 and 8.0 seconds are not thirds of anything. The largest remainders
    /// take the leftover lanes so the segments add up to the whole stack
    /// exactly: a lane nobody drew into is a black flash once per loop.
    static func programShares(lanes: Int, weights: [Double]) -> [Int] {
        guard lanes > 0, !weights.isEmpty else { return [] }
        let total = weights.reduce(0, +)
        guard total > 0 else { return programShares(lanes: lanes, clips: weights.count) }
        // One lane each first, so a very short clip is never given none.
        guard lanes >= weights.count else { return Array(repeating: 0, count: weights.count) }
        var shares = weights.map { max(1, Int((Double(lanes) * $0 / total).rounded(.down))) }
        var slack = lanes - shares.reduce(0, +)
        let byRemainder = weights.indices.sorted {
            let a = Double(lanes) * weights[$0] / total
            let b = Double(lanes) * weights[$1] / total
            return (a - a.rounded(.down)) > (b - b.rounded(.down))
        }
        var cursor = 0
        while slack != 0 {
            let index = byRemainder[cursor % byRemainder.count]
            if slack > 0 {
                shares[index] += 1; slack -= 1
            } else if shares[index] > 1 {
                shares[index] -= 1; slack += 1
            }
            cursor += 1
        }
        return shares
    }

    /// The slowest a shuffled design is allowed to play.
    ///
    /// Holding every clip whole needs a thirty-second loop, and a clip that
    /// ends early is the cheaper loss: this is the floor the loop length is
    /// chosen to clear.
    ///
    /// 16 at first, because 480 lanes was not affordable when every lane cost a
    /// full-crop mask buffer. Patch-built lanes are a tenth of that, so the
    /// floor is now 24 - a twenty-second loop at 24fps against 480 lanes.
    static let shuffleFrameRateFloor = 24

    static var shuffleFrameRateFloorBudget: Int {
        ProcessInfo.processInfo.environment["MOTIONARY_SHUFFLE_FPS_FLOOR"]
            .flatMap(Int.init).map { max(1, $0) } ?? shuffleFrameRateFloor
    }

    /// The longest loop worth giving a shuffled design.
    ///
    /// The shortest mask that holds every clip when they all fit - there is no
    /// reason to spread three short clips over thirty seconds - and otherwise
    /// the longest one that still plays at the floor, so the clips are cut as
    /// little as the frame rate allows.
    static func shufflePeriod(covering wall: TimeInterval, authored: Int)
        -> (seconds: Int, resource: String)
    {
        let floor = min(shuffleFrameRateFloorBudget, authored)
        let affordable = FontSetGenerator.blinkPeriods.filter { laneBudget / $0.seconds >= floor }
        let fits = affordable.first { Double($0.seconds) >= wall - 0.001 }
        return fits ?? affordable.last ?? FontSetGenerator.blinkPeriods[0]
    }

    /// Equal shares, for clips whose lengths are not known.
    static func programShares(lanes: Int, clips: Int) -> [Int] {
        guard clips > 0, lanes > 0 else { return [] }
        let base = lanes / clips
        let remainder = lanes % clips
        return (0 ..< clips).map { base + ($0 < remainder ? 1 : 0) }
    }

    /// One clip in a shuffled programme, and how long it actually runs.
    private struct ProgramClip {
        let id: UUID?
        let source: URL
        /// Seconds of source material.
        let duration: Double
        /// Seconds it should occupy on screen, at the speed the design sets.
        let wall: Double
    }

    private func programClips(
        design: DesignDocument, spec: TimerFontSpec, crop: CGRect, cutOut: Bool
    ) async -> [ProgramClip] {
        var out: [ProgramClip] = []
        let speed = max(0.01, design.playbackSpeed)
        for (id, url) in [(UUID?.none, store.sourceVideoURL(for: design))]
            + design.variants.map { ($0.id as UUID?, store.variantClipURL(for: design.id, name: $0.sourceVideoName)) }
        {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let summary = try? await MediaFrameExtractor(
                url: url, transform: design.mediaTransform
            ).summary(), summary.duration > 0 else { continue }
            let duration = cutOut
                ? await contentSeconds(design: design, source: url, crop: crop, whole: summary.duration)
                : summary.duration
            if duration < summary.duration - 0.05 {
                let name = url.lastPathComponent
                Self.logger.info("\(name, privacy: .public) runs \(summary.duration)s but is empty after \(duration)s")
            }
            out.append(ProgramClip(id: id, source: url, duration: duration, wall: duration / speed))
        }
        return out
    }

    /// How long a clip actually animates for, which is not how long its file is.
    ///
    /// `spidey_alpha-2-2.mov` runs eight seconds and is empty after 1.8 - the
    /// figure leaves and never comes back. Sized by the file, it took a
    /// 7.6-second segment of a thirty-second loop to show 1.8 seconds of
    /// animation and six seconds of nothing, which reads as the clip being cut
    /// off at its end.
    ///
    /// Sampled coarsely: this looks for where the content stops, and a quarter
    /// of a second either way costs one lane.
    private func contentSeconds(
        design: DesignDocument, source: URL, crop: CGRect, whole: TimeInterval
    ) async -> TimeInterval {
        let rate = 4
        let count = max(1, Int((whole * Double(rate)).rounded(.down)))
        guard let frames = try? await pictures(
            design: design,
            spec: TimerFontSpec(laneCount: 1, framesPerSecond: rate),
            source: source, isPrimary: false, count: count,
            preservesAlpha: true, onStage: { _ in }
        ) else { return whole }
        var last = -1
        for (index, frame) in frames.enumerated() {
            guard let cropped = frame.cropping(to: crop),
                  FrameEncoder.opaqueBounds(of: cropped, stride: 4) != nil else { continue }
            last = index
        }
        guard last >= 0 else { return whole }
        // One sample past the last one with anything in it, so the figure is not
        // clipped mid-exit, and never longer than the file.
        return min(whole, Double(last + 2) / Double(rate))
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
        poster: CGImage? = nil,
        onStage: @Sendable @escaping (Stage) -> Void
    ) async throws -> ClipBuild {
        guard let first = frames.first else {
            throw GeneratorError.emptyCrop(design: design.name)
        }
        // The backdrop is the still scene behind the animation, so it has to be
        // opaque even when the frames are not - a sprite set composited over a
        // transparent backdrop is a widget with nothing behind the figure.
        let plate = poster ?? first

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
        ).write(design: design, poster: plate, variantID: variant?.id)
        let companions = companionBytes(design: design, variant: variant?.id)
        let budget = FramePayloadPlan.frameBudget(companionBytes: companions)
        Self.logger.info("""
        \(companions / 1024)KB of backdrop and artwork travels in the archive; \
        \(budget / 1024)KB left for frames
        """)

        onStage(.encoding(progress: 0))
        // A cut-out clip is shipped as sprites: each frame cropped to the
        // pixels that are actually in it, over the backdrop the widget already
        // draws. Flattened, every frame carries the same still scene and the
        // budget goes on 320 copies of it.
        if frames.first.map(Self.hasAlpha) == true {
            return try await writeSprites(
                frames: frames, design: design, spec: spec, crop: crop,
                variant: variant, companions: companions, budget: budget, plate: plate,
                onStage: onStage
            )
        }
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
        var crop = design.effectiveCrop
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

        // A patch-built design animates the whole widget frame rather than the
        // authored crop. The crop exists because a flattened frame costs its
        // own area, so it was drawn tight around the motion - and Spidey's
        // swing leaves it, which clips the figure in 44% of frames. A patch
        // costs what its contents cost wherever the crop's edges are, so there
        // is no longer any reason to clip anything.
        if await prefersSprites(
            design: design, spec: spec, source: store.sourceVideoURL(for: design),
            crop: design.effectiveCrop
        ) {
            crop = design.widgetRect.intersection(
                CGRect(origin: .zero, size: DeviceGeometry.screenPixelSize)
            )
            Self.logger.info("patch-built: animating the whole widget frame \(String(describing: crop), privacy: .public)")
        }

        // Shuffle turns every clip into one stack, so it replaces the whole
        // build rather than being applied after it: there is one frame set, the
        // clips are not separately selectable, and nothing else needs to know.
        if design.clipPlaybackMode == .shuffled, !design.variants.isEmpty,
           let manifest = try await buildShuffled(
               design: design, spec: spec, crop: crop, onStage: onStage
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
        onStage: @Sendable @escaping (Stage) -> Void
    ) async throws -> BuildManifest? {
        let cutOut = await prefersSprites(
            design: design, spec: spec, source: store.sourceVideoURL(for: design), crop: crop
        )
        let clips = await programClips(design: design, spec: spec, crop: crop, cutOut: cutOut)
        guard clips.count > 1 else {
            Self.logger.warning("shuffle asked for but only \(clips.count) clip could be read; building one clip instead")
            return nil
        }

        // Length and smoothness are the same budget: lanes are `period x fps`
        // and the lane ceiling is what the phone will draw. A mask long enough
        // to hold all three clips whole costs 30s at 10fps, and 10fps is worse
        // to look at than a clip that ends early - so the loop is the longest
        // one that still clears `shuffleFrameRateFloor`, and the clips are cut
        // to it rather than stretched to fill it.
        let wall = clips.reduce(0) { $0 + $1.wall }
        let mask = Self.shufflePeriod(covering: wall, authored: spec.framesPerSecond)
        let fps = max(1, min(spec.framesPerSecond, Self.laneBudget / mask.seconds))
        let lanes = mask.seconds * fps
        // Each clip gets exactly its own length where the loop can afford it,
        // and whatever is left over goes to one segment rather than being
        // spread across all of them. The leftover is a clip playing its opening
        // again, and one hitch per loop is easier to watch than three.
        // Rounded up: rounding to nearest drops the last fraction of a second,
        // which is a clip ending a moment early - and the end of a swing is
        // exactly the part anybody watching is waiting for.
        let own = clips.map { max(1, Int(($0.wall * Double(fps)).rounded(.up))) }
        var shares = own.reduce(0, +) <= lanes
            ? own
            : Self.programShares(lanes: lanes, weights: clips.map(\.wall))
        let slack = lanes - shares.reduce(0, +)
        if slack > 0, let longest = shares.indices.max(by: { shares[$0] < shares[$1] }) {
            shares[longest] += slack
        }
        guard shares.count == clips.count, shares.allSatisfy({ $0 > 0 }) else {
            Self.logger.warning("\(clips.count) clips will not divide \(lanes) lanes; building one clip instead")
            return nil
        }
        guard let program = ClipProgram.shuffled(
            clips: zip(clips, shares).map { .init(id: $0.id, frameCount: $1) },
            totalFrames: lanes,
            seed: design.id
        ) else {
            Self.logger.warning("no shuffled order fits \(lanes) lanes; building one clip instead")
            return nil
        }
        Self.logger.info("""
        shuffled \(program.count) clips over \(mask.seconds)s at \(fps)fps: \
        \(zip(clips, shares).map { String(format: "%.1fs->%d", $0.wall, $1) }.joined(separator: " "), privacy: .public)
        """)

        let programSpec = TimerFontSpec(laneCount: spec.laneCount, framesPerSecond: fps)
        // Decided once, from the design's own clip: every clip in a design is
        // the same scene shot the same way, and a stack half sprites and half
        // flattened frames would draw the still background over the sprites.
        let sprites = cutOut
        let frames = try await programmedPictures(
            design: design, fps: fps, clips: clips, program: program,
            preservesAlpha: sprites, onStage: onStage
        )
        let plate = sprites ? try? await pictures(
            design: design, spec: programSpec, source: clips[0].source,
            isPrimary: clips[0].id == nil, count: 1, onStage: { _ in }
        ).first : nil
        let built = try await write(
            frames: frames, design: design, spec: programSpec, crop: crop, variant: nil,
            poster: plate ?? nil, onStage: onStage
        )

        let backdropRect = DesignArtWriter.backdropRect(widgetRect: design.widgetRect)
        // No `clipVariants`: with a programme there is nothing to switch
        // between, and offering a switch the widget ignores is how a stale
        // choice used to survive a rebuild.
        let manifest = BuildManifest(
            designID: design.id,
            buildGeneration: design.buildGeneration + 1,
            fontFamilyBase: design.fontFamilyBase,
            laneCount: programSpec.laneCount,
            framesPerSecond: fps,
            loopFrameCount: built.frameCount,
            animationCrop: crop,
            widgetRect: design.widgetRect,
            screenSize: DeviceGeometry.screenPixelSize,
            wallpaperName: store.wallpaperURL(for: design.id).lastPathComponent,
            totalFontBytes: built.totalBytes,
            builtAt: Date(),
            backdropRect: backdropRect.isNull ? nil : backdropRect,
            frameCount: built.frameCount,
            maskPeriod: mask.seconds,
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
        clips=\(clips.count) period=\(mask.seconds)s fps=\(fps) frames=\(built.frameCount)
        """)
        return manifest
    }
}
