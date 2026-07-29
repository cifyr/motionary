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
    }

    @ViewBuilder
    private var content: some View {
        if let source = imported() ?? bundled() {
            let _ = record(source: source)
            CompositionView(
                manifest: source.manifest,
                tiles: [],
                viewport: DeviceGeometry.widgetRect,
                wallpaper: source.backdrop,
                wallpaperRect: source.manifest.backdropRect,
                isAnimated: source.fontsUsable
            ) { _, _ in EmptyView() }
        } else {
            let _ = record(source: nil)
            PlaceholderView(message: "Open Motionary and add a clip.")
        }
    }

    /// The design chosen in the app, if it is built and its fonts will draw.
    private func imported() -> Source? {
        guard let store = try? DesignStore(),
              let design = ActiveDesign.resolve(in: store),
              let manifest = try? store.loadManifest(id: design.id)
        else { return nil }

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

    private func bundled() -> Source? {
        guard let manifest = PrebuiltDesign.manifest else { return nil }
        let fonts = PrebuiltDesign.fontReport(for: manifest)
        guard let url = PrebuiltDesign.backdropURL ?? PrebuiltDesign.wallpaperURL else { return nil }
        let longest = manifest.backdropRect.map { Int(max($0.width, $0.height)) }
            ?? Int(max(manifest.screenSize.width, manifest.screenSize.height))
        return Source(
            manifest: manifest,
            backdrop: ImageLoader.load(at: url, maxPixelSize: longest).map { Image(decorative: $0, scale: 1) },
            fontsUsable: fonts.resolvable == fonts.requested,
            origin: "bundled",
            scope: "UIAppFonts",
            name: "Wizard"
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
                : (source.fontsUsable ? "ok" : "ok, but still - the fonts would not draw")
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
        anim=\(source?.fontsUsable == true) \
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
