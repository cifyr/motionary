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
    /// Resumes the loop at the widget's current phase when supplied.
    var startTime: (() -> TimeInterval)?
    /// Placed pictures, over the video and under the tiles - the preview
    /// video does not carry them, exactly as the widget's animation does not.
    var assets: [PlacedAsset] = []
    var assetImage: (PlacedAsset) -> Image? = { _ in nil }
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
                    LoopingVideoView(url: videoURL, startTime: startTime)
                        .frame(width: screen.width, height: screen.height)
                        .offset(x: originX, y: originY)
                        .allowsHitTesting(false)
                }

                ForEach(assets.sorted { $0.zIndex < $1.zIndex }) { asset in
                    if let image = assetImage(asset) {
                        image
                            .resizable()
                            .interpolation(.high)
                            .frame(width: asset.size.width * scale, height: asset.size.height * scale)
                            .rotationEffect(.degrees(asset.rotation))
                            .opacity(asset.opacity)
                            .offset(
                                x: originX + asset.rect.minX * scale,
                                y: originY + asset.rect.minY * scale
                            )
                    }
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
    /// Where in the loop the widget is right now, in seconds. Read at the
    /// moment playback starts so the wait for readiness is accounted for, and
    /// again while playing so the app cannot drift away from it. Nil starts at
    /// zero and never corrects.
    var startTime: (() -> TimeInterval)?

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.play(url: url, phase: startTime)
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        view.play(url: url, phase: startTime)
    }

    static func dismantleUIView(_ view: PlayerView, coordinator: ()) {
        view.stop()
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }

        /// How long a looped clip is stretched to before it repeats.
        ///
        /// Every wrap costs a few milliseconds of real time, so a short loop
        /// pays that toll constantly: measured, a 0.31s clip lost 7ms per
        /// second under AVPlayerLooper against 0.3ms for a 6s one. The widget's
        /// animation is driven by the clock and never loses anything, so that
        /// toll is the two running at different speeds. Repeating the clip
        /// into one long item leaves the picture identical and the wraps rare.
        private static let minimumSpan: TimeInterval = 4

        /// How far out of step with the widget the picture may get before it is
        /// pulled back. Above a frame or so it is visible as disagreement;
        /// below it, correcting would be the more visible of the two.
        private static let tolerance: TimeInterval = 0.08

        private var looper: AVPlayerLooper?
        private var queuePlayer: AVQueuePlayer?
        private var currentURL: URL?
        /// The single loop's length, which the composition holds a whole number
        /// of - so the phase inside it is the player's time modulo this.
        private var loopDuration: TimeInterval = 0
        private var phase: (() -> TimeInterval)?
        private var driftObserver: Any?
        /// Bumped on every load, so a composition that finishes building after
        /// the view has moved on is dropped rather than played.
        private var generation = 0

        private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        func play(url: URL, phase: (() -> TimeInterval)?) {
            // The closure is refreshed even when the clip has not changed: it
            // captures the manifest the caller is drawing, and SwiftUI hands
            // over a new one on every update.
            self.phase = phase
            guard currentURL != url else { return }
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            // The clip playing now is left alone. Tearing it down here blanked
            // the layer for as long as the next one took to compose and seek,
            // and what showed through the hole was the wallpaper - which is
            // baked from the scene's own clip, so switching between two
            // variants flashed a third picture on the way.
            currentURL = url
            generation += 1
            let token = generation

            Task { [weak self] in
                guard let repeated = try? await Self.repeated(url: url, atLeast: Self.minimumSpan) else {
                    // Falling back rather than showing nothing: a clip that
                    // cannot be composed still plays, it just wraps more often.
                    await MainActor.run { self?.start(item: AVPlayerItem(url: url), loop: 0, token: token) }
                    return
                }
                await MainActor.run {
                    self?.start(item: AVPlayerItem(asset: repeated.composition), loop: repeated.loop, token: token)
                }
            }
        }

        /// The clip laid end to end enough times to run for `span`, and the
        /// length of one pass through it.
        private static func repeated(
            url: URL,
            atLeast span: TimeInterval
        ) async throws -> (composition: AVComposition, loop: TimeInterval) {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            guard seconds > 0, let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw LoopedClipError.noVideoTrack(path: url.path)
            }

            let composition = AVMutableComposition()
            guard let destination = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw LoopedClipError.noVideoTrack(path: url.path)
            }
            let range = CMTimeRange(start: .zero, duration: duration)
            let passes = max(1, Int((span / seconds).rounded(.up)))
            for pass in 0 ..< passes {
                try destination.insertTimeRange(
                    range,
                    of: track,
                    at: CMTimeMultiply(duration, multiplier: Int32(pass))
                )
            }
            return (composition, seconds)
        }

        /// Builds the incoming clip and only shows it once it can draw.
        ///
        /// The swap is the last thing that happens: until then the outgoing
        /// clip is still on the layer and still playing, so changing clip has
        /// no gap in it rather than a flash of whatever is underneath.
        private func start(item: AVPlayerItem, loop: TimeInterval, token: Int) {
            guard token == generation else { return }

            let player = AVQueuePlayer()
            // Belt only. The preview has no audio track to begin with, and mute
            // does nothing about the session an AVPlayer activates - that is
            // AudioSessionPolicy's job, and it was the actual cause of the app
            // silencing whatever the phone was already playing.
            player.isMuted = true
            // AVPlayerLooper repeats gaplessly; restarting on the
            // did-play-to-end notification visibly stutters at the wrap.
            let looper = AVPlayerLooper(player: player, templateItem: item)

            observe(player: player) { [weak self] in
                guard let self, token == self.generation else { return }
                // Seeked before it is shown, and the phase read at that moment,
                // so the wait for readiness does not put the app behind the
                // widget - and so the first frame drawn is the right one.
                self.seekToPhase(player: player) { [weak self] in
                    guard let self, token == self.generation else { return }
                    player.play()
                    self.show(player: player, looper: looper, loop: loop)
                }
            }
        }

        /// Puts the prepared player on screen and retires the one it replaces.
        private func show(player: AVQueuePlayer, looper: AVPlayerLooper, loop: TimeInterval) {
            let outgoing = queuePlayer
            let outgoingLooper = self.looper
            if let driftObserver, let outgoing {
                outgoing.removeTimeObserver(driftObserver)
            }
            self.driftObserver = nil

            playerLayer.videoGravity = .resize
            playerLayer.player = player
            queuePlayer = player
            self.looper = looper
            loopDuration = loop

            outgoing?.pause()
            outgoingLooper?.disableLooping()

            if phase != nil { watchForDrift(player: player) }
        }

        private func seekToPhase(player: AVQueuePlayer, then finished: @escaping () -> Void) {
            guard let phase else { return finished() }
            player.seek(
                to: CMTime(seconds: phase(), preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { _ in finished() }
        }

        /// Pulls the picture back onto the widget's clock when it slips.
        ///
        /// Playback is not held to real time - a wrap, a stall or a dropped
        /// frame all cost a little - while the widget's animation is a pure
        /// function of wall-clock time. Without this the two only agree at the
        /// moment the app opens.
        private func watchForDrift(player: AVQueuePlayer) {
            guard loopDuration > 0 else { return }
            driftObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 1, preferredTimescale: 600),
                queue: .main
            ) { [weak self] time in
                guard let self, let phase = self.phase, player.rate != 0 else { return }
                let drift = Self.drift(
                    playhead: CMTimeGetSeconds(time),
                    expected: phase(),
                    loopDuration: self.loopDuration
                )
                guard abs(drift) > min(Self.tolerance, self.loopDuration / 4) else { return }
                self.seekToPhase(player: player) {}
            }
        }

        /// How far ahead the picture is of where the widget says it should be,
        /// as the shorter way round the loop: at the wrap, 0.01s after the end
        /// is 0.01s ahead of the start rather than a whole loop behind.
        static func drift(playhead: TimeInterval, expected: TimeInterval, loopDuration: TimeInterval) -> TimeInterval {
            guard loopDuration > 0 else { return 0 }
            let position = playhead.truncatingRemainder(dividingBy: loopDuration)
            var difference = position - expected.truncatingRemainder(dividingBy: loopDuration)
            if difference > loopDuration / 2 { difference -= loopDuration }
            if difference < -loopDuration / 2 { difference += loopDuration }
            return difference
        }

        private var readinessObservation: NSKeyValueObservation?

        private func observe(player: AVQueuePlayer, then start: @escaping @MainActor () -> Void) {
            if player.currentItem?.status == .readyToPlay {
                start()
                return
            }
            readinessObservation?.invalidate()
            readinessObservation = player.observe(\.currentItem?.status, options: [.initial, .new]) { player, _ in
                guard player.currentItem?.status == .readyToPlay else { return }
                Task { @MainActor in start() }
            }
        }

        func stop() {
            readinessObservation?.invalidate()
            readinessObservation = nil
            if let driftObserver { queuePlayer?.removeTimeObserver(driftObserver) }
            driftObserver = nil
            queuePlayer?.pause()
            looper?.disableLooping()
            looper = nil
            queuePlayer = nil
            currentURL = nil
            loopDuration = 0
        }
    }
}

enum LoopedClipError: Error, CustomStringConvertible {
    case noVideoTrack(path: String)

    var description: String {
        switch self {
        case .noVideoTrack(let path): "preview clip has no video track to loop: \(path)"
        }
    }
}
