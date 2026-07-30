import CoreGraphics
import Foundation
import os

enum RuntimeBuildError: Error, CustomStringConvertible {
    case emptyCrop(design: String)
    case sheetNotDrawable(reason: String)
    case encodeFailed(frameIndex: Int, size: CGSize)
    case writeFailed(path: String, underlying: Error)
    case sheetContextFailed(size: CGSize)

    var description: String {
        switch self {
        case .emptyCrop(let design):
            "runtime build: design \"\(design)\" has no animated area inside its widget frame"
        case .sheetNotDrawable(let reason):
            "runtime build: \(reason). Use separate frames, or fewer of them."
        case .encodeFailed(let index, let size):
            "runtime build: could not encode frame \(index) at \(Int(size.width))x\(Int(size.height))"
        case .writeFailed(let path, let underlying):
            "runtime build: could not write \(path): \(underlying)"
        case .sheetContextFailed(let size):
            "runtime build: could not allocate a \(Int(size.width))x\(Int(size.height)) sheet"
        }
    }
}

/// Builds a design the phone can make on its own: pictures in the app group
/// instead of fonts in the bundle.
///
/// The counterpart to `FontSetGenerator`, and deliberately the same shape - same
/// store, same manifest, same wallpaper and backdrop - so the widget's render
/// path differs in one branch rather than in a second renderer. What is gone is
/// the part that needed a Mac: no shaping template, no lane fonts, no base64
/// payload, nothing to compile into an extension's bundle.
///
/// Two passes over the source, on purpose. The crop has to be measured before
/// the frames are cut, and holding sixteen full-screen frames to measure it is
/// 200MB on a device that will not give it. The measuring pass therefore decodes
/// a quarter-size screen, which costs nothing and is finer than the detector's
/// own 64-column grid anyway.
struct RuntimeFrameBuilder {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "RuntimeBuild")

    /// How much the measuring pass shrinks the screen by.
    static let detectionDivisor: CGFloat = 4
    /// Frames the measuring pass looks at.
    static let detectionSamples = 12

    enum Stage: Equatable, Sendable {
        case reading
        case measuring
        case writingFrames(completed: Int, total: Int)
        case writingPictures
        case done

        var caption: String {
            switch self {
            case .reading: "Reading the clip"
            case .measuring: "Measuring motion"
            case .writingFrames(let completed, let total): "Writing frames (\(completed)/\(total))"
            case .writingPictures: "Saving the wallpaper"
            case .done: "Done"
            }
        }

        var fraction: Double {
            switch self {
            case .reading: 0.03
            case .measuring: 0.12
            case .writingFrames(let completed, let total):
                0.2 + (total > 0 ? Double(completed) / Double(total) : 0) * 0.72
            case .writingPictures: 0.94
            case .done: 1
            }
        }
    }

    let store: DesignStore
    let screenSize: CGSize

    init(store: DesignStore, screenSize: CGSize = DeviceGeometry.screenPixelSize) {
        self.store = store
        self.screenSize = screenSize
    }

    /// Works out the loop, the crop and the frame rate, then writes the frames.
    ///
    /// Returns the design as it ended up as well as the manifest: the fit
    /// changes the playback speed and the detection changes the crop, and a
    /// caller that saved the design it passed in would be storing numbers the
    /// build did not use.
    func build(
        design incoming: DesignDocument,
        onStage: @Sendable @escaping (Stage) -> Void = { _ in }
    ) async throws -> (design: DesignDocument, manifest: BuildManifest) {
        var design = incoming
        design.animationSource = .runtimeImages
        design.runtimeFramesPerSecond = BlinkCycle.clampedFramesPerSecond(design.runtimeFramesPerSecond)

        onStage(.reading)
        let source = store.sourceVideoURL(for: design)
        let probe = MediaFrameExtractor(url: source, screenSize: screenSize)
        let summary = try await probe.summary()
        design.sourceDuration = summary.duration
        if design.mediaTransform.isIdentity {
            design.mediaTransform = MediaTransform.suggested(
                sourceSize: summary.naturalSize,
                screenSize: screenSize
            )
        }

        // The whole reason the two-second cap is bearable. A loop that does not
        // divide two seconds gets cut mid-motion at the wrap, so it is played a
        // whole number of times instead and the speed absorbs the difference.
        let fit = BlinkCycle.fit(sourceLoop: summary.duration)
        design.playbackSpeed = fit.speed
        let frameCount = design.runtimeFrameCount
        let rate = design.runtimeFramesPerSecond

        onStage(.measuring)
        design.animationCrop = try await detectedCrop(design: design, fit: fit, rate: rate)
        let crop = design.effectiveCrop
        guard crop.width >= 2, crop.height >= 2 else {
            throw RuntimeBuildError.emptyCrop(design: design.name)
        }

        if design.runtimeLayout == .sheet,
           let refusal = RuntimeFrameSequence.sheetRefusal(frameCount: frameCount, frameSize: crop.size) {
            throw RuntimeBuildError.sheetNotDrawable(reason: refusal)
        }

        Self.logger.info("""
        runtime build design=\(design.id.uuidString, privacy: .public) \
        frames=\(frameCount) rate=\(rate) layout=\(design.runtimeLayout.rawValue, privacy: .public) \
        crop=\(Int(crop.width))x\(Int(crop.height)) repeats=\(fit.repeats) speed=\(fit.speed)
        """)

        let written = try await writeFrames(
            design: design,
            fit: fit,
            crop: crop,
            frameCount: frameCount,
            rate: rate,
            onStage: onStage
        )

        let sequence = RuntimeFrameSequence(
            framesPerSecond: rate,
            layout: design.runtimeLayout,
            frameSize: crop.size,
            rect: crop,
            sourceRepeats: fit.repeats,
            speed: fit.speed,
            totalFrameBytes: written.bytes
        )
        let manifest = BuildManifest(
            designID: design.id,
            buildGeneration: design.buildGeneration + 1,
            fontFamilyBase: design.fontFamilyBase,
            // Stated as the runtime frame geometry rather than left at zero: the
            // widget report prints these, and a report that says 0 lanes at 0fps
            // for a design that is plainly animating reads as a broken build.
            laneCount: 0,
            framesPerSecond: rate,
            loopFrameCount: frameCount,
            animationCrop: crop,
            widgetRect: design.widgetRect,
            screenSize: screenSize,
            wallpaperName: "wallpaper.png",
            totalFontBytes: 0,
            builtAt: Date(),
            backdropRect: written.backdropRect,
            tiles: design.tiles,
            animationSource: .runtimeImages,
            frameSequence: sequence
        )

        design.buildGeneration += 1
        try store.save(design)
        try store.save(manifest)
        onStage(.done)
        Self.logger.info("""
        runtime build done design=\(design.id.uuidString, privacy: .public) \
        bytes=\(written.bytes) files=\(self.store.frameFileCount(for: design.id))
        """)
        return (design, manifest)
    }

    // MARK: - Measuring

    private func detectedCrop(
        design: DesignDocument,
        fit: BlinkCycle.LoopFit,
        rate: Int
    ) async throws -> CGRect {
        let small = CGSize(
            width: (screenSize.width / Self.detectionDivisor).rounded(),
            height: (screenSize.height / Self.detectionDivisor).rounded()
        )
        let extractor = try extractor(design: design, fit: fit, screenSize: small)
        let samples = try await extractor.composedFrames(
            startFrame: design.loopStartFrame,
            count: min(Self.detectionSamples, design.runtimeFrameCount),
            frameRate: rate,
            speed: fit.speed
        )
        let detection = MotionCropDetector().detect(frames: samples, screenSize: small)
        // Back to screen pixels. The detector's grid is 64 columns across the
        // whole screen either way, so nothing was lost by measuring small.
        let scaled = CGRect(
            x: detection.crop.minX * Self.detectionDivisor,
            y: detection.crop.minY * Self.detectionDivisor,
            width: detection.crop.width * Self.detectionDivisor,
            height: detection.crop.height * Self.detectionDivisor
        )
        return DesignDocument.usableCrop(scaled, in: design.widgetRect)
    }

    private func extractor(
        design: DesignDocument,
        fit: BlinkCycle.LoopFit,
        screenSize: CGSize
    ) throws -> MediaFrameExtractor {
        let ratio = screenSize.width / max(1, self.screenSize.width)
        return MediaFrameExtractor(
            url: store.sourceVideoURL(for: design),
            screenSize: screenSize,
            transform: MediaTransform(
                scale: design.mediaTransform.scale,
                // The offset is in screen pixels, so it has to shrink with the
                // screen or the measuring pass looks at a differently placed
                // clip than the writing pass cuts.
                offset: CGPoint(
                    x: design.mediaTransform.offset.x * ratio,
                    y: design.mediaTransform.offset.y * ratio
                ),
                fillsBackground: design.mediaTransform.fillsBackground
            ),
            background: design.backgroundName.flatMap {
                ImageLoader.load(
                    at: store.backgroundURL(for: design.id, name: $0),
                    maxPixelSize: Int(max(screenSize.width, screenSize.height))
                )
            },
            clipRect: design.backgroundName == nil
                ? nil
                : design.widgetRect.applying(CGAffineTransform(scaleX: ratio, y: ratio)),
            clipCornerRadius: design.effectiveCornerRadius * ratio,
            // Sampling runs past the end of a short clip on purpose: the frames
            // have to fill the whole two-second cycle whatever the source's own
            // length is, so it comes round `fit.repeats` times.
            sourceLoop: fit.sourceLoop > 0 ? fit.sourceLoop : nil
        )
    }

    // MARK: - Writing

    private struct Written {
        var bytes = 0
        var backdropRect: CGRect?
    }

    private func writeFrames(
        design: DesignDocument,
        fit: BlinkCycle.LoopFit,
        crop: CGRect,
        frameCount: Int,
        rate: Int,
        onStage: @Sendable @escaping (Stage) -> Void
    ) async throws -> Written {
        try store.clearFrames(for: design.id)
        let extractor = try extractor(design: design, fit: fit, screenSize: screenSize)

        var written = Written()
        var sheetContext: CGContext?
        if design.runtimeLayout == .sheet {
            let size = CGSize(width: crop.width, height: crop.height * CGFloat(frameCount))
            guard let context = CGContext(
                data: nil,
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else {
                throw RuntimeBuildError.sheetContextFailed(size: size)
            }
            sheetContext = context
        }

        try await extractor.forEachComposedFrame(
            startFrame: design.loopStartFrame,
            count: frameCount,
            frameRate: rate,
            speed: fit.speed
        ) { index, frame in
            onStage(.writingFrames(completed: index, total: frameCount))

            // The first composed frame is the still picture behind everything,
            // so it is used for the wallpaper and the backdrop before it goes.
            if index == 0 {
                written.backdropRect = try writeStills(frame: frame, design: design)
            }

            guard let cropped = frame.cropping(to: crop) else {
                throw RuntimeBuildError.encodeFailed(frameIndex: index, size: crop.size)
            }
            if let sheetContext {
                // Bottom-up: `CGContext` origin is bottom-left, and slot 0 has
                // to be the top strip or every window shows the wrong frame.
                sheetContext.draw(cropped, in: CGRect(
                    x: 0,
                    y: crop.height * CGFloat(frameCount - 1 - index),
                    width: crop.width,
                    height: crop.height
                ))
            } else {
                guard let data = FrameEncoder.jpegData(cropped, quality: design.runtimeQuality) else {
                    throw RuntimeBuildError.encodeFailed(frameIndex: index, size: crop.size)
                }
                let url = store.frameURL(for: design.id, index: index)
                do {
                    try data.write(to: url, options: DesignStore.writingOptions)
                } catch {
                    throw RuntimeBuildError.writeFailed(path: url.path, underlying: error)
                }
                written.bytes += data.count
            }
        }
        onStage(.writingFrames(completed: frameCount, total: frameCount))

        if let sheetContext {
            guard let image = sheetContext.makeImage(),
                  let data = FrameEncoder.jpegData(image, quality: design.runtimeQuality)
            else {
                throw RuntimeBuildError.encodeFailed(frameIndex: -1, size: crop.size)
            }
            let url = store.frameSheetURL(for: design.id)
            do {
                try data.write(to: url, options: DesignStore.writingOptions)
            } catch {
                throw RuntimeBuildError.writeFailed(path: url.path, underlying: error)
            }
            written.bytes = data.count
        }

        onStage(.writingPictures)
        return written
    }

    /// The full-screen wallpaper and the pre-cropped widget backdrop, from the
    /// first frame. Identical to what a lane-font build bakes, because the
    /// widget loads them by the same rules and a difference here would show as
    /// the animation sitting on a differently sized picture.
    private func writeStills(frame: CGImage, design: DesignDocument) throws -> CGRect? {
        let wallpaper = try FrameEncoder.pngData(frame)
        let wallpaperURL = store.wallpaperURL(for: design.id)
        do {
            try wallpaper.write(to: wallpaperURL, options: DesignStore.writingOptions)
        } catch {
            throw RuntimeBuildError.writeFailed(path: wallpaperURL.path, underlying: error)
        }

        // Padded, because the system hands over 359x548pt where the calibration
        // says 358x544: cropping to the exact frame leaves a few unpainted
        // pixels down the right and bottom edges.
        let padding: CGFloat = 24
        let backdropRect = design.widgetRect
            .insetBy(dx: -padding, dy: -padding)
            .intersection(CGRect(origin: .zero, size: screenSize))
            .integral
        guard !backdropRect.isNull, let cropped = frame.cropping(to: backdropRect) else { return nil }
        let data = try FrameEncoder.jpegData(cropped, quality: 0.9) ?? FrameEncoder.pngData(cropped)
        let url = store.widgetBackdropURL(for: design.id)
        do {
            try data.write(to: url, options: DesignStore.writingOptions)
        } catch {
            throw RuntimeBuildError.writeFailed(path: url.path, underlying: error)
        }
        return backdropRect
    }
}
