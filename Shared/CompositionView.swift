import SwiftUI

/// Draws a design's full-screen composition, scaled and offset so that a given
/// screen-space rect fills the available bounds.
///
/// The app editor passes the whole screen; the widget passes its own frame.
/// Both therefore lay tiles out from identical screen pixel coordinates.
struct CompositionView<Tile: View>: View {
    @Environment(\.displayScale) private var displayScale

    let manifest: BuildManifest
    let tiles: [PlacedTile]
    /// Region of the screen to show, in screen pixels. Only its origin affects
    /// layout; the visible extent comes from the real view size.
    let viewport: CGRect
    let wallpaper: Image?
    let isAnimated: Bool
    @ViewBuilder let tileContent: (PlacedTile, CGFloat) -> Tile

    var body: some View {
        GeometryReader { geometry in
            // The composition is authored in screen pixels, so points per
            // screen pixel is exactly 1/displayScale. Deriving it from
            // `geometry.size.width / viewport.width` instead would make every
            // position depend on the widget-size table being exactly right,
            // and a 1.6% width error drifts content by ~16px over a large
            // widget — visible as the scene jumping when the app opens.
            let scale = 1 / max(displayScale, 1)
            let screen = CGSize(
                width: manifest.screenSize.width * scale,
                height: manifest.screenSize.height * scale
            )
            // Screen-space origin expressed in this view's coordinates.
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

                if isAnimated {
                    TimerFontLayer(manifest: manifest)
                        .frame(width: screen.width, height: screen.height)
                        .offset(x: originX, y: originY)
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

/// The animated layer: 32-64 stacked timer texts, each in its own lane font,
/// with only one visible at a time thanks to the blink mask.
///
/// Nothing here runs per frame. The system re-renders the timer text on its own
/// schedule and that is what advances the visible glyph.
struct TimerFontLayer: View {
    let manifest: BuildManifest

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size.width
            TimerFontCanvas(size: size, manifest: manifest)
                .frame(width: size, height: size)
                // The glyph canvas is square; stretch it back to screen aspect.
                .scaleEffect(x: 1, y: geometry.size.height / size, anchor: .top)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

private struct TimerFontCanvas: View {
    let size: CGFloat
    let manifest: BuildManifest

    private func laneFont(_ lane: Int) -> String {
        LaneFontBuilder.postScriptName(family: manifest.fontFamilyBase, lane: lane)
    }

    var body: some View {
        let lanes = manifest.laneCount
        let frameDuration = 1 / CGFloat(manifest.framesPerSecond)
        // A reference in the past guarantees the timer is counting up through
        // the selections rather than waiting to start.
        let reference = Date() - 60

        ZStack {
            // Split into two halves masked against each other: the blink mask
            // can only isolate one lane within a half, so the second half is
            // gated as a group.
            ZStack {
                Text(reference + 1, style: .timer)
                    .font(.custom(laneFont(0), size: size))
                    .foregroundStyle(.white)
                    .centerAnimationGlyph(size: size)

                ForEach(1 ..< max(2, lanes / 2), id: \.self) { lane in
                    Text(reference + 1 + frameDuration * CGFloat(lane), style: .timer)
                        .font(.custom(laneFont(lane), size: size))
                        .foregroundStyle(.white)
                        .centerAnimationGlyph(size: size)
                        .mask {
                            BlinkMask(blinkOffset: CGFloat(-lane) * frameDuration)
                                .frame(width: size, height: size)
                        }
                }
            }

            ZStack {
                ForEach((lanes / 2) ..< lanes, id: \.self) { lane in
                    Text(reference + 1 + frameDuration * CGFloat(lane), style: .timer)
                        .font(.custom(laneFont(lane), size: size))
                        .foregroundStyle(.white)
                        .centerAnimationGlyph(size: size)
                        .mask {
                            BlinkMask(blinkOffset: CGFloat(-lane) * frameDuration)
                                .frame(width: size, height: size)
                        }
                }
            }
            .mask {
                BlinkMask(blinkOffset: 1).frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .clipped()
    }
}

private struct BlinkMask: View {
    static let referenceDate = Date() - 60
    let blinkOffset: TimeInterval

    var body: some View {
        GeometryReader { geometry in
            let maxSize = max(geometry.size.width, geometry.size.height)
            Text(Self.referenceDate - blinkOffset, style: .timer)
                .font(.custom(FontSetGenerator.blinkFontResourceName, size: maxSize))
                .centerAnimationGlyph(size: maxSize, isInGeometryReader: true)
        }
        .clipped()
    }
}

private extension Text {
    /// Pushes the timer string sideways so the one glyph carrying the frame
    /// lands on the canvas and the surrounding digits fall outside it.
    func centerAnimationGlyph(size: CGFloat, isInGeometryReader: Bool = false) -> some View {
        frame(width: size * 9, height: size)
            .multilineTextAlignment(.trailing)
            .offset(x: -size * (isInGeometryReader ? 8 : 4))
    }
}
