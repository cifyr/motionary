import CoreText
import SwiftUI
import WidgetKit
import os

/// Renders the one bundled design.
///
/// Reads nothing the extension did not ship with: the manifest, the backdrop
/// and the lane fonts are all bundle resources, and the fonts are registered by
/// the system from `UIAppFonts` before any of this runs. That is the
/// arrangement the Onewheel build uses on this same phone, and generating and
/// registering them at runtime instead was the one thing that differed while
/// the animated layer refused to draw.
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

    @ViewBuilder
    private var content: some View {
        if let manifest = PrebuiltDesign.manifest {
            let fonts = PrebuiltDesign.fontReport(for: manifest)
            let backdrop = loadBackdrop(manifest: manifest)
            let _ = record(manifest: manifest, fonts: fonts, backdropLoaded: backdrop != nil)

            CompositionView(
                manifest: manifest,
                tiles: [],
                viewport: DeviceGeometry.widgetRect,
                wallpaper: backdrop,
                wallpaperRect: manifest.backdropRect,
                isAnimated: fonts.resolvable == fonts.requested
            ) { _, _ in EmptyView() }
        } else {
            let _ = record(manifest: nil, fonts: (0, 0), backdropLoaded: false)
            PlaceholderView(message: "The bundled design is missing from this build.")
        }
    }

    private func loadBackdrop(manifest: BuildManifest) -> Image? {
        guard let url = PrebuiltDesign.backdropURL ?? PrebuiltDesign.wallpaperURL else { return nil }
        let longest = manifest.backdropRect.map { Int(max($0.width, $0.height)) }
            ?? Int(max(manifest.screenSize.width, manifest.screenSize.height))
        return ImageLoader.load(at: url, maxPixelSize: longest).map { Image(decorative: $0, scale: 1) }
    }

    /// The report still goes to the shared container, because it is the only
    /// way to see what the widget did. Nothing needed to draw depends on it.
    @discardableResult
    private func record(
        manifest: BuildManifest?,
        fonts: (resolvable: Int, requested: Int),
        backdropLoaded: Bool
    ) -> Bool {
        var status = WidgetStatus()
        status.outcome = manifest == nil
            ? "the bundled design is missing"
            : (fonts.resolvable == fonts.requested
                ? (backdropLoaded ? "ok" : "ok, but the bundled picture did not load")
                : "bundled fonts did not resolve: \(fonts.resolvable)/\(fonts.requested)")
        status.family = "\(family)"
        status.familyRawValue = family.rawValue
        status.renderedSize = Self.lastRenderedSize
        status.containerReachable = (try? DesignStore()) != nil
        status.storePath = "bundle"

        let blinkName = FontSetGenerator.blinkFontResourceName
        status.blinkFontResolved = CTFontCopyPostScriptName(
            CTFontCreateWithName(blinkName as CFString, 12, nil)
        ) as String == blinkName

        if let manifest {
            status.manifestFound = true
            status.designName = "Wizard (bundled)"
            status.designID = manifest.designID.uuidString
            status.designSize = WidgetSizeOption.fullScreen.title
            status.buildGeneration = manifest.buildGeneration
            status.laneCount = manifest.laneCount
            status.framesPerSecond = manifest.framesPerSecond
            status.loopFrameCount = manifest.loopFrameCount
            status.animationCrop = manifest.animationCrop
            status.widgetRect = DeviceGeometry.widgetRect
            status.screenSize = manifest.screenSize
            status.manifestFontBytes = manifest.totalFontBytes
            status.lanesRequested = fonts.requested
            status.lanesRegistered = fonts.resolvable
            status.lanesResolvable = fonts.resolvable
            status.designFolders = 1
            status.designsDecoded = 1

            if let url = PrebuiltDesign.backdropURL {
                status.backdropExists = true
                status.backdropBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
            status.wallpaperExists = PrebuiltDesign.wallpaperURL != nil
        }

        status.memoryFootprintMB = MemoryFootprint.megabytes
        WidgetStatusLog.write(status)
        WidgetRenderLog.append("""
        \(status.succeeded ? "OK  " : "FAIL") \(entry.isPreview ? "GALLERY" : "PLACED ") \
        bundled fonts=\(fonts.resolvable)/\(fonts.requested) backdrop=\(backdropLoaded) \
        \(Int(Self.lastRenderedSize.width))x\(Int(Self.lastRenderedSize.height)) \
        \(status.memoryFootprintMB)MB \(status.succeeded ? "" : status.outcome.prefix(48))
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
        // Redaction turns text into a grey bar, which is how this failure first
        // appeared: unreadable rather than merely unhappy.
        .unredacted()
    }
}
