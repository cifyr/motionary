import SwiftUI

/// Draws the imported source where a build would put it, live.
///
/// The editor used to show the last build's baked wallpaper, which meant a
/// placement change did nothing visible until the design was rebuilt. Drawing
/// the raw frame through the same placement arithmetic the generator uses makes
/// pinching and dragging show the real result immediately.
struct SourcePlacementLayer: View {
    let sourceImage: CGImage
    let transform: MediaTransform
    let screenSize: CGSize
    /// Screen pixels to canvas points.
    let canvasScale: CGFloat

    private var sourceSize: CGSize {
        CGSize(width: sourceImage.width, height: sourceImage.height)
    }

    var body: some View {
        let placed = MediaFrameExtractor.placement(
            sourceSize: sourceSize,
            screenSize: screenSize,
            transform: transform
        )
        let image = Image(decorative: sourceImage, scale: 1)

        ZStack(alignment: .topLeading) {
            Color.black

            if transform.fillsBackground,
               placed.width < screenSize.width || placed.height < screenSize.height {
                let backdrop = MediaFrameExtractor.backdropPlacement(
                    sourceSize: sourceSize,
                    screenSize: screenSize
                )
                layer(image, in: backdrop)
                    .opacity(MediaFrameExtractor.backdropOpacity)
            }

            layer(image, in: placed)
        }
        .frame(
            width: screenSize.width * canvasScale,
            height: screenSize.height * canvasScale,
            alignment: .topLeading
        )
        .clipped()
    }

    private func layer(_ image: Image, in rect: CGRect) -> some View {
        image
            .resizable()
            .interpolation(.high)
            .frame(width: rect.width * canvasScale, height: rect.height * canvasScale)
            .offset(x: rect.minX * canvasScale, y: rect.minY * canvasScale)
    }
}
