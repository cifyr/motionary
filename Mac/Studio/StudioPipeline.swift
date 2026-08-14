import CoreGraphics
import Foundation

enum StudioPipelineError: Error, CustomStringConvertible {
    case noProjectFolder

    var description: String {
        switch self {
        case .noProjectFolder:
            "no Motionary project folder chosen; building writes into the Xcode project, so pick the folder holding project.yml"
        }
    }
}

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

    /// Optional, because only building needs it.
    ///
    /// Editing a layout reads the design and its clip out of Application
    /// Support; the Xcode project is where a *build* is written. Requiring it
    /// to open the editor meant a studio that could not find project.yml
    /// silently refused to open anything, which reads as clicking not working.
    let projectRoot: URL?
    let model: DeviceModel

    /// Designs live in Application Support, not a temp directory.
    ///
    /// They were scratch until a design became worth reopening: everything
    /// placed on the canvas is in here, and a build used to be the last time
    /// anyone could see it. The OS empties a temp directory whenever it likes,
    /// which would have thrown away the layout rather than the leftovers.
    static func storeContainer() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support.appendingPathComponent("Motionary", isDirectory: true)
    }

    static func openStore() throws -> DesignStore {
        try DesignStore(containerURL: try storeContainer())
    }

    private func makeStore() throws -> DesignStore {
        try Self.openStore()
    }

    /// Rasterised catalogue icons, alongside the designs rather than inside any
    /// one of them - the same folder `IconCache` writes to.
    static func iconsFolder(for store: DesignStore) -> URL {
        store.root.deletingLastPathComponent().appendingPathComponent("Icons", isDirectory: true)
    }

    /// The designs Studio ships with, by the names they were built under.
    ///
    /// Matched by name because they predate the flag that marks them. Only ever
    /// consulted once per design: after the first run the flag is on disk, and
    /// renaming one afterwards cannot un-starter it.
    static let starterNames: Set<String> = ["Video Games", "Aethetic Photos", "Spidey Swing"]

    /// Marks the shipped designs, once.
    @discardableResult
    static func markStarters() -> Int {
        guard let store = try? openStore() else { return 0 }
        var marked = 0
        for design in store.loadAll() where !design.isStarter && starterNames.contains(design.name) {
            var updated = design
            updated.isStarter = true
            // Not touched: flagging a design is not editing it, and the library
            // sorts on updatedAt.
            try? store.save(updated, touch: false)
            marked += 1
        }
        return marked
    }

    /// Brings designs over from the temp store the studio used to write to.
    ///
    /// Only the design and its source clip: the fonts, preview and wallpaper
    /// are regenerated by the next build, and copying 30MB of lane fonts per
    /// design to keep a layout would be paying for the wrong thing.
    @discardableResult
    static func migrateLegacyDesigns() -> Int {
        let manager = FileManager.default
        let legacy = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MotionaryStudio/Designs", isDirectory: true)
        guard manager.fileExists(atPath: legacy.path), let store = try? openStore() else { return 0 }

        let existing = Set(store.loadAll().map(\.id))
        var moved = 0
        let folders = (try? manager.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent), !existing.contains(id) else { continue }
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("design.json")),
                  let design = try? JSONDecoder().decode(DesignDocument.self, from: data)
            else { continue }

            let source = folder.appendingPathComponent(design.sourceVideoName)
            guard manager.fileExists(atPath: source.path) else { continue }
            do {
                try store.createFolder(for: design.id)
                let destination = store.sourceVideoURL(for: design)
                if !manager.fileExists(atPath: destination.path) {
                    try manager.copyItem(at: source, to: destination)
                }
                // Not touched: carrying a design across stores is not editing
                // it, and the library sorts on updatedAt.
                try store.save(design, touch: false)
                moved += 1
            } catch {
                continue
            }
        }
        return moved
    }

    /// Designs already made, newest first, for reopening.
    static func saved() -> [DesignDocument] {
        guard let store = try? openStore() else { return [] }
        return store.loadAll().sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Reopens a saved design in the state it was left, rather than deriving a
    /// fresh one from the clip and discarding the placement.
    func reopen(_ design: DesignDocument) async throws -> Prepared {
        let store = try makeStore()
        let poster = try? await MediaFrameExtractor(
            url: store.sourceVideoURL(for: design),
            screenSize: model.screenPixelSize
        ).posterFrame()
        return Prepared(design: design, store: store, poster: poster)
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
        // Numbered against the library, because the same clip gets dropped
        // repeatedly while a layout is worked out and rows that read
        // identically cannot be told apart afterwards.
        var design = DesignDocument.new(
            name: DesignStore.uniqueName(
                DesignStore.suggestedName(for: source.deletingPathExtension().lastPathComponent),
                among: store.loadAll().map(\.name)
            ),
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

        // The same sizing a rebuild does, rather than a second copy of it: an
        // import that sized the loop its own way disagreed with every later
        // retune about how much of the clip there was.
        design.retuneLoop()
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
            transform: design.mediaTransform,
            // The same background the build will use, or the motion would be
            // measured against a different picture than gets made.
            background: design.backgroundName.flatMap {
                ImageLoader.load(
                    at: store.backgroundURL(for: design.id, name: $0),
                    maxPixelSize: Int(model.screenPixelSize.height)
                )
            },
            clipRect: design.backgroundName == nil ? nil : design.widgetRect,
            clipCornerRadius: design.effectiveCornerRadius
        )
        // Sized before the sample as well as after it. The sample is what the
        // crop gets measured over, and a loop length left behind by an earlier
        // build spans the wrong part of the clip: a design carrying 96 frames
        // measured three seconds of travel where there were ten, locking a box
        // the other seven escaped. Sizing it again after the planner is still
        // required, because changing smoothness changes the frame rate the loop
        // is counted in.
        design.retuneLoop()
        // The whole loop, not a prefix of it: a crop measured against only the
        // first 16 frames missed everything a clip did after its first half
        // second - real for anything that travels rather than idles in place,
        // and it locked the box that gets reused for every remaining frame.
        let sample = try await extractor.composedFrames(
            startFrame: 0,
            count: design.loopFrameCount,
            frameRate: design.spec.framesPerSecond
        )
        // The detector works across the whole screen and the motion it finds
        // can sit entirely outside the widget frame, where nothing is ever
        // drawn. A disjoint crop builds a design that cannot be built at all.
        let detection = MotionCropDetector().detect(frames: sample, screenSize: model.screenPixelSize)
        var combinedCrop = detection.crop
        if design.clipPlaybackMode == .shuffled {
            // A crop measured from the primary alone freezes motion unique to
            // another clip. Analyse each source with the same composition and
            // take their union, so Spidey's right-side swings stay animated
            // without paying for the entire widget at a lower frame rate.
            for variant in design.variants {
                let variantExtractor = MediaFrameExtractor(
                    url: store.variantClipURL(for: design.id, name: variant.sourceVideoName),
                    screenSize: model.screenPixelSize,
                    transform: design.mediaTransform,
                    background: design.backgroundName.flatMap {
                        ImageLoader.load(
                            at: store.backgroundURL(for: design.id, name: $0),
                            maxPixelSize: Int(model.screenPixelSize.height)
                        )
                    },
                    clipRect: design.backgroundName == nil ? nil : design.widgetRect,
                    clipCornerRadius: design.effectiveCornerRadius
                )
                let summary = try await variantExtractor.summary()
                let count = FontSetGenerator.variantLoopLength(
                    duration: summary.duration,
                    spec: design.spec,
                    playbackSpeed: design.playbackSpeed
                )
                let frames = try await variantExtractor.composedFrames(
                    startFrame: 0,
                    count: count,
                    frameRate: design.spec.framesPerSecond,
                    speed: design.playbackSpeed
                )
                let variantCrop = MotionCropDetector()
                    .detect(frames: frames, screenSize: model.screenPixelSize).crop
                combinedCrop = combinedCrop.union(variantCrop)
            }
        }
        design.animationCrop = DesignDocument.usableCrop(combinedCrop, in: design.widgetRect)
        // Worth saying out loud, because a loose box is invisible in the result
        // and expensive in every glyph: the pixels inside it are re-encoded into
        // all `lanes x 15` selections whether they move or not.
        FileHandle.standardError.write(Data("""
        ... motion in \(Int(detection.boxOccupancy * 100))% of the detected box, \
        \(detection.discardedClusterCount) of \(detection.clusterCount) clusters left to the backdrop\n
        """.utf8))

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
                maximum: TimerFontSpec.maximumLoopFrames
            )
        }
        try store.save(design)

        // The same artwork the bundling step installs, so the icons baked into
        // the wallpaper line up with the live ones the widget draws over them.
        let artwork = TileArtwork(
            iconsFolder: Self.iconsFolder(for: store),
            skinsFolder: store.skinsFolder(for: design.id)
        )
        // Keyed on the way into the bake, from the design's own Assets folder,
        // so what ships is what the editor showed.
        let designID = design.id
        let manifest = try await FontSetGenerator(
            store: store,
            tileArtwork: { artwork.image(for: $0) },
            assetArtwork: { AssetArtwork.image(for: $0, designID: designID, store: store) }
        ).build(design: design) { stage in
            onStage(.generating(stage))
        }
        let seconds = Double(manifest.loopFrameCount) / Double(manifest.framesPerSecond)
        return Built(
            manifest: manifest,
            folder: store.folder(for: design.id),
            summary: String(
                format: "%d lanes at %dfps, %d frames (%.2fs), %.1fMB of fonts, animating %.0f%% of the widget",
                manifest.laneCount,
                manifest.framesPerSecond,
                manifest.loopFrameCount,
                seconds,
                Double(manifest.totalFontBytes) / 1_048_576,
                Double(manifest.animationCrop.width * manifest.animationCrop.height)
                    / Double(manifest.widgetRect.width * manifest.widgetRect.height) * 100
            )
        )
    }

    /// Builds a design as pictures and packs it into one file.
    ///
    /// The other path here compiles a design into the widget extension and
    /// installs the app, because glyphs only draw from a bundle. This one
    /// produces something that can be handed to a phone that already has the
    /// app - AirDropped, opened from Files, or later synced - and needs no
    /// toolchain at the other end. The cost is the loop: a picture per lane is
    /// two seconds where the fonts get thirty.
    ///
    /// Progress is plain text rather than a `Stage`, because nothing about this
    /// job is a build-and-install and mapping it onto those captions would have
    /// the run screen claiming to be compiling something.
    @discardableResult
    func deliverable(
        design: DesignDocument,
        to destination: URL,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        let store = try makeStore()
        let artwork = TileArtwork(
            iconsFolder: Self.iconsFolder(for: store),
            skinsFolder: store.skinsFolder(for: design.id)
        )
        let designID = design.id
        let manifest = try await FrameSetGenerator(
            store: store,
            tileArtwork: { artwork.image(for: $0) },
            assetArtwork: { AssetArtwork.image(for: $0, designID: designID, store: store) }
        ).build(design: design) { stage in
            onProgress(stage.label)
        }

        // Beside the design rather than into the project's Resources: these are
        // the pictures its tiles draw, and a delivered design has no bundle to
        // read them out of.
        onProgress("Rendering the tile artwork")
        let artFolder = store.artFolder(for: design.id)
        // Cleared first: a design that has lost a tile since the last delivery
        // would otherwise keep sending that tile's icon forever.
        try? FileManager.default.removeItem(at: artFolder)
        try BundleWriter(artworkFolder: artFolder).writeArtwork(
            manifest: manifest,
            iconsFolder: Self.iconsFolder(for: store),
            store: store,
            includeSkinLibrary: false,
            // Nor every app a slot could hold instead: 246 files and 56MB for
            // one design, against 306KB of frames. A delivered design carries
            // what it shows, and a slot swapped on the phone falls back to the
            // catalogue's plate rather than to nothing.
            includeAlternates: false
        )

        onProgress("Packing \(manifest.frameCount ?? 0) frames")
        let data = try DesignPackage.write(designID: design.id, store: store)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try data.write(to: destination, options: Data.WritingOptions.atomic)
        // The package size is the wrong number to read: most of it is wallpaper
        // and preview video that the widget never archives. What decides
        // whether the Home Screen shows a picture is the heaviest single clip's
        // frames plus the artwork that shares its archive.
        let heaviest = DesignPackage.archiveWeights(designID: design.id, store: store).first
        onProgress(String(
            format: "%d frames, %.1fs loop, %.1fMB%@%@",
            manifest.frameCount ?? 0,
            Double(manifest.frameCount ?? 0) / Double(manifest.framesPerSecond),
            Double(data.count) / 1_048_576,
            manifest.hasShuffledClipProgram
                ? ", \(manifest.clipProgram?.count ?? 0) clips shuffled" : "",
            heaviest.map {
                let note = switch $0.headroom {
                case .comfortable: ""
                case .tight: " - close to the limit, and a black widget is what going over looks like"
                case .over: " - OVER THE LIMIT, the widget will drop lanes to fit"
                }
                return String(format: ", %.1fMB per archive%@", Double($0.bytes) / 1_048_576, note)
            } ?? ""
        ))
        // Last, so it is the line left on screen: a clip that ends early is the
        // thing people notice and the thing this used to say nothing about.
        if let notice = FrameSetGenerator.lengthNotice(for: design) {
            onProgress(notice.text)
        }
        return destination
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
        // Every starred design ships, not only the one just edited: the phone
        // switches between whatever is in the bundle, and a font has to be in
        // there to draw at all.
        var bundled: [BundleWriter.Bundled] = [
            .init(name: prepared.design.name, folder: built.folder, manifest: built.manifest),
        ]
        for design in Self.saved()
        where design.isStarred && design.id != prepared.design.id {
            guard let manifest = try? prepared.store.loadManifest(id: design.id) else {
                // Starred but never built, or built before its fonts were
                // cleared. Skipped rather than failing the build, and said so.
                onStage(.installing("\(design.name) is starred but has no build yet - skipped"))
                continue
            }
            bundled.append(.init(
                name: design.name,
                folder: prepared.store.folder(for: design.id),
                manifest: manifest
            ))
        }

        guard let projectRoot else { throw StudioPipelineError.noProjectFolder }
        try BundleWriter(projectRoot: projectRoot).install(
            bundled,
            iconsFolder: Self.iconsFolder(for: prepared.store),
            store: prepared.store
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
