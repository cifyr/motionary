import CoreGraphics
import Foundation

/// Reports what a design's animated crop costs, without building it.
///
/// The crop decides how many pixels get re-encoded into every glyph selection,
/// and a build takes minutes, so "is this crop tight?" needs an answer that does
/// not need one. Read-only: nothing is saved and no font is written.
///
///     MotionaryStudio --analyse-crop [--starred]
enum CropAnalysis {
    static func requested(in arguments: [String]) -> Bool {
        arguments.contains("--analyse-crop")
    }

    static func run() -> Never {
        let designs = StudioPipeline.saved()
        guard let root = ProjectLocator.find(), !designs.isEmpty else {
            FileHandle.standardError.write(Data("failed: no designs or no project\n".utf8))
            exit(1)
        }
        let onlyStarred = CommandLine.arguments.contains("--starred")
        let pipeline = StudioPipeline(projectRoot: root, model: .default)

        Task.detached {
            for design in designs where !onlyStarred || design.isStarred {
                do {
                    try await report(design: design, pipeline: pipeline)
                } catch {
                    FileHandle.standardError.write(Data("failed: \(design.name): \(error)\n".utf8))
                }
            }
            exit(0)
        }
        dispatchMain()
    }

    /// Composed exactly as `StudioPipeline.generate` does, or the motion would be
    /// measured against a different picture than a build would make.
    private static func frames(for design: DesignDocument, store: DesignStore) async throws -> [CGImage] {
        let extractor = MediaFrameExtractor(
            url: store.sourceVideoURL(for: design),
            screenSize: DeviceGeometry.screenPixelSize,
            transform: design.mediaTransform,
            background: design.backgroundName.flatMap {
                ImageLoader.load(
                    at: store.backgroundURL(for: design.id, name: $0),
                    maxPixelSize: Int(DeviceGeometry.screenPixelSize.height)
                )
            },
            clipRect: design.backgroundName == nil ? nil : design.widgetRect,
            clipCornerRadius: design.effectiveCornerRadius
        )
        return try await extractor.composedFrames(
            startFrame: 0,
            count: min(design.loopFrameCount, 16),
            frameRate: design.spec.framesPerSecond
        )
    }

    private static func report(design: DesignDocument, pipeline: StudioPipeline) async throws {
        let store = try StudioPipeline.openStore()
        let sample = try await frames(for: design, store: store)
        let widget = design.widgetRect
        let widgetArea = Double(widget.width * widget.height)
        let spec = design.spec

        print("=== \(design.name) [\(design.id.uuidString.prefix(8))]\(design.isStarred ? " *" : "")")
        print(String(
            format: "  widget %.0fx%.0f  sampled %d frames  quality %.2f  %d lanes  %d-frame loop",
            widget.width, widget.height, sample.count, design.jpegQuality, spec.laneCount, design.loopFrameCount
        ))
        print(String(
            format: "  stored crop %@  %.1f%% of the widget",
            rect(design.effectiveCrop),
            Double(design.effectiveCrop.width * design.effectiveCrop.height) / widgetArea * 100
        ))

        // A sweep rather than a single reading: the useful question is how much
        // of the box is slack, and that only shows against the alternatives.
        for minimum in [1, 2, 4, 8, 16, 32] {
            var detector = MotionCropDetector()
            detector.minimumClusterCells = minimum
            let result = detector.detect(frames: sample, screenSize: DeviceGeometry.screenPixelSize)
            let crop = DesignDocument.usableCrop(result.crop, in: widget)
            let bytes = averageBytes(frames: sample, crop: crop, quality: design.jpegQuality)
            print(String(
                format: "  min cluster %2d cells: %@ %5.1f%% of widget, box %3.0f%% moving,"
                    + " %2d of %2d clusters left static, frame %6d bytes",
                minimum, rect(crop), Double(crop.width * crop.height) / widgetArea * 100,
                result.boxOccupancy * 100, result.discardedClusterCount, result.clusterCount, bytes
            ))
        }

        // What the crop costs in real encoded bytes, which is the only number the
        // payload budget reacts to, and where the saving actually ends up.
        let detected = DesignDocument.usableCrop(
            MotionCropDetector().detect(frames: sample, screenSize: DeviceGeometry.screenPixelSize).crop,
            in: widget
        )
        for (label, crop) in [("stored  ", design.effectiveCrop), ("detected", detected)] {
            let bytes = averageBytes(frames: sample, crop: crop, quality: design.jpegQuality)
            let budget = PayloadBudget(spec: spec, averageEncodedFrameBytes: bytes)
            let planned = PayloadBudget.bestPlan(samples: sample, crop: crop)
            print("  \(label) crop: frame \(bytes) bytes, payload at this quality"
                + " \(budget.estimatedTotalBytes), planner would pick \(planned?.summary ?? "nothing")")
        }
        print("")
    }

    private static func averageBytes(frames: [CGImage], crop: CGRect, quality: Double) -> Int {
        var total = 0
        var counted = 0
        for frame in frames {
            guard let cropped = frame.cropping(to: crop),
                  let data = FrameEncoder.jpegData(cropped, quality: quality)
            else { continue }
            total += data.count
            counted += 1
        }
        return counted > 0 ? total / counted : 0
    }

    private static func rect(_ rect: CGRect) -> String {
        String(format: "%4.0f,%4.0f %4.0fx%4.0f", rect.minX, rect.minY, rect.width, rect.height)
    }
}
