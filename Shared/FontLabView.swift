import SwiftUI

/// One row per font-delivery route, each showing the same small window onto the
/// same frame of the design.
///
/// Every row is the same view through the same geometry; only the font behind
/// it differs. A row with a picture is a route the renderer honours and an
/// empty row is one it does not, with nothing to interpret in between. The
/// answer has to be read off a rendered widget because the extension cannot
/// tell the difference from the inside - that is exactly what made four
/// previous attempts look healthy and draw nothing.
struct FontLabView: View {
    private static let labelWidth: CGFloat = 96

    let manifest: BuildManifest
    let outcomes: [FontLab.Outcome]
    let viewport: CGRect
    /// SwiftUI draws nothing at all for these fonts outside a widget, so in the
    /// app the rows show a CoreText rasterisation instead. That answers a
    /// different question - is the font sound in this process - from the one
    /// the widget's rows answer, which is whether the renderer will draw it.
    var usesCoreTextProof = false

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height / CGFloat(max(1, outcomes.count))
            VStack(spacing: 0) {
                ForEach(Array(outcomes.enumerated()), id: \.element.id) { index, outcome in
                    row(outcome, index: index, width: geometry.size.width, height: height)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .background(Color.black)
        .clipped()
        .unredacted()
    }

    private func row(_ outcome: FontLab.Outcome, index: Int, width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 4) {
            Text("\(index + 1) \(outcome.route.label)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(outcome.isDrawable ? .white : .yellow)
                .frame(width: Self.labelWidth, alignment: .leading)
            picture(outcome, size: CGSize(width: max(0, width - Self.labelWidth - 8), height: height - 4))
            Spacer(minLength: 0)
        }
        .frame(width: width, height: height, alignment: .leading)
    }

    @ViewBuilder
    private func picture(_ outcome: FontLab.Outcome, size: CGSize) -> some View {
        if usesCoreTextProof {
            if outcome.isDrawable, let proof = FontLab.coreTextProof(route: outcome.route, side: 240) {
                Image(uiImage: proof)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height, alignment: .center)
                    .clipped()
            } else {
                Color.black.frame(width: size.width, height: size.height)
            }
        } else if let font = outcome.font {
            let window = self.window(size: size)
            Stage(manifest: manifest, viewport: viewport, font: font)
                .offset(x: -window.minX, y: -window.minY)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .clipped()
        } else {
            Color.black.frame(width: size.width, height: size.height)
        }
    }

    /// The patch of the composition every row shows: centred on the animated
    /// area, so a row is empty only because nothing was drawn rather than
    /// because the picture landed somewhere else.
    private func window(size: CGSize) -> CGRect {
        let scale = 1 / DeviceGeometry.scale
        let centre = CGPoint(
            x: (manifest.animationCrop.midX - viewport.minX) * scale,
            y: (manifest.animationCrop.midY - viewport.minY) * scale
        )
        return CGRect(
            x: centre.x - size.width / 2,
            y: centre.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

/// The design's animated layer placed exactly as the widget places it, so a
/// route is judged through the production geometry rather than a probe of its
/// own. Two hand-built probes have already answered a question nobody asked.
private struct Stage: View {
    @Environment(\.displayScale) private var displayScale

    let manifest: BuildManifest
    let viewport: CGRect
    let font: (CGFloat) -> Font

    var body: some View {
        let scale = 1 / max(displayScale, 1)
        SingleLaneGlyph(font: font)
            .frame(
                width: manifest.screenSize.width * scale,
                height: manifest.screenSize.height * scale
            )
            .offset(x: -viewport.minX * scale, y: -viewport.minY * scale)
    }
}
