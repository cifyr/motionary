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
    /// Screen-space rect the wallpaper image covers: the whole screen for the
    /// full wallpaper, or the baked crop when the widget loads the smaller
    /// backdrop. Stated rather than assumed, because positioning a pre-cropped
    /// image as if it were full-screen is what previously left the rest of the
    /// widget black.
    var wallpaperRect: CGRect?
    let isAnimated: Bool
    /// Where a tap that misses every tile goes. Nil leaves the gaps dead,
    /// which is what a Home Screen does and so what this does by default.
    var background: URL?
    /// Placed pictures, drawn over the animation and under the tiles - the
    /// same stacking the editor and the wallpaper bake use. Defaulted so the
    /// font lab, which draws no decoration, does not have to say so.
    var assets: [PlacedAsset] = []
    var assetImage: (PlacedAsset) -> Image? = { _ in nil }
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

                if let background {
                    // Beneath the wallpaper's own frame but above nothing else,
                    // and sized to the whole view: a Link cannot be an overlay
                    // here or it would take the taps the tiles need.
                    Link(destination: background) {
                        Color.clear.frame(width: geometry.size.width, height: geometry.size.height)
                    }
                    .accessibilityLabel("Open \(background.host ?? background.absoluteString)")
                }

                if let wallpaper {
                    // Placed by the rect it actually covers, so a full-screen
                    // image and a baked crop both land on the same pixels.
                    let covered = wallpaperRect
                        ?? CGRect(origin: .zero, size: manifest.screenSize)
                    wallpaper
                        .resizable()
                        .interpolation(.high)
                        .frame(width: covered.width * scale, height: covered.height * scale)
                        .offset(
                            x: originX + covered.minX * scale,
                            y: originY + covered.minY * scale
                        )
                }

                if isAnimated {
                    TimerFontLayer(
                        laneCount: manifest.laneCount,
                        framesPerSecond: manifest.framesPerSecond,
                        font: { lane, size in
                            .custom(
                                LaneFontBuilder.postScriptName(family: manifest.fontFamilyBase, lane: lane),
                                size: size
                            )
                        }
                    )
                    .frame(width: screen.width, height: screen.height)
                    .offset(x: originX, y: originY)
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

/// The animated layer: 32-64 stacked timer texts, each in its own lane font,
/// with only one visible at a time thanks to the blink mask.
///
/// Nothing here runs per frame. The system re-renders the timer text on its own
/// schedule and that is what advances the visible glyph.
///
/// The lane font is supplied rather than derived from the manifest so the font
/// lab can push the same drawing through a font obtained some other way; the
/// point of the lab is that it is not a second renderer.
struct TimerFontLayer: View {
    let laneCount: Int
    let framesPerSecond: Int
    let font: (Int, CGFloat) -> Font

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size.width
            TimerFontCanvas(
                size: size,
                laneCount: laneCount,
                framesPerSecond: framesPerSecond,
                font: font
            )
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
    let laneCount: Int
    let framesPerSecond: Int
    let font: (Int, CGFloat) -> Font

    var body: some View {
        let lanes = laneCount
        let frameDuration = 1 / CGFloat(framesPerSecond)
        // Anchored to a whole cycle rather than "now minus 60", so the visible
        // frame is a pure function of wall-clock time. That is what lets the
        // app resume the animation where the widget left it. It also keeps the
        // lanes and the blink mask on one reference; two separate `Date()`
        // reads could disagree by enough to select the wrong lane.
        let reference = TimerFontSpec.cycleAlignedReference()

        ZStack {
            // Split into two halves masked against each other: the blink mask
            // can only isolate one lane within a half, so the second half is
            // gated as a group.
            ZStack {
                Text(reference + 1, style: .timer)
                    .font(font(0, size))
                    .foregroundStyle(.white)
                    .centerAnimationGlyph(size: size)

                ForEach(1 ..< max(2, lanes / 2), id: \.self) { lane in
                    Text(reference + 1 + frameDuration * CGFloat(lane), style: .timer)
                        .font(font(lane, size))
                        .foregroundStyle(.white)
                        .centerAnimationGlyph(size: size)
                        .mask {
                            BlinkMask(reference: reference, blinkOffset: CGFloat(-lane) * frameDuration)
                                .frame(width: size, height: size)
                        }
                }
            }

            ZStack {
                ForEach((lanes / 2) ..< lanes, id: \.self) { lane in
                    Text(reference + 1 + frameDuration * CGFloat(lane), style: .timer)
                        .font(font(lane, size))
                        .foregroundStyle(.white)
                        .centerAnimationGlyph(size: size)
                        .mask {
                            BlinkMask(reference: reference, blinkOffset: CGFloat(-lane) * frameDuration)
                                .frame(width: size, height: size)
                        }
                }
            }
            .mask {
                BlinkMask(reference: reference, blinkOffset: 1).frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .clipped()
    }
}

/// Lane 0 on its own, unmasked - the same drawing the stack does first, with
/// nothing else layered over it.
///
/// The font lab needs a picture per route, not motion, and one lane says
/// everything: if this draws, the route reached the renderer.
struct SingleLaneGlyph: View {
    let font: (CGFloat) -> Font

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size.width
            Text(TimerFontSpec.cycleAlignedReference() + 1, style: .timer)
                .font(font(size))
                .foregroundStyle(.white)
                .centerAnimationGlyph(size: size)
                .frame(width: size, height: size)
                .scaleEffect(x: 1, y: geometry.size.height / size, anchor: .top)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

private struct BlinkMask: View {
    /// Shared with the lane texts so both sides of the mask agree on phase.
    let reference: Date
    let blinkOffset: TimeInterval

    var body: some View {
        GeometryReader { geometry in
            let maxSize = max(geometry.size.width, geometry.size.height)
            Text(reference - blinkOffset, style: .timer)
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
