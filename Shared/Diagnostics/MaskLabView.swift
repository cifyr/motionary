import SwiftUI
import UIKit

/// Three bands under the same live masks, so the Home Screen can say which
/// kinds of content a mask gates.
///
/// Read it by watching, or by two photographs a second apart: each band should
/// step 1-2-3-4 and wrap twice in two seconds. A band showing one card forever
/// is a mask that was resolved when the view was archived. A black band is
/// content the renderer would not draw at all. The text band is the control -
/// it is what the shipping engine already does, so if it is dead the lab is
/// broken and the other two bands say nothing.
struct MaskLabView: View {
    let cards: [UIImage]
    let phasing: MaskLab.Phasing
    let reference: Date

    var body: some View {
        VStack(spacing: 4) {
            Text("""
            MASK LAB  \(phasing.cardCount) cards \(phasing.cardPixels)px  \
            \(String(format: "%.2f", phasing.cardDuration))s each
            """)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)

            ForEach(MaskLab.Band.allCases, id: \.rawValue) { band in
                VStack(spacing: 2) {
                    Text(band.label)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                    strip(band: band)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .unredacted()
    }

    private func strip(band: MaskLab.Band) -> some View {
        GeometryReader { geometry in
            // The mask glyph is centred in a square canvas, so the square has
            // to cover the strip's long side or the gate clips the picture
            // rather than gating it.
            let side = max(geometry.size.width, geometry.size.height)
            ZStack {
                if phasing.spacing >= 1 {
                    // Second-scale phases need no split. The shipped mask is
                    // solid on even seconds, so it can only tell one lane from
                    // another inside a half of the stack and the other half has
                    // to be gated as a group. A mask solid one second in ten
                    // makes each second exclusive on its own, which is the
                    // whole question this setting exists to answer.
                    half(band: band, half: 0, side: side, lanes: 0 ..< phasing.laneCount)
                } else {
                    half(band: band, half: 0, side: side)
                    half(band: band, half: 1, side: side)
                        .mask {
                            BlinkMask(reference: reference, blinkOffset: 1, font: phasing.maskFont)
                                .frame(width: side, height: side)
                        }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: 54)
        .clipped()
        .border(.white.opacity(0.25))
    }

    private func half(
        band: MaskLab.Band,
        half: Int,
        side: CGFloat,
        lanes: Range<Int>? = nil
    ) -> some View {
        ZStack {
            ForEach(Array(lanes ?? phasing.lanes(half: half)), id: \.self) { lane in
                content(band: band, card: phasing.card(forLane: lane))
                    .mask {
                        BlinkMask(
                            reference: reference,
                            blinkOffset: phasing.blinkOffset(lane: lane),
                            font: phasing.maskFont
                        )
                        .frame(width: side, height: side)
                    }
            }
        }
    }

    @ViewBuilder
    private func content(band: MaskLab.Band, card: Int) -> some View {
        switch band {
        case .image:
            // `Image(uiImage:)` rather than a bundle asset or a file URL: it is
            // the one image route documented to be inlined into the archive,
            // and the point of the lab is that these bytes arrived after the
            // install.
            if card < cards.count {
                Image(uiImage: cards[card])
                    .resizable()
                    .scaledToFill()
            } else {
                Color.clear
            }
        case .colour:
            Color(uiColor: MaskLab.colour(card: card, of: phasing.cardCount))
        case .text:
            Text("\(card + 1)")
                .font(.system(size: 34, weight: .heavy))
                .foregroundStyle(Color(uiColor: MaskLab.colour(card: card, of: phasing.cardCount)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
