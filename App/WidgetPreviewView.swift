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

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let manifest, let report {
                    GeometryReader { geometry in
                        let aspect = manifest.widgetRect.width / manifest.widgetRect.height
                        let width = min(geometry.size.width, geometry.size.height * aspect)

                        LoopingCompositionView(
                            manifest: manifest,
                            tiles: design.tiles,
                            videoURL: store.previewVideoURL(for: design.id),
                            wallpaper: wallpaper
                        )
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

/// The widget's viewport onto a looping video of the composed scene, with the
/// same tiles drawn on top.
private struct LoopingCompositionView: View {
    let manifest: BuildManifest
    let tiles: [PlacedTile]
    let videoURL: URL
    let wallpaper: Image?

    var body: some View {
        GeometryReader { geometry in
            let viewport = manifest.widgetRect
            let scale = geometry.size.width / viewport.width
            let screen = CGSize(
                width: manifest.screenSize.width * scale,
                height: manifest.screenSize.height * scale
            )
            let originX = -viewport.minX * scale
            let originY = -viewport.minY * scale

            ZStack(alignment: .topLeading) {
                Color.black

                if let wallpaper {
                    wallpaper
                        .resizable()
                        .interpolation(.high)
                        .frame(width: screen.width, height: screen.height)
                        .offset(x: originX, y: originY)
                }

                LoopingVideoView(url: videoURL)
                    .frame(width: screen.width, height: screen.height)
                    .offset(x: originX, y: originY)

                ForEach(tiles) { tile in
                    TileView(tile: tile, side: tile.size * scale)
                        .frame(width: tile.size * scale, height: tile.size * scale)
                        .offset(
                            x: originX + tile.rect.minX * scale,
                            y: originY + tile.rect.minY * scale
                        )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .clipped()
    }
}

private struct LoopingVideoView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.play(url: url)
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {}

    static func dismantleUIView(_ view: PlayerView, coordinator: ()) {
        view.stop()
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        private var looper: AVPlayerLooper?
        private var queuePlayer: AVQueuePlayer?

        private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        func play(url: URL) {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let item = AVPlayerItem(url: url)
            let player = AVQueuePlayer()
            player.isMuted = true
            // AVPlayerLooper gives a gapless repeat; restarting on the
            // did-play-to-end notification visibly stutters at the wrap.
            looper = AVPlayerLooper(player: player, templateItem: item)
            playerLayer.player = player
            playerLayer.videoGravity = .resize
            queuePlayer = player
            player.play()
        }

        func stop() {
            queuePlayer?.pause()
            looper?.disableLooping()
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
