import CoreGraphics
import SwiftUI
import os

/// A runtime-frame design, full screen, in the app.
///
/// The app cannot draw the widget's animation. The mask is timer text and only
/// the system widget renderer advances that, so the app swaps one picture on a
/// timer instead - and it picks the picture from the same cycle phase the mask
/// would, so opening the app continues the loop rather than restarting it.
///
/// The frames are loaded small. Full resolution is sixty-odd megabytes of
/// bitmaps and the app has no reason to hold them: this is a screen-sized
/// preview, not the widget.
struct RuntimeDesignView<Tile: View>: View {
    @Environment(\.displayScale) private var displayScale

    let manifest: BuildManifest
    let sequence: RuntimeFrameSequence
    let frames: [Image]
    let wallpaper: Image?
    @ViewBuilder let tileContent: (PlacedTile, CGFloat) -> Tile

    var body: some View {
        GeometryReader { geometry in
            let scale = 1 / max(displayScale, 1)
            let screen = CGSize(
                width: manifest.screenSize.width * scale,
                height: manifest.screenSize.height * scale
            )

            ZStack(alignment: .topLeading) {
                Color.black

                if let wallpaper {
                    wallpaper
                        .resizable()
                        .interpolation(.high)
                        .frame(width: screen.width, height: screen.height)
                }

                if !frames.isEmpty {
                    // Half a slot, so the swap lands inside the window rather
                    // than on its edge. On the edge it alternates between two
                    // frames every tick and reads as a flicker.
                    TimelineView(.periodic(
                        from: .now,
                        by: BlinkCycle.slotWidth(count: sequence.frameCount) / 2
                    )) { context in
                        let index = BlinkCycle.slot(
                            count: frames.count,
                            at: context.date,
                            reference: TimerFontSpec.cycleAlignedReference()
                        )
                        frames[min(index, frames.count - 1)]
                            .resizable()
                            .interpolation(.high)
                            .frame(
                                width: sequence.rect.width * scale,
                                height: sequence.rect.height * scale
                            )
                            .offset(x: sequence.rect.minX * scale, y: sequence.rect.minY * scale)
                    }
                }

                ForEach(manifest.placedTiles) { tile in
                    tileContent(tile, tile.size * scale)
                        .frame(width: tile.size * scale, height: tile.size * scale)
                        .offset(x: tile.rect.minX * scale, y: tile.rect.minY * scale)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .clipped()
    }
}

/// Loads a runtime-frame design's pictures for the app to show.
///
/// Off the main thread and at a fraction of their real size. Loading 64
/// full-resolution frames synchronously in a view body froze the launch for
/// several seconds and held 60MB for a preview nobody looks at closely.
@MainActor
final class RuntimeFrameGallery: ObservableObject {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "RuntimeGallery")

    /// Longest side each frame is decoded at. A phone screen is 1206 wide and
    /// this preview is scaled to fit it, so a third of that is already more
    /// detail than the display can show.
    ///
    /// `nonisolated` because the decode runs off the main actor and the number
    /// is a constant; without it the loader cannot read its own setting.
    nonisolated static let previewPixelSize = 420

    @Published private(set) var frames: [Image] = []
    @Published private(set) var wallpaper: Image?
    @Published private(set) var failure: String?

    private var loadedID: UUID?

    func load(design: DesignDocument, manifest: BuildManifest, sequence: RuntimeFrameSequence, store: DesignStore) {
        guard loadedID != design.id else { return }
        loadedID = design.id
        frames = []
        wallpaper = nil
        failure = nil

        let id = design.id
        let count = sequence.frameCount
        let layout = sequence.layout
        // Resolved here rather than in the task: paths are all the loader needs
        // from the store, and sending a whole store across an isolation
        // boundary to compute a filename is asking for a concurrency warning
        // in exchange for nothing.
        let frameURLs = (0 ..< count).map { store.frameURL(for: id, index: $0) }
        let sheetURL = store.frameSheetURL(for: id)
        let stillURL = store.wallpaperURL(for: id)

        Task.detached(priority: .userInitiated) {
            var decoded: [CGImage] = []
            switch layout {
            case .separate:
                for url in frameURLs {
                    guard let image = ImageLoader.load(at: url, maxPixelSize: Self.previewPixelSize)
                    else { continue }
                    decoded.append(image)
                }
            case .sheet:
                // The strip has to be decoded tall enough that a single frame
                // still has pixels in it, then cut apart.
                let cap = Self.previewPixelSize * count
                if let sheet = ImageLoader.load(at: sheetURL, maxPixelSize: cap) {
                    let sliceHeight = CGFloat(sheet.height) / CGFloat(count)
                    for index in 0 ..< count {
                        let rect = CGRect(
                            x: 0,
                            y: (CGFloat(index) * sliceHeight).rounded(),
                            width: CGFloat(sheet.width),
                            height: sliceHeight.rounded()
                        )
                        guard let slice = sheet.cropping(to: rect) else { continue }
                        decoded.append(slice)
                    }
                }
            }
            let still = ImageLoader.load(
                at: stillURL,
                maxPixelSize: Int(DeviceGeometry.screenPixelSize.height / 2)
            )

            await MainActor.run {
                self.frames = decoded.map { Image(decorative: $0, scale: 1) }
                self.wallpaper = still.map { Image(decorative: $0, scale: 1) }
                if decoded.isEmpty {
                    // Said out loud rather than shown as a still picture: a
                    // design with no frames on disk and a design whose
                    // animation is broken look identical otherwise.
                    self.failure = "This design has no frames on disk. Import the clip again."
                    Self.logger.error("no frames for \(id.uuidString, privacy: .public), \(count) expected")
                }
            }
        }
    }
}
