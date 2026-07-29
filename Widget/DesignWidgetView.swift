import CoreText
import SwiftUI
import WidgetKit
import os

/// Renders one design inside whatever family the system asked for.
///
/// Everything comes from the shared container at render time, which is what
/// lets a single installed extension present designs it never shipped with.
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
        switch load() {
        case .success(let loaded) where !loaded.backdropLoaded:
            PlaceholderView(
                message: "Could not load the picture for \"\(loaded.design.name)\". Open Motionary and rebuild this design."
            )
            .onAppear {
                record(
                    outcome: loaded.outcome, design: loaded.design, manifest: loaded.manifest,
                    report: loaded.report, backdrop: loaded.backdropFacts
                )
            }

        case .success(let loaded):
            let _ = Self.logger.info(
                "WIDGET OK design=\(loaded.design.name, privacy: .public) family=\(family.rawValue) fonts=\(loaded.fontsReady)"
            )
            let _ = record(
                outcome: loaded.outcome, design: loaded.design, manifest: loaded.manifest,
                report: loaded.report, backdrop: loaded.backdropFacts
            )
            CompositionView(
                manifest: loaded.manifest,
                tiles: loaded.design.tiles,
                // The design's current rect, not the one baked at build time,
                // so a calibration fix or a nudge takes effect immediately
                // instead of requiring every font to be regenerated. The glyphs
                // place the animated crop in screen coordinates, so moving the
                // viewport moves the whole composition together.
                viewport: loaded.design.widgetRect,
                wallpaper: loaded.wallpaper,
                wallpaperIsWidgetSized: loaded.usesCroppedBackdrop,
                isAnimated: loaded.fontsReady
            ) { tile, side in
                Link(destination: LaunchLink.url(for: tile.appID)) {
                    TileView(tile: tile, side: side, iconImage: loaded.icons.image(for: tile))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(AppCatalog.app(id: tile.appID)?.name ?? tile.appID)")
            }
        case .failure(let message):
            PlaceholderView(message: message)
                .onAppear {
                    Self.logger.error("WIDGET FAILURE: \(message, privacy: .public)")
                    record(outcome: message, design: nil, manifest: nil, report: nil)
                }
        }
    }

    private struct Loaded {
        let design: DesignDocument
        let manifest: BuildManifest
        let wallpaper: Image?
        let fontsReady: Bool
        let icons: IconImageProvider
        let report: RuntimeFontRegistry.Report
        let usesCroppedBackdrop: Bool
        let backdropLoaded: Bool
        let familyMatches: Bool
        let backdropFacts: (exists: Bool, bytes: Int, decoded: CGSize)

        var outcome: String {
            if !backdropLoaded { return "ok, but the backdrop image did not load" }
            if !familyMatches {
                return "ok, but this design is cut for \(design.widgetSize.title); "
                    + "set the design to this widget's size and rebuild for an exact fit"
            }
            return "ok"
        }
    }

    @discardableResult
    private func record(
        outcome: String,
        design: DesignDocument?,
        manifest: BuildManifest?,
        report: RuntimeFontRegistry.Report?,
        backdrop: (exists: Bool, bytes: Int, decoded: CGSize)? = nil
    ) -> Bool {
        var status = WidgetStatus()
        status.outcome = outcome
        status.family = "\(family)"
        status.familyRawValue = family.rawValue
        status.renderedSize = Self.lastRenderedSize

        let blinkName = FontSetGenerator.blinkFontResourceName
        status.blinkFontResolved = CTFontCopyPostScriptName(
            CTFontCreateWithName(blinkName as CFString, 12, nil)
        ) as String == blinkName

        if let store = try? DesignStore() {
            status.containerReachable = true
            if let design {
                status.designID = design.id.uuidString
                status.designName = design.name
                status.designSize = design.widgetSize.title
                status.buildGeneration = design.buildGeneration
                status.widgetRect = design.widgetRect

                let fonts = (try? FileManager.default.contentsOfDirectory(
                    at: store.fontsFolder(for: design.id), includingPropertiesForKeys: [.fileSizeKey]
                )) ?? []
                status.fontFilesOnDisk = fonts.count
                status.fontBytesOnDisk = fonts.reduce(0) {
                    $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }

                let wallpaper = store.wallpaperURL(for: design.id)
                status.wallpaperExists = FileManager.default.fileExists(atPath: wallpaper.path)
                status.wallpaperBytes = fileSize(wallpaper)
            }
        }

        if let manifest {
            status.manifestFound = true
            status.laneCount = manifest.laneCount
            status.framesPerSecond = manifest.framesPerSecond
            status.loopFrameCount = manifest.loopFrameCount
            status.animationCrop = manifest.animationCrop
            status.screenSize = manifest.screenSize
            status.manifestFontBytes = manifest.totalFontBytes
            if status.widgetRect == .zero { status.widgetRect = manifest.widgetRect }
        }

        if let report {
            status.lanesRequested = report.requested
            status.lanesRegistered = report.registered
            status.lanesResolvable = report.resolvable
            status.fontFailures = Array(report.failures.prefix(4))
        }

        if let backdrop {
            status.backdropExists = backdrop.exists
            status.backdropBytes = backdrop.bytes
            status.backdropDecoded = backdrop.decoded
        }

        status.memoryFootprintMB = MemoryFootprint.megabytes
        WidgetStatusLog.write(status)
        return true
    }

    private func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// The real size the system gave the widget, captured while drawing so the
    /// report can compare it against the geometry table.
    nonisolated(unsafe) static var lastRenderedSize: CGSize = .zero

    private enum LoadOutcome {
        case success(Loaded)
        case failure(String)
    }

    private func load() -> LoadOutcome {
        guard let designID = entry.designID else {
            return .failure("Open Motionary to create a design.")
        }
        do {
            let store = try DesignStore()
            let design = try store.load(id: designID)
            let manifest = try store.loadManifest(id: designID)

            // A design cut for another family still draws: the composition is
            // positioned in screen space, so a different family is a different
            // sized window onto it. Refusing produced a blank widget, which is
            // worse than a window that does not quite line up.
            let expected = WidgetFamilyCompatibility.sizeOption(for: family)
            let familyMatches = design.widgetSize == expected

            let report = RuntimeFontRegistry.register(manifest: manifest, store: store)

            let backdropURL = store.widgetBackdropURL(for: designID)
            let usesBackdrop = FileManager.default.fileExists(atPath: backdropURL.path)
            let imageURL = usesBackdrop ? backdropURL : store.wallpaperURL(for: designID)
            // Cap the decode: the fallback is a full-screen PNG, and decoding
            // it whole is a plausible way to end up with nothing to draw.
            let maxPixels = Int(max(manifest.screenSize.width, manifest.screenSize.height))
            let loadedImage = ImageLoader.load(at: imageURL, maxPixelSize: maxPixels)
            let wallpaper = loadedImage.map { Image(decorative: $0, scale: 1) }
            Self.logger.info("""
            backdrop=\(usesBackdrop ? "cropped" : "fullscreen", privacy: .public) \
            loaded=\(loadedImage != nil) \
            size=\(loadedImage?.width ?? 0)x\(loadedImage?.height ?? 0)
            """)

            return .success(Loaded(
                design: design,
                manifest: manifest,
                wallpaper: wallpaper,
                fontsReady: report.isUsable,
                icons: IconImageProvider(store: store),
                report: report,
                usesCroppedBackdrop: usesBackdrop,
                backdropLoaded: loadedImage != nil,
                familyMatches: familyMatches,
                backdropFacts: (
                    exists: FileManager.default.fileExists(atPath: imageURL.path),
                    bytes: (try? imageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0,
                    decoded: CGSize(width: loadedImage?.width ?? 0, height: loadedImage?.height ?? 0)
                )
            ))
        } catch {
            return .failure(String(describing: error))
        }
    }
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
                // White, not `.secondary`: grey on the black container
                // background is unreadable, which turns a diagnosable failure
                // into a blank rectangle.
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        // Redaction turns text into a grey bar and an icon into a grey square,
        // which is exactly how this failure looked on device: unreadable.
        .unredacted()
    }
}
