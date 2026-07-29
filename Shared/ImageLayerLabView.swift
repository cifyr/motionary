import CoreGraphics
import SwiftUI
import os

/// One slot of the blink cycle, as a mask.
///
/// A single blink text is opaque for a whole second out of two, which on its
/// own can only ever pick between two pictures. Two of them, offset from each
/// other by less than a second and multiplied together, leave a window as
/// narrow as the offset between them - and that window is what makes a frame
/// rate out of a font that only knows odd from even.
struct BlinkWindow: View {
    /// Shared with every other window so all of them agree on phase; two
    /// separate `Date()` reads can straddle a slot boundary.
    let reference: Date
    let slot: Int
    let slotCount: Int
    let side: CGFloat

    var body: some View {
        let start = ImageLayerLab.slotStart(index: slot, count: slotCount)
        let width = ImageLayerLab.slotWidth(count: slotCount)
        // `BlinkMask` takes the offset it subtracts from the reference, so the
        // sign flips going in.
        BlinkMask(reference: reference, blinkOffset: -start)
            .frame(width: side, height: side)
            .mask {
                BlinkMask(
                    reference: reference,
                    blinkOffset: -ImageLayerLab.trailingOffset(start: start, width: width)
                )
                .frame(width: side, height: side)
            }
    }
}

/// The whole proposal, drawn: N pictures stacked, each cut to its own slot of
/// the two-second cycle by the bundled blink font.
///
/// Nothing here is generated, registered, or compiled. The pictures come out of
/// the app group at render time and the only font involved ships with the
/// extension.
struct ImageLayerStack: View {
    let frames: [Image]
    let reference: Date

    var body: some View {
        GeometryReader { geometry in
            let side = max(geometry.size.width, geometry.size.height)
            ZStack {
                ForEach(Array(frames.enumerated()), id: \.offset) { index, frame in
                    frame
                        .resizable()
                        .interpolation(.none)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .mask {
                            BlinkWindow(
                                reference: reference,
                                slot: index,
                                slotCount: frames.count,
                                side: side
                            )
                        }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

/// The same stack cut out of one tall strip.
///
/// A separate file per frame and one strip holding all of them decode to the
/// same number of pixels, so this is not obviously cheaper - but it is one
/// allocation and one decode instead of N, and whether that shows up in the
/// extension's footprint is exactly the sort of thing that has to be measured
/// rather than reasoned about.
struct SheetLayerStack: View {
    let sheet: Image
    let frameCount: Int
    let reference: Date

    var body: some View {
        GeometryReader { geometry in
            let side = max(geometry.size.width, geometry.size.height)
            ZStack {
                ForEach(0 ..< frameCount, id: \.self) { index in
                    sheet
                        .resizable()
                        .interpolation(.none)
                        .frame(
                            width: geometry.size.width,
                            height: geometry.size.height * CGFloat(frameCount)
                        )
                        .offset(y: -geometry.size.height * CGFloat(index))
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                        .clipped()
                        .mask {
                            BlinkWindow(
                                reference: reference,
                                slot: index,
                                slotCount: frameCount,
                                side: side
                            )
                        }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

/// What the widget draws when the image lab is on.
///
/// The caption is part of the result, not decoration: the run is judged from a
/// screenshot taken from outside the simulator, and a picture that states its
/// own frame count, tile size and footprint needs no separate log to be read
/// against.
struct ImageLayerLabView: View {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "ImageLayerLab")

    let settings: ImageLayerLab.Settings
    let frames: [Image]
    let sheet: Image?
    /// Taken after the pictures were decoded, which is the number that decides
    /// whether this approach fits in a widget at all.
    let footprintMB: Int

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black

            switch settings.mode {
            case .separate:
                ImageLayerStack(frames: frames, reference: TimerFontSpec.cycleAlignedReference())
            case .sheet:
                if let sheet {
                    SheetLayerStack(
                        sheet: sheet,
                        frameCount: settings.frameCount,
                        reference: TimerFontSpec.cycleAlignedReference()
                    )
                }
            }

            Text("\(loaded)/\(settings.frameCount) x \(settings.tileSide)px \(settings.mode.rawValue) \(footprintMB)MB")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(3)
                .background(Color.black)
        }
        .clipped()
        .unredacted()
    }

    private var loaded: Int {
        settings.mode == .sheet ? (sheet == nil ? 0 : settings.frameCount) : frames.count
    }
}
