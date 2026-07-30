import CoreGraphics
import Foundation
import os

/// Takes a clip and produces a design the widget can animate, entirely on the
/// phone.
///
/// This is the whole point of the runtime-frame route. The lane-font route needs
/// the clip to reach a Mac, be turned into 64 colour-glyph fonts, be compiled
/// into the widget extension's bundle and be installed - because a widget
/// renderer will not draw a font that was not in its bundle at install time.
/// Nothing here is compiled, so the phone can go from a picked video to an
/// animating Home Screen widget without a toolchain in the loop.
struct RuntimeDesignImporter {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "RuntimeImport")

    struct Options: Equatable, Sendable {
        var framesPerSecond = 32
        var layout = RuntimeFrameSequence.Layout.separate
        var quality: Double = 0.82

        /// Frames this will write.
        var frameCount: Int { BlinkCycle.frameCount(framesPerSecond: framesPerSecond) }
    }

    let store: DesignStore
    let screenSize: CGSize

    init(store: DesignStore, screenSize: CGSize = DeviceGeometry.screenPixelSize) {
        self.store = store
        self.screenSize = screenSize
    }

    /// Copies the clip into its own design folder and returns the design.
    ///
    /// Named for what the bytes are rather than what the file was called: the
    /// extractor picks its decoder from the extension, and a GIF exported from
    /// Photos arrives with any name at all.
    func makeDesign(from data: Data, name: String, options: Options) throws -> DesignDocument {
        let isGIF = data.starts(with: Data("GIF8".utf8))
        var design = DesignDocument.new(
            name: name.isEmpty ? "Clip" : name,
            sourceVideoName: isGIF ? "source.gif" : "source.mov"
        )
        design.animationSource = .runtimeImages
        design.runtimeFramesPerSecond = BlinkCycle.clampedFramesPerSecond(options.framesPerSecond)
        design.runtimeLayout = options.layout
        design.runtimeQuality = options.quality

        try store.createFolder(for: design.id)
        let destination = store.sourceVideoURL(for: design)
        do {
            try data.write(to: destination, options: DesignStore.writingOptions)
        } catch {
            throw RuntimeBuildError.writeFailed(path: destination.path, underlying: error)
        }
        try store.save(design)
        Self.logger.info("""
        imported \(data.count) bytes as \(design.sourceVideoName, privacy: .public) \
        for \(design.id.uuidString, privacy: .public)
        """)
        return design
    }

    /// The whole job: copy the clip in, build the frames, and make the design
    /// the one the widget shows.
    func run(
        sourceData: Data,
        name: String,
        options: Options,
        onStage: @Sendable @escaping (RuntimeFrameBuilder.Stage) -> Void = { _ in }
    ) async throws -> (design: DesignDocument, manifest: BuildManifest) {
        let design = try makeDesign(from: sourceData, name: name, options: options)
        do {
            let built = try await RuntimeFrameBuilder(store: store, screenSize: screenSize)
                .build(design: design, onStage: onStage)
            // Selected here rather than by the caller: an import that leaves the
            // widget showing the previous design looks like an import that did
            // nothing, and that is the failure this project keeps repeating.
            ActiveDesign.identifier = built.design.id
            return built
        } catch {
            // The half-written design would otherwise sit in the library
            // undecodable-adjacent: it decodes fine and has no frames, so the
            // widget picks it and draws a still. Better to take it away and say
            // what happened.
            try? store.archive(id: design.id)
            Self.logger.error("""
            import of \(name, privacy: .public) failed and was rolled back: \
            \(String(describing: error), privacy: .public)
            """)
            throw error
        }
    }

    func run(
        sourceAt url: URL,
        options: Options,
        onStage: @Sendable @escaping (RuntimeFrameBuilder.Stage) -> Void = { _ in }
    ) async throws -> (design: DesignDocument, manifest: BuildManifest) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw MediaImportError.unreadable(url: url, underlying: error)
        }
        return try await run(
            sourceData: data,
            name: url.deletingPathExtension().lastPathComponent,
            options: options,
            onStage: onStage
        )
    }

    /// Designs in the store that were built the runtime-frame way and have a
    /// manifest to draw from.
    static func builtDesigns(in store: DesignStore) -> [(design: DesignDocument, manifest: BuildManifest)] {
        store.loadAll().compactMap { design in
            guard let manifest = try? store.loadManifest(id: design.id),
                  manifest.resolvedAnimationSource == .runtimeImages,
                  manifest.frameSequence != nil
            else { return nil }
            return (design, manifest)
        }
    }
}
