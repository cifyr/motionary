import CoreGraphics
import Foundation
import os

/// Builds a ready-to-use design from the GIF shipped with the app, so a fresh
/// install has a working widget without anyone opening the editor.
///
/// Everything is chosen from the source rather than assumed: the poster is
/// fitted to the widget frame, the animated region comes from the motion
/// detector, and the smoothness and quality come from encoding a real frame and
/// asking what fits the memory budget. Guessing any of those is how a widget
/// ends up black.
enum BundledDesignSeeder {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "Seed")

    static let resourceName = "Wizard"
    static let designName = "Wizard"

    enum Outcome {
        case seeded(BuildManifest)
        case skipped(String)
        case failed(String)
    }

    static func seedIfEmpty(store: DesignStore, existing: [DesignDocument]) async -> Outcome {
        guard existing.isEmpty else { return .skipped("the library already has a design") }
        guard let source = Bundle.main.url(forResource: resourceName, withExtension: "gif") else {
            return .failed("\(resourceName).gif is missing from the app bundle")
        }

        do {
            var design = DesignDocument.new(name: designName, sourceVideoName: "source.gif")
            try store.createFolder(for: design.id)
            try Data(contentsOf: source)
                .write(to: store.sourceVideoURL(for: design), options: DesignStore.writingOptions)

            let extractor = MediaFrameExtractor(url: store.sourceVideoURL(for: design))
            let summary = try await extractor.summary()
            design.sourceDuration = summary.duration
            design.mediaTransform = MediaTransform.fitting(
                sourceSize: summary.naturalSize,
                inside: design.widgetRect,
                screenSize: DeviceGeometry.screenPixelSize
            )

            // The loop should hold the whole GIF: 11 frames over 1.2s is one
            // complete cycle, and a shorter loop would cut it mid-motion.
            let spec = design.spec
            let natural = max(1, Int((summary.duration * Double(spec.framesPerSecond)).rounded()))
            design.loopFrameCount = spec.seamlessLoopLength(nearest: natural, maximum: 96)
            design.loopStartFrame = 0

            let sample = try await MediaFrameExtractor(
                url: store.sourceVideoURL(for: design), transform: design.mediaTransform
            ).composedFrames(
                startFrame: 0,
                count: min(design.loopFrameCount, 12),
                frameRate: spec.framesPerSecond
            )
            let detection = MotionCropDetector().detect(
                frames: sample, screenSize: DeviceGeometry.screenPixelSize
            )
            design.animationCrop = DesignDocument.usableCrop(detection.crop, in: design.widgetRect)

            guard let plan = PayloadBudget.bestPlan(samples: sample, crop: design.effectiveCrop)
            else {
                return .failed("no settings fit the memory budget for this source")
            }
            design.smoothness = plan.smoothness
            design.jpegQuality = plan.quality
            // The plan may have changed the frame rate, and the loop length is
            // measured in frames.
            design.retuneLoop()
            try store.save(design)
            logger.info("""
            seeding \(designName, privacy: .public) at \(plan.summary, privacy: .public), \
            crop \(String(describing: design.effectiveCrop), privacy: .public)
            """)

            let manifest = try await FontSetGenerator(store: store).build(design: design) { _ in }
            design.buildGeneration = manifest.buildGeneration
            try store.save(design)
            ActiveDesign.identifier = design.id
            logger.info("seeded \(design.id.uuidString, privacy: .public), \(manifest.totalFontBytes) bytes")
            return .seeded(manifest)
        } catch {
            logger.error("seed failed: \(String(describing: error), privacy: .public)")
            return .failed(String(describing: error))
        }
    }
}
