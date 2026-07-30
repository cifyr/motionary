import SwiftUI

/// Draws `EdgeLab`'s target at the widget's own bounds, one device pixel at a
/// time.
///
/// Built from plain coloured rectangles rather than a `Canvas`: a widget's view
/// is archived and rasterised elsewhere, and this project has already spent a
/// night on a black widget caused by something in the tree the renderer would
/// not carry. Rectangles are what every other view here already proves survive.
struct EdgeLabView: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geometry in
            let scale = max(displayScale, 1)
            let pixel = 1 / scale
            let widthPixels = Int((geometry.size.width * scale).rounded())
            let heightPixels = Int((geometry.size.height * scale).rounded())

            // The base cannot be enlarged by an overlay, so nothing inside can
            // push the target off the pixels it is meant to land on.
            Color.black
                .frame(width: geometry.size.width, height: geometry.size.height)
                .overlay(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .frame(width: geometry.size.width, height: geometry.size.height)

                        bands(heightPixels: heightPixels, width: geometry.size.width, pixel: pixel)
                        grid(
                            widthPixels: widthPixels,
                            heightPixels: heightPixels,
                            size: geometry.size,
                            pixel: pixel
                        )
                        rings(
                            widthPixels: widthPixels,
                            heightPixels: heightPixels,
                            pixel: pixel
                        )
                    }
                }
        }
        .unredacted()
    }

    /// Flat grey, in bands down the widget, inset far enough to leave the rings
    /// their own pixels.
    private func bands(heightPixels: Int, width: CGFloat, pixel: CGFloat) -> some View {
        let inset = EdgeLab.fieldInset
        return ForEach(Array(stride(from: inset, to: heightPixels - inset, by: EdgeLab.bandHeightPixels)), id: \.self) { top in
            let bottom = min(top + EdgeLab.bandHeightPixels, heightPixels - inset)
            let level = EdgeLab.bandLevel(atPixelY: top)
            Color(white: level)
                .frame(
                    width: width - CGFloat(inset * 2) * pixel,
                    height: CGFloat(bottom - top) * pixel
                )
                .offset(x: CGFloat(inset) * pixel, y: CGFloat(top) * pixel)
        }
    }

    /// 1px white lines both ways: a horizontal displacement bends the vertical
    /// ones, a vertical displacement shifts the horizontal ones.
    private func grid(widthPixels: Int, heightPixels: Int, size: CGSize, pixel: CGFloat) -> some View {
        let inset = EdgeLab.fieldInset
        let spacing = EdgeLab.gridSpacingPixels
        return ZStack(alignment: .topLeading) {
            ForEach(Array(stride(from: spacing, to: widthPixels - inset, by: spacing)), id: \.self) { x in
                Color.white
                    .frame(width: pixel, height: size.height - CGFloat(inset * 2) * pixel)
                    .offset(x: CGFloat(x) * pixel, y: CGFloat(inset) * pixel)
            }
            ForEach(Array(stride(from: spacing, to: heightPixels - inset, by: spacing)), id: \.self) { y in
                Color.white
                    .frame(width: size.width - CGFloat(inset * 2) * pixel, height: pixel)
                    .offset(x: CGFloat(inset) * pixel, y: CGFloat(y) * pixel)
            }
        }
    }

    /// One saturated 1px ring per pixel of inset, so the boundary can be read
    /// off whichever ring the composite leaves intact.
    private func rings(widthPixels: Int, heightPixels: Int, pixel: CGFloat) -> some View {
        ForEach(EdgeLab.rings, id: \.inset) { ring in
            let inset = CGFloat(ring.inset) * pixel
            let width = CGFloat(widthPixels - ring.inset * 2) * pixel
            let height = CGFloat(heightPixels - ring.inset * 2) * pixel
            let color = Color(red: ring.rgb.0, green: ring.rgb.1, blue: ring.rgb.2)
            ZStack(alignment: .topLeading) {
                color.frame(width: width, height: pixel)
                color.frame(width: width, height: pixel).offset(y: height - pixel)
                color.frame(width: pixel, height: height)
                color.frame(width: pixel, height: height).offset(x: width - pixel)
            }
            .offset(x: inset, y: inset)
        }
    }
}
