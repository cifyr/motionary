import AVKit
import SwiftUI

/// Shows exactly what the widget will render, using the same manifest,
/// registry, and composition the extension uses.
///
/// This is the only way to see the animation without leaving the app, and it
/// is also how a font-registration failure surfaces as a message instead of a
/// blank rectangle.
struct WidgetPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let design: DesignDocument
    let store: DesignStore

    @State private var manifest: BuildManifest?
    @State private var report: RuntimeFontRegistry.Report?
    @State private var failure: String?
    @State private var wallpaper: Image?
    @StateObject private var icons = IconImageLoader(store: try? DesignStore())

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let manifest, let report {
                    GeometryReader { geometry in
                        let viewport = design.widgetRect
                        let aspect = viewport.width / viewport.height
                        let width = min(geometry.size.width, geometry.size.height * aspect)

                        LoopingCompositionView(
                            screenSize: manifest.screenSize,
                            viewport: viewport,
                            tiles: design.tiles,
                            videoURL: store.previewVideoURL(for: design.id),
                            wallpaper: wallpaper
                        ) { tile, side in
                            TileView(tile: tile, side: side, iconImage: icons.image(for: tile))
                        }
                        .frame(width: width, height: width / aspect)
                        .clipShape(RoundedRectangle(cornerRadius: width * 0.09, style: .continuous))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    }

                    RegistrationSummary(report: report, manifest: manifest)
                } else if let failure {
                    FailureView(title: "Nothing to preview", message: failure)
                } else {
                    ProgressView()
                }
            }
            .padding()
            .navigationTitle("Widget preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task { load() }
        }
    }

    private func load() {
        do {
            let manifest = try store.loadManifest(id: design.id)
            self.manifest = manifest
            report = RuntimeFontRegistry.register(manifest: manifest, store: store)
            let url = store.wallpaperURL(for: design.id)
            wallpaper = UIImage(contentsOfFile: url.path).map { Image(uiImage: $0) }
        } catch {
            failure = String(describing: error)
        }
    }
}

private struct RegistrationSummary: View {
    let report: RuntimeFontRegistry.Report
    let manifest: BuildManifest

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                report.isUsable
                    ? "\(report.resolvable)/\(report.requested) lane fonts registered"
                    : "Only \(report.resolvable)/\(report.requested) lane fonts registered",
                systemImage: report.isUsable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(report.isUsable ? .green : .orange)
            .font(.footnote)

            Text("\(manifest.framesPerSecond) fps · \(Int(manifest.animationCrop.width))x\(Int(manifest.animationCrop.height)) px · \(ByteCountFormatter.string(fromByteCount: Int64(manifest.totalFontBytes), countStyle: .file))")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach(report.failures.prefix(4), id: \.self) { failure in
                Text(failure).font(.caption2).foregroundStyle(.red).monospaced()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
