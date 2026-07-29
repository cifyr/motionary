import CoreText
import SwiftUI
import WidgetKit

/// Renders one design inside whatever family the system asked for.
///
/// Everything comes from the shared container at render time, which is what
/// lets a single installed extension present designs it never shipped with.
struct DesignWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DesignEntry

    var body: some View {
        content
            .overlay(alignment: .bottom) {
#if DEBUG
                if ProcessInfo.processInfo.environment["MOTIONARY_DIAGNOSE"] != nil || diagnosticsEnabled {
                    FontDiagnostics(entry: entry)
                }
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
            PlaceholderView(message: message)
        }
    }

    private struct Loaded {
        let design: DesignDocument
        let manifest: BuildManifest
        let wallpaper: Image?
        let fontsReady: Bool
        let icons: IconImageProvider
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
                return .failure("\"\(design.name)\" is cut for \(design.widgetSize.title). Add the \(design.widgetSize.title) widget instead.")
            }

            let report = RuntimeFontRegistry.register(manifest: manifest, store: store)
            let wallpaperURL = store.wallpaperURL(for: designID)
            let wallpaper = UIImage(contentsOfFile: wallpaperURL.path).map { Image(uiImage: $0) }

            return .success(Loaded(
                design: design,
                manifest: manifest,
                wallpaper: wallpaper,
                fontsReady: report.isUsable,
                icons: IconImageProvider(store: store)
            ))
        } catch {
            return .failure(String(describing: error))
        }
    }
}

private struct PlaceholderView: View {
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "wand.and.sparkles")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        VStack(spacing: 1) {
            Text(reference, style: .timer)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(.green)

            if let name = laneFontName {
                Text(reference, style: .timer)
                    .font(.custom(name, size: 15))
                    .foregroundStyle(.yellow)
                Text(resolves(name) ? "R" : "X")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(resolves(name) ? .green : .red)
            } else {
                Text("no manifest").font(.system(size: 10)).foregroundStyle(.red)
            }
        }
        .padding(3)
        .background(.black.opacity(0.75))
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
