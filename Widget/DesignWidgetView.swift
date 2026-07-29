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
            .widgetAccentable(false)
            .containerBackground(for: .widget) { Color.black }
    }

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
                    TileView(tile: tile, side: side)
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
                fontsReady: report.isUsable
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
