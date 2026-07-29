import CoreGraphics
import Foundation

/// Turns a video or GIF into a built design, natively.
///
/// The old route ran this same code inside a booted simulator and waited for a
/// manifest to appear in its container, because the pipeline lived in the iOS
/// app. None of it is iOS-only - CoreGraphics, AVFoundation and ImageIO all
/// exist here - so the studio runs it directly and the simulator drops out of
/// the loop entirely.
///
/// The import sequence deliberately mirrors the app's, step for step: probe,
/// fit, detect the motion, let the payload planner choose quality and frame
/// rate, then retune the loop against the rate it chose. Each of those steps
/// exists because leaving it out produced a specific broken widget.
struct StudioPipeline: Sendable {
    enum Stage: Equatable, Sendable {
        case preparing
        case generating(FontSetGenerator.Stage)
        case bundling
        case installing(String)

        var caption: String {
            switch self {
            case .preparing: "Reading the clip"
            case .generating(let stage): stage.caption
            case .bundling: "Adding the fonts to the app"
            case .installing(let step): step
            }
        }

        var fraction: Double {
            switch self {
            case .preparing: 0.02
            case .generating(let stage): 0.04 + stage.fraction * 0.56
            case .bundling: 0.62
            case .installing: 0.7
            }
        }
    }

    struct Built: Sendable {
        let manifest: BuildManifest
        let folder: URL
        let summary: String
        /// Set when the design was installed but something after it was not
        /// clean - a locked phone refusing to open the app, most often.
        var warning: String?

        /// The full-screen wallpaper this design needs behind it. Offered from
        /// the Mac as well as the phone: the picture is made here, and going
        /// via Photos to fetch it back is a detour.
        var wallpaperURL: URL { folder.appendingPathComponent("wallpaper.png") }
    }

    let projectRoot: URL
    let model: DeviceModel

    /// A scratch store, so a failed build leaves nothing in the project.
    private func makeStore() throws -> DesignStore {
        try DesignStore(containerURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MotionaryStudio", isDirectory: true))
    }

    /// A design worked out from the clip, before anything is generated.
    ///
    /// Split out so there is somewhere for the editor to stand: the crop and
    /// the placement are baked into the glyphs, so they have to be settled
    /// before the fonts are built rather than adjusted afterwards.
    struct Prepared: @unchecked Sendable {
        var design: DesignDocument
        let store: DesignStore
        let poster: CGImage?
    }

    func prepare(
        source: URL,
        onStage: @escaping @Sendable (Stage) -> Void
    ) async throws -> Prepared {
        onStage(.preparing)
        let store = try makeStore()

        let data = try Data(contentsOf: source)
        // Named for what the bytes are rather than what they were called: the
        // extractor picks its decoder from the extension.
        let isGIF = data.starts(with: Data("GIF8".utf8))
        var design = DesignDocument.new(
            name: source.deletingPathExtension().lastPathComponent,
            sourceVideoName: isGIF ? "source.gif" : "source.mov"
        )
        try store.createFolder(for: design.id)
        try data.write(to: store.sourceVideoURL(for: design), options: .atomic)

        let extractor = MediaFrameExtractor(
            url: store.sourceVideoURL(for: design),
            screenSize: model.screenPixelSize
        )
        let summary = try await extractor.summary()
        design.sourceDuration = summary.duration
        design.mediaTransform = MediaTransform.suggested(
            sourceSize: summary.naturalSize,
            screenSize: model.screenPixelSize
        )

        let spec = design.spec
        let natural = max(1, Int((summary.duration * Double(spec.framesPerSecond)).rounded()))
        design.loopFrameCount = spec.seamlessLoopLength(nearest: natural, maximum: 96)
        try store.save(design)

        let poster = try? await extractor.posterFrame()
        return Prepared(design: design, store: store, poster: poster)
    }

    func generate(
        _ prepared: Prepared,
        loopSeconds: Double?,
        onStage: @escaping @Sendable (Stage) -> Void
    ) async throws -> Built {
        var design = prepared.design
        let store = prepared.store

        // Measured here rather than at import, because the editor moves and
        // resizes the clip afterwards: a crop detected against the old
        // placement would animate a region the picture has left.
        let extractor = MediaFrameExtractor(
            url: store.sourceVideoURL(for: design),
            screenSize: model.screenPixelSize,
            transform: design.mediaTransform
        )
        let sample = try await extractor.composedFrames(
            startFrame: 0,
            count: min(design.loopFrameCount, 16),
            frameRate: design.spec.framesPerSecond
        )
        // The detector works across the whole screen and the motion it finds
        // can sit entirely outside the widget frame, where nothing is ever
        // drawn. A disjoint crop builds a design that cannot be built at all.
        let detection = MotionCropDetector().detect(frames: sample, screenSize: model.screenPixelSize)
        design.animationCrop = DesignDocument.usableCrop(detection.crop, in: design.widgetRect)

        // The payload ceiling decides whether the widget draws at all, so the
        // quality and frame rate come from real encoded frames rather than a
        // default that happens to be too big for this clip.
        if let plan = PayloadBudget.bestPlan(samples: sample, crop: design.effectiveCrop) {
            design.smoothness = plan.smoothness
            design.jpegQuality = plan.quality
        }
        // After the planner, never before: a loop sized against the wrong
        // frame rate plays at the wrong speed.
        design.retuneLoop()

        if let loopSeconds, loopSeconds > 0 {
            design.loopFrameCount = design.spec.seamlessLoopLength(
                nearest: max(1, Int((loopSeconds * Double(design.spec.framesPerSecond)).rounded())),
                maximum: 96
            )
        }
        try store.save(design)

        let manifest = try await FontSetGenerator(store: store).build(design: design) { stage in
            onStage(.generating(stage))
        }
        let seconds = Double(manifest.loopFrameCount) / Double(manifest.framesPerSecond)
        return Built(
            manifest: manifest,
            folder: store.folder(for: design.id),
            summary: String(
                format: "%d lanes at %dfps, %d frames (%.2fs), %.1fMB of fonts",
                manifest.laneCount,
                manifest.framesPerSecond,
                manifest.loopFrameCount,
                seconds,
                Double(manifest.totalFontBytes) / 1_048_576
            )
        )
    }

    /// The whole job: build the design, compile it into the app, install it.
    func run(
        source: URL,
        loopSeconds: Double?,
        deviceID: String?,
        onStage: @escaping @Sendable (Stage) -> Void
    ) async throws -> Built {
        let prepared = try await prepare(source: source, onStage: onStage)
        return try await install(prepared, loopSeconds: loopSeconds, deviceID: deviceID, onStage: onStage)
    }

    /// Generates and installs an already-prepared design, which is what the
    /// editor hands back.
    func install(
        _ prepared: Prepared,
        loopSeconds: Double?,
        deviceID: String?,
        onStage: @escaping @Sendable (Stage) -> Void
    ) async throws -> Built {
        let built = try await generate(prepared, loopSeconds: loopSeconds, onStage: onStage)

        onStage(.bundling)
        try BundleWriter(projectRoot: projectRoot).install(
            designFolder: built.folder,
            manifest: built.manifest,
            iconsFolder: prepared.store.root.deletingLastPathComponent()
                .appendingPathComponent("Icons", isDirectory: true)
        )
        let installer = DeviceInstaller(projectRoot: projectRoot)
        try installer.regenerateProject { onStage(.installing($0)) }

        guard let deviceID else { return built }

        var installed = built
        installed.warning = try installer.installAndLaunch(deviceID: deviceID) {
            onStage(.installing($0))
        }
        return installed
    }
}
