import SwiftUI

/// One frame of the design drawn once per font-delivery route, each route
/// owning a horizontal band of the same picture.
///
/// Every band is the same view through the same geometry; only the font behind
/// it differs. So a band with a picture in it is a route the widget renderer
/// honours and a black band is one it does not, with no interpretation in
/// between. Reading the answer off the Home Screen is the point: the extension
/// cannot tell the difference from the inside, which is what made the last four
/// attempts at this look healthy and draw nothing.
struct FontLabView: View {
    let manifest: BuildManifest
    let outcomes: [FontLab.Outcome]
    let viewport: CGRect

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height / CGFloat(max(1, outcomes.count))
            ZStack(alignment: .topLeading) {
                Color.black
                ForEach(Array(outcomes.enumerated()), id: \.element.id) { index, outcome in
                    band(outcome, index: index, size: geometry.size, height: height)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .clipped()
        .unredacted()
    }

    private func band(_ outcome: FontLab.Outcome, index: Int, size: CGSize, height: CGFloat) -> some View {
        let top = CGFloat(index) * height
        return Group {
            if let font = outcome.font {
                Stage(manifest: manifest, viewport: viewport, font: font)
            } else {
                Color.black
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .mask {
            Rectangle()
                .frame(width: size.width, height: height)
                .offset(y: top)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .overlay(alignment: .topLeading) {
            Text("\(index + 1) \(outcome.route.label)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(outcome.isDrawable ? .white : .yellow)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(.black.opacity(0.6))
                .padding(.leading, 3)
                .offset(y: top + 2)
        }
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
