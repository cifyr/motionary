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
                    // Reported, not learned: the provider records the size,
                    // because only it can tell a real widget from a gallery
                    // preview.
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
            // Recorded while the body is evaluated, never from `.onAppear`:
            // WidgetKit renders to a snapshot and does not reliably run
            // appearance callbacks, so a failure recorded there never
            // overwrote the last success. The report then said "ok" while the
            // widget on screen showed an error.
            let _ = record(
                outcome: loaded.outcome, design: loaded.design, manifest: loaded.manifest,
                report: loaded.report, backdrop: loaded.backdropFacts
            )
            PlaceholderView(
                message: "Could not load the picture for \"\(loaded.design.name)\". Open Motionary and rebuild this design."
            )

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
                isAnimated: loaded.fontsReady
            ) { tile, side in
                Link(destination: LaunchLink.url(for: tile.appID)) {
                    TileView(tile: tile, side: side, iconImage: loaded.icons.image(for: tile))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(AppCatalog.app(id: tile.appID)?.name ?? tile.appID)")
            }
        case .failure(let message):
            let _ = Self.logger.error("WIDGET FAILURE: \(message, privacy: .public)")
            let _ = record(outcome: message, design: nil, manifest: nil, report: nil)
            PlaceholderView(message: message)
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
        let sizeMatches: Bool
        let backdropFacts: (exists: Bool, bytes: Int, decoded: CGSize)

        var outcome: String {
            if !backdropLoaded { return "ok, but the backdrop image did not load" }
            if !sizeMatches {
                return "ok, but the frame the system gave this widget is not the calibrated "
                    + "tall portrait size. The composition is scaled to fit it."
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
            status.activeSelection = ActiveDesign.identifier?.uuidString
            let folders = ((try? FileManager.default.contentsOfDirectory(atPath: store.root.path)) ?? [])
                .compactMap { UUID(uuidString: $0) }
            status.designFolders = folders.count

            // Swept on every render, not only on failure. Skipping it left
            // "folders 1, decoded 0" on a perfectly good render, which reads as
            // a store full of unreadable designs. A handful of small JSON files
            // is worth an honest number.
            for id in folders {
                do {
                    _ = try store.load(id: id)
                    status.designsDecoded += 1
                } catch {
                    let reason = String(describing: error).prefix(120)
                    status.decodeErrors.append("\(id.uuidString.prefix(8)) \(reason)")
                }
            }
            status.decodeErrors = Array(status.decodeErrors.prefix(3))

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
        do {
            let store = try DesignStore()

            // The entry only records which design was current when the timeline
            // was built, which may be long ago and may have been nothing at
            // all. Trusting it meant one nil entry pinned the widget to
            // "create a design" no matter what the store held afterwards, even
            // across a remove and re-add. Resolving here costs one directory
            // read and always reflects the container as it is now.
            let design: DesignDocument
            if let id = entry.designID, let fromEntry = try? store.load(id: id) {
                design = fromEntry
            } else if let resolved = ActiveDesign.resolve(in: store) {
                Self.logger.info("entry had no usable design; resolved \(resolved.id.uuidString, privacy: .public) live")
                design = resolved
            } else {
                return .failure("Open Motionary to create a design.")
            }

            let designID = design.id
            guard let manifest = try? store.loadManifest(id: designID) else {
                return .failure("\"\(design.name)\" has not been built yet. Open Motionary, open the design, and tap Build widget.")
            }

            // Reported by measurement, never by the family enum, which on iOS 27
            // has named two different families for one widget rendering at an
            // identical size. Only the tall portrait family is advertised now,
            // so this is a sanity check rather than a branch: it should only
            // fail on a system old enough to fall back to the large square.
            let expected = design.widgetRect.size
            let actual = CGSize(
                width: Self.lastRenderedSize.width * DeviceGeometry.scale,
                height: Self.lastRenderedSize.height * DeviceGeometry.scale
            )
            let sizeMatches = actual.width < 1 || actual.height < 1
                || (abs(expected.width - actual.width) < expected.width * 0.05
                    && abs(expected.height - actual.height) < expected.height * 0.05)

            let report = RuntimeFontRegistry.register(manifest: manifest, store: store)

            // The full composition, not the pre-cropped backdrop: only the
            // full one is guaranteed to cover whatever size the system gives.
            let usesBackdrop = false
            let imageURL = store.wallpaperURL(for: designID)
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
                sizeMatches: sizeMatches,
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
