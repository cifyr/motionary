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
            .overlay(alignment: .bottom) {
#if DEBUG
                FontDiagnostics(entry: entry)
#endif
            }
            .widgetAccentable(false)
            .containerBackground(for: .widget) { Color.black }
    }

#if DEBUG
    /// Toggled by dropping a marker file into the app group, so the widget can
    /// be diagnosed without a rebuild.
    private var diagnosticsEnabled: Bool {
        guard let store = try? DesignStore() else { return false }
        let marker = store.root.deletingLastPathComponent().appendingPathComponent("diagnose")
        return FileManager.default.fileExists(atPath: marker.path)
    }
#endif

    @ViewBuilder
    private var content: some View {
        switch load() {
        case .success(let loaded):
            let _ = Self.logger.info(
                "WIDGET OK design=\(loaded.design.name, privacy: .public) family=\(family.rawValue) fonts=\(loaded.fontsReady)"
            )
            let _ = record(
                outcome: loaded.backdropLoaded ? "ok" : "ok, but the backdrop image did not load",
                design: loaded.design,
                report: loaded.report
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
                    record(outcome: message, design: nil, report: nil)
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
    }

    @discardableResult
    private func record(
        outcome: String,
        design: DesignDocument?,
        report: RuntimeFontRegistry.Report?
    ) -> Bool {
        let blinkResolved = CTFontCopyPostScriptName(
            CTFontCreateWithName(FontSetGenerator.blinkFontResourceName as CFString, 12, nil)
        ) as String == FontSetGenerator.blinkFontResourceName

        WidgetStatusLog.write(WidgetStatus(
            recordedAt: Date(),
            family: "\(family)",
            outcome: outcome,
            designName: design?.name,
            designSize: design?.widgetSize.title,
            laneFontResolved: (report?.resolvable ?? 0) > 0,
            blinkFontResolved: blinkResolved,
            lanesRequested: report?.requested ?? 0,
            lanesResolvable: report?.resolvable ?? 0,
            failures: Array((report?.failures ?? []).prefix(3))
        ))
        return true
    }

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

            // A design cut for one family renders wrong in another, and a
            // silently mis-cropped widget is harder to diagnose than a label.
            let expected = WidgetFamilyCompatibility.sizeOption(for: family)
            guard design.widgetSize == expected else {
                return .failure(
                    "\"\(design.name)\" is cut for \(design.widgetSize.title), but this is the "
                    + "\(expected.title) widget. Remove this one and add a \(design.widgetSize.title) "
                    + "widget, or change the design's size and rebuild."
                )
            }

            let report = RuntimeFontRegistry.register(manifest: manifest, store: store)

            let backdropURL = store.widgetBackdropURL(for: designID)
            let usesBackdrop = FileManager.default.fileExists(atPath: backdropURL.path)
            let imageURL = usesBackdrop ? backdropURL : store.wallpaperURL(for: designID)
            let loadedImage = UIImage(contentsOfFile: imageURL.path)
            let wallpaper = loadedImage.map { Image(uiImage: $0) }
            Self.logger.info("""
            backdrop=\(usesBackdrop ? "cropped" : "fullscreen", privacy: .public) \
            loaded=\(loadedImage != nil) \
            size=\(Int(loadedImage?.size.width ?? 0))x\(Int(loadedImage?.size.height ?? 0))
            """)

            return .success(Loaded(
                design: design,
                manifest: manifest,
                wallpaper: wallpaper,
                fontsReady: report.isUsable,
                icons: IconImageProvider(store: store),
                report: report,
                usesCroppedBackdrop: usesBackdrop,
                backdropLoaded: loadedImage != nil
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
    }
}

#if DEBUG
/// Draws the same timer text twice: once in the system font and once in a lane
/// font. The system copy shows whether the renderer is advancing timer text at
/// all; the lane copy shows whether it can resolve a font that was registered
/// at runtime rather than shipped in the bundle.
private struct FontDiagnostics: View {
    let entry: DesignEntry

    var body: some View {
        let reference = TimerFontSpec.cycleAlignedReference()
        VStack(spacing: 2) {
            Text(reference, style: .timer)
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundStyle(.green)

            if let name = laneFontName {
                // Drawn in a lane font, so this glyph IS an animation frame.
                // If it changes between two screenshots the animation is
                // advancing; if it is frozen, nothing is driving the timer.
                Text(reference, style: .timer)
                    .font(.custom(name, size: 90))
                    .foregroundStyle(.yellow)
                    .frame(height: 90)

                // The blink font drives sub-second lane switching. If it falls
                // back, the picture can only step once per glyph — two seconds
                // — which reads as barely animating.
                Text(reference, style: .timer)
                    .font(.custom(FontSetGenerator.blinkFontResourceName, size: 22))
                    .foregroundStyle(.cyan)

                HStack(spacing: 6) {
                    flag("L", ok: resolves(name))
                    flag("B", ok: resolves(FontSetGenerator.blinkFontResourceName))
                    Text("\(laneCount) lanes")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(.white)
                }
            } else {
                Text("no manifest").font(.system(size: 10)).foregroundStyle(.red)
            }
        }
        .padding(3)
        .background(.black.opacity(0.75))
    }

    private func flag(_ label: String, ok: Bool) -> some View {
        Text("\(label):\(ok ? "R" : "X")")
            .font(.system(size: 15, weight: .heavy))
            .foregroundStyle(ok ? .green : .red)
    }

    private var laneCount: Int {
        guard let id = entry.designID,
              let store = try? DesignStore(),
              let manifest = try? store.loadManifest(id: id)
        else { return 0 }
        return manifest.laneCount
    }

    private var laneFontName: String? {
        guard let id = entry.designID,
              let store = try? DesignStore(),
              let manifest = try? store.loadManifest(id: id)
        else { return nil }
        _ = RuntimeFontRegistry.register(manifest: manifest, store: store)
        return LaneFontBuilder.postScriptName(family: manifest.fontFamilyBase, lane: 0)
    }

    /// Resolution inside this process. If this says R but the yellow line draws
    /// plain digits, the renderer is a different process that cannot see it.
    private func resolves(_ name: String) -> Bool {
        CTFontCopyPostScriptName(CTFontCreateWithName(name as CFString, 12, nil)) as String == name
    }
}
#endif
