import CoreText
import SwiftUI
import WidgetKit
import os

/// Renders the current design, preferring one you imported and falling back to
/// the design bundled with the app.
///
/// The fallback is the point. A widget that draws nothing looks identical to a
/// widget that is broken, and this one spent a long night black. If an imported
/// design cannot be drawn — not built yet, fonts that will not register — the
/// bundled one still can, so the Home Screen always shows something real and
/// the report says which was used.
struct DesignWidgetView: View {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "Widget")

    @Environment(\.widgetFamily) private var family
    let entry: DesignEntry

    var body: some View {
        content
            .background {
                GeometryReader { geometry in
                    Color.clear.onAppear { Self.lastRenderedSize = geometry.size }
                }
            }
            .widgetAccentable(false)
            .containerBackground(for: .widget) { Color.black }
    }

    /// Where a renderable design came from, and everything needed to draw it.
    private struct Source {
        let manifest: BuildManifest
        let backdrop: Image?
        let fontsUsable: Bool
        let origin: String
        let scope: String
        let name: String
        /// Set when the design animates from pictures in the app group instead
        /// of from lane fonts in the bundle.
        var frames: RuntimeFrameLayer.Payload?

        /// Which of the two animations this render used, in words the report
        /// prints. Two routes now reach the same widget and they fail in
        /// different ways, so a report that does not name the route is a report
        /// that cannot be acted on.
        var animationPath: String {
            if let frames {
                return "runtime frames: \(frames.loadedCount)/\(frames.sequence.frameCount) "
                    + "\(frames.sequence.layout.rawValue) at \(frames.sequence.framesPerSecond)fps, "
                    + "\(Int(frames.sequence.frameSize.width))x\(Int(frames.sequence.frameSize.height))px, "
                    + "\(String(format: "%.2f", BlinkCycle.cycleDuration))s cycle"
            }
            return fontsUsable
                ? "lane fonts: \(manifest.laneCount) bundled at \(manifest.framesPerSecond)fps"
                : "still: no animation layer drew"
        }

        var isAnimating: Bool { frames?.isDrawable == true || fontsUsable }
    }

    @ViewBuilder
    private var content: some View {
        if FontLab.isEnabled, let lab = lab() {
            lab
        } else if let source = imported() ?? bundled() {
            let _ = record(source: source)
            CompositionView(
                manifest: source.manifest,
                tiles: source.manifest.placedTiles,
                viewport: DeviceGeometry.widgetRect,
                wallpaper: source.backdrop,
                wallpaperRect: source.manifest.backdropRect,
                isAnimated: source.fontsUsable,
                runtimeFrames: source.frames
            ) { tile, side in
                // Through the app rather than straight to the destination: a
                // Link from an extension to a third-party scheme is
                // unreliable, so the app takes the tap and forwards it.
                Link(destination: LaunchLink.url(for: tile.appID)) {
                    TileView(
                        tile: tile,
                        side: side,
                        iconImage: PrebuiltDesign.iconURL(tileID: tile.id)
                            .flatMap { ImageLoader.load(at: $0, maxPixelSize: Int(side * 3)) }
                            .map { Image(decorative: $0, scale: 1) }
                    )
                }
            }
        } else {
            let _ = record(source: nil)
            PlaceholderView(message: "Open Motionary and add a clip.")
        }
    }

    /// The font lab, when it is switched on and there is an imported design
    /// whose lane fonts it can try to deliver nine different ways.
    private func lab() -> FontLabView? {
        guard let store = try? DesignStore() else { return nil }
        // Logged step by step: the widget came back black with not even a
        // label drawn, which means the extension stopped somewhere before the
        // view existed. A black rectangle cannot say where.
        WidgetRenderLog.append("lab  enter \(MemoryFootprint.megabytes)MB")
        let importedManifest = ActiveDesign.resolve(in: store)
            .flatMap { try? store.loadManifest(id: $0.id) }
        guard let manifest = importedManifest ?? PrebuiltDesign.manifest else {
            WidgetRenderLog.append("lab  no manifest")
            return nil
        }

        WidgetRenderLog.append("lab  manifest \(MemoryFootprint.megabytes)MB")
        let outcomes = FontLab.run(manifest: manifest, store: store)
        WidgetRenderLog.append("""
        lab  prepared \(outcomes.filter(\.isDrawable).count)/\(outcomes.count) \
        \(MemoryFootprint.megabytes)MB
        """)
        FontLab.record(outcomes, store: store)
        return FontLabView(
            manifest: manifest,
            outcomes: outcomes,
            viewport: DeviceGeometry.widgetRect
        )
    }

    /// The design chosen in the app, if it is built and its fonts will draw.
    private func imported() -> Source? {
        guard let store = try? DesignStore(),
              let design = ActiveDesign.resolve(in: store),
              let manifest = try? store.loadManifest(id: design.id)
        else { return nil }

        if manifest.resolvedAnimationSource == .runtimeImages, let sequence = manifest.frameSequence {
            return runtimeFrameSource(
                design: design,
                manifest: manifest,
                sequence: sequence,
                store: store
            )
        }

        // Animated only when the lane fonts shipped in this build. Runtime
        // registration reports every lane usable on iOS 27 and then draws
        // nothing, so an imported design is shown as a still picture rather
        // than gambling the whole widget on fonts that resolve but do not
        // render. A still upload is a poor outcome; a black one is a worse
        // outcome that looks identical to broken.
        let bundledFonts = PrebuiltDesign.fontsAreBundled(familyBase: manifest.fontFamilyBase)
        if bundledFonts {
            _ = RuntimeFontRegistry.register(manifest: manifest, store: store)
        }
        return Source(
            manifest: manifest,
            backdrop: backdrop(manifest: manifest, store: store, designID: design.id),
            fontsUsable: bundledFonts,
            origin: "imported",
            scope: bundledFonts ? "bundled" : "still - fonts not in this build",
            name: design.name
        )
    }

    /// The runtime-frame route: pictures out of the app group, revealed by the
    /// one font that already ships with the extension.
    ///
    /// Logged step by step with the footprint after each, because the memory
    /// answer is the one that decides this. A stack of full-frame images has a
    /// point where it stops fitting under the widget's cap, and past that point
    /// the render is simply dropped - a blank widget, with nothing anywhere
    /// saying why. The only way to see it coming is to watch the number climb.
    private func runtimeFrameSource(
        design: DesignDocument,
        manifest: BuildManifest,
        sequence: RuntimeFrameSequence,
        store: DesignStore
    ) -> Source {
        WidgetRenderLog.append("img  enter \(sequence.summary) \(MemoryFootprint.megabytes)MB")
        let loaded = RuntimeFrameLoader.load(sequence: sequence, designID: design.id, in: store)
        WidgetRenderLog.append("img  loaded \(loaded.note) \(loaded.footprintMB)MB")

        return Source(
            manifest: manifest,
            backdrop: backdrop(manifest: manifest, store: store, designID: design.id),
            // The lane fonts are irrelevant here and there are none: saying yes
            // would put a second animated layer on top drawing from fonts that
            // do not exist.
            fontsUsable: false,
            origin: "imported",
            scope: loaded.payload.isDrawable
                ? "runtime frames from the app group"
                : "still - the frames are not on disk",
            name: design.name,
            frames: loaded.payload
        )
    }

    private func bundled() -> Source? {
        // Whichever the app last chose, so the Home Screen follows a swipe.
        guard let entry = PrebuiltDesign.selected(), let manifest = entry.manifest else { return nil }
        let fonts = PrebuiltDesign.fontReport(for: manifest)
        guard let url = entry.backdropURL ?? entry.wallpaperURL else { return nil }
        let longest = manifest.backdropRect.map { Int(max($0.width, $0.height)) }
            ?? Int(max(manifest.screenSize.width, manifest.screenSize.height))
        return Source(
            manifest: manifest,
            backdrop: ImageLoader.load(at: url, maxPixelSize: longest).map { Image(decorative: $0, scale: 1) },
            fontsUsable: fonts.resolvable == fonts.requested,
            origin: "bundled",
            scope: "UIAppFonts",
            name: entry.name
        )
    }

    private func backdrop(manifest: BuildManifest, store: DesignStore, designID: UUID) -> Image? {
        let cropped = store.widgetBackdropURL(for: designID)
        let usesCrop = manifest.backdropRect != nil
            && FileManager.default.fileExists(atPath: cropped.path)
        let url = usesCrop ? cropped : store.wallpaperURL(for: designID)
        let covered = usesCrop
            ? manifest.backdropRect
            : CGRect(origin: .zero, size: manifest.screenSize)
        let longest = Int(max(covered?.width ?? 0, covered?.height ?? 0))
        return ImageLoader.load(at: url, maxPixelSize: longest).map { Image(decorative: $0, scale: 1) }
    }

    @discardableResult
    private func record(source: Source?) -> Bool {
        var status = WidgetStatus()
        status.family = "\(family)"
        status.familyRawValue = family.rawValue
        status.renderedSize = Self.lastRenderedSize
        status.containerReachable = (try? DesignStore()) != nil

        let blinkName = FontSetGenerator.blinkFontResourceName
        status.blinkFontResolved = CTFontCopyPostScriptName(
            CTFontCreateWithName(blinkName as CFString, 12, nil)
        ) as String == blinkName

        if let source {
            status.outcome = source.backdrop == nil
                ? "ok, but the picture did not load"
                : (source.isAnimating ? "ok" : "ok, but still - no animation layer drew")
            status.animationSource = source.manifest.resolvedAnimationSource.rawValue
            status.animationPath = source.animationPath
            if let frames = source.frames {
                status.frameCycleSeconds = BlinkCycle.cycleDuration
                status.framesRequested = frames.sequence.frameCount
                status.framesLoaded = frames.loadedCount
                status.frameLayout = frames.sequence.layout.rawValue
                status.frameSize = frames.sequence.frameSize
                status.frameBytesOnDisk = frames.sequence.totalFrameBytes
                status.frameFilesOnDisk = (try? DesignStore())
                    .map { $0.frameFileCount(for: source.manifest.designID) } ?? 0
                status.sourceRepeats = frames.sequence.sourceRepeats
                status.playbackSpeed = frames.sequence.speed
            }
            status.manifestFound = true
            status.designName = "\(source.name) (\(source.origin))"
            status.designID = source.manifest.designID.uuidString
            status.designSize = WidgetSizeOption.fullScreen.title
            status.storePath = "\(source.origin) via \(source.scope)"
            status.buildGeneration = source.manifest.buildGeneration
            status.laneCount = source.manifest.laneCount
            status.framesPerSecond = source.manifest.framesPerSecond
            status.loopFrameCount = source.manifest.loopFrameCount
            status.animationCrop = source.manifest.animationCrop
            status.widgetRect = DeviceGeometry.widgetRect
            status.screenSize = source.manifest.screenSize
            status.manifestFontBytes = source.manifest.totalFontBytes
            status.lanesRequested = source.manifest.laneCount
            status.lanesResolvable = source.fontsUsable ? source.manifest.laneCount : 0
            status.lanesRegistered = status.lanesResolvable
            status.backdropExists = source.backdrop != nil
        } else {
            status.outcome = "nothing to draw: no imported design and no bundled one"
        }

        status.memoryFootprintMB = MemoryFootprint.megabytes
        WidgetStatusLog.write(status)
        WidgetRenderLog.append("""
        \(status.succeeded ? "OK  " : "FAIL") \(entry.isPreview ? "GALLERY" : "PLACED ") \
        \(source?.origin ?? "none")/\(source?.scope ?? "-") \
        path=\(source?.animationPath ?? "none") \
        \(Int(Self.lastRenderedSize.width))x\(Int(Self.lastRenderedSize.height)) \
        \(status.memoryFootprintMB)MB
        """)
        return true
    }

    /// The real size the system gave the widget, captured while drawing.
    nonisolated(unsafe) static var lastRenderedSize: CGSize = .zero
}

private struct PlaceholderView: View {
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.yellow)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .unredacted()
    }
}
