import AVFoundation
import SwiftUI
import UIKit

/// A viewport onto a design's composed scene: wallpaper, the looping video, and
/// the placed tiles, all laid out from the same screen pixel coordinates.
///
/// The app plays a video rather than the lane fonts because only the system
/// widget renderer advances timer text fast enough to drive those.
struct LoopingCompositionView<Tile: View>: View {
    /// How screen pixels map to points.
    enum ScaleMode {
        /// Life size: one screen pixel is one device pixel. Used anywhere the
        /// result has to line up with the real Home Screen.
        case device
        /// Shrink to fit the available width, for a scaled-down mock.
        case fitWidth
    }

    @Environment(\.displayScale) private var displayScale

    let screenSize: CGSize
    /// Region of the screen to show, in screen pixels. Under `.device` only its
    /// origin matters; the visible extent comes from the real view size.
    let viewport: CGRect
    let tiles: [PlacedTile]
    let videoURL: URL?
    let wallpaper: Image?
    var scaleMode: ScaleMode = .fitWidth
    @ViewBuilder let tileContent: (PlacedTile, CGFloat) -> Tile

    var body: some View {
        GeometryReader { geometry in
            let scale = scaleMode == .device
                ? 1 / max(displayScale, 1)
                : geometry.size.width / viewport.width
            let screen = CGSize(width: screenSize.width * scale, height: screenSize.height * scale)
            // At device scale the viewport's top-left pins to the view's
            // top-left; centring would reintroduce a dependency on the assumed
            // viewport size being exactly the real one.
            let centreX = scaleMode == .device ? 0 : (geometry.size.width - viewport.width * scale) / 2
            let centreY = scaleMode == .device ? 0 : (geometry.size.height - viewport.height * scale) / 2
            let originX = -viewport.minX * scale + centreX
            let originY = -viewport.minY * scale + centreY

            ZStack(alignment: .topLeading) {
                Color.black

                if let wallpaper {
                    wallpaper
                        .resizable()
                        .interpolation(.high)
                        .frame(width: screen.width, height: screen.height)
                        .offset(x: originX, y: originY)
                }

                if let videoURL {
                    LoopingVideoView(url: videoURL)
                        .frame(width: screen.width, height: screen.height)
                        .offset(x: originX, y: originY)
                        .allowsHitTesting(false)
                }

                ForEach(tiles) { tile in
                    tileContent(tile, tile.size * scale)
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

struct LoopingVideoView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.play(url: url)
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        view.play(url: url)
    }

    static func dismantleUIView(_ view: PlayerView, coordinator: ()) {
        view.stop()
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }

        private var looper: AVPlayerLooper?
        private var queuePlayer: AVQueuePlayer?
        private var currentURL: URL?

        private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        func play(url: URL) {
            guard currentURL != url else { return }
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            stop()

            let player = AVQueuePlayer()
            player.isMuted = true
            // AVPlayerLooper repeats gaplessly; restarting on the
            // did-play-to-end notification visibly stutters at the wrap.
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            playerLayer.player = player
            playerLayer.videoGravity = .resize
            queuePlayer = player
            currentURL = url
            player.play()
        }

        func stop() {
            queuePlayer?.pause()
            looper?.disableLooping()
            looper = nil
            queuePlayer = nil
            currentURL = nil
        }
    }
}
