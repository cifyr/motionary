import CoreGraphics
import SwiftUI

/// One slot of the blink cycle, as a mask.
///
/// A single blink text is opaque for a whole second out of two, which on its own
/// can only ever pick between two pictures. Two of them, offset from each other
/// by less than a second and multiplied together, leave a window as narrow as
/// the offset between them - and that window is what makes a frame rate out of a
/// font that only knows odd from even.
struct BlinkWindow: View {
    /// Shared with every other window so all of them agree on phase; two
    /// separate `Date()` reads can straddle a slot boundary.
    let reference: Date
    let slot: Int
    let slotCount: Int
    let side: CGFloat

    var body: some View {
        let start = BlinkCycle.slotStart(index: slot, count: slotCount)
        let width = BlinkCycle.slotWidth(count: slotCount)
        // `BlinkMask` takes the offset it subtracts from the reference, so the
        // sign flips going in.
        BlinkMask(reference: reference, blinkOffset: -start)
            .frame(width: side, height: side)
            .mask {
                BlinkMask(
                    reference: reference,
                    blinkOffset: -BlinkCycle.trailingOffset(start: start, width: width)
                )
                .frame(width: side, height: side)
            }
    }
}

/// The runtime-frame animation: N pictures stacked, each cut to its own slot of
/// the two-second cycle by the bundled blink font.
///
/// Nothing here is generated, registered or compiled. The pictures come out of
/// the app group at render time and the only font involved ships with the
/// extension, so a design drawn this way needed no toolchain to exist.
struct RuntimeFrameLayer: View {
    /// The pictures, already decoded by whoever could afford to decode them.
    ///
    /// Loaded outside the view rather than inside it because the footprint has
    /// to be sampled straight after the load: it is the number that decides
    /// whether this approach fits in a widget at all, and a view body is not a
    /// place that can report it.
    struct Payload {
        let sequence: RuntimeFrameSequence
        /// Populated for `.separate`.
        var frames: [Image] = []
        /// Populated for `.sheet`.
        var sheet: Image?
        /// Slots whose file would not decode, filled from a neighbour. Carried
        /// with the payload rather than left in the loader, because the widget
        /// report is the only place it can be seen.
        var missing: [Int] = []

        /// How many slots have a picture in them, after gaps were filled.
        var loadedCount: Int {
            sequence.layout == .sheet ? (sheet == nil ? 0 : sequence.frameCount) : frames.count
        }

        /// How many slots had a picture of their own.
        var foundCount: Int { max(0, loadedCount - missing.count) }

        /// Every slot has to be filled, or the ones that are not draw nothing and
        /// the widget flashes black for its share of the cycle.
        var isDrawable: Bool { loadedCount == sequence.frameCount }
    }

    let payload: Payload
    /// Shared with everything else on the render so the phase cannot disagree.
    let reference: Date

    init(payload: Payload, reference: Date = TimerFontSpec.cycleAlignedReference()) {
        self.payload = payload
        self.reference = reference
    }

    var body: some View {
        GeometryReader { geometry in
            // The mask is square because the blink glyph is a square em; it has
            // to cover the longest side or the corner it misses never reveals.
            let side = max(geometry.size.width, geometry.size.height)
            ZStack {
                switch payload.sequence.layout {
                case .separate:
                    ForEach(Array(payload.frames.enumerated()), id: \.offset) { index, frame in
                        frame
                            .resizable()
                            .interpolation(.medium)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .mask {
                                BlinkWindow(
                                    reference: reference,
                                    slot: index,
                                    slotCount: payload.frames.count,
                                    side: side
                                )
                            }
                    }
                case .sheet:
                    if let sheet = payload.sheet {
                        ForEach(0 ..< payload.sequence.frameCount, id: \.self) { index in
                            SheetWindow(
                                sheet: sheet,
                                index: index,
                                frameCount: payload.sequence.frameCount,
                                size: geometry.size
                            )
                            .mask {
                                BlinkWindow(
                                    reference: reference,
                                    slot: index,
                                    slotCount: payload.sequence.frameCount,
                                    side: side
                                )
                            }
                        }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

/// One frame cut out of a tall strip.
private struct SheetWindow: View {
    let sheet: Image
    let index: Int
    let frameCount: Int
    let size: CGSize

    var body: some View {
        sheet
            .resizable()
            .interpolation(.medium)
            .frame(width: size.width, height: size.height * CGFloat(frameCount))
            .offset(y: -size.height * CGFloat(index))
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipped()
    }
}

/// Reads a design's frames off disk and says what they cost.
///
/// Separated from the view so the widget can log the footprint immediately
/// after the decode. Every load is reported, because a missing frame draws a
/// hole in the loop that looks exactly like a broken mask, and a jetsam draws
/// a blank widget with no error anywhere saying why.
enum RuntimeFrameLoader {
    struct Result {
        var payload: RuntimeFrameLayer.Payload
        var footprintMB = 0

        var missing: [Int] { payload.missing }

        var note: String {
            let sequence = payload.sequence
            var text = "\(payload.foundCount)/\(sequence.frameCount) \(sequence.layout.rawValue)"
            if !missing.isEmpty {
                text += " FILLED \(missing.prefix(6).map(String.init).joined(separator: ","))"
                if missing.count > 6 { text += "..(\(missing.count))" }
            }
            if !payload.isDrawable { text += " NOT DRAWABLE" }
            return text
        }
    }

    static func load(sequence: RuntimeFrameSequence, designID: UUID, in store: DesignStore) -> Result {
        var result = Result(payload: .init(sequence: sequence))
        // The frames were written at exactly the size they are drawn, so the
        // cap is the frame's own longest side. Asking for less would resample
        // every frame; asking for more decodes nothing extra but hides a
        // mistake in the numbers.
        let longest = Int(max(sequence.frameSize.width, sequence.frameSize.height).rounded())

        switch sequence.layout {
        case .separate:
            var frames: [Image?] = []
            frames.reserveCapacity(sequence.frameCount)
            for index in 0 ..< sequence.frameCount {
                let url = store.frameURL(for: designID, index: index)
                guard let decoded = ImageLoader.load(at: url, maxPixelSize: longest) else {
                    result.payload.missing.append(index)
                    frames.append(nil)
                    continue
                }
                frames.append(Image(decorative: decoded, scale: 1))
            }
            // Gaps are filled from the nearest frame that did load rather than
            // left empty. An empty slot draws nothing for its share of the
            // cycle, so a folder caught mid-write - the app archiving the old
            // design while a render lands - flashed black several times a
            // second. A repeated frame is a stutter; a hole is a strobe. The
            // gaps are still named in the report either way.
            result.payload.frames = Self.filled(frames)
        case .sheet:
            // The strip is `frameCount` frames tall, so the cap has to allow
            // for that or the whole sheet comes back shrunk to one frame's
            // worth of pixels and every window shows the same smear.
            let cap = Int(sequence.frameSize.height.rounded()) * sequence.frameCount
            let url = store.frameSheetURL(for: designID)
            if let decoded = ImageLoader.load(at: url, maxPixelSize: max(cap, longest)) {
                result.payload.sheet = Image(decorative: decoded, scale: 1)
            } else {
                result.payload.missing = Array(0 ..< sequence.frameCount)
            }
        }

        result.footprintMB = MemoryFootprint.megabytes
        return result
    }

    /// Replaces each gap with the closest frame that did load. Empty if none did.
    static func filled(_ frames: [Image?]) -> [Image] {
        guard frames.contains(where: { $0 != nil }) else { return [] }
        var forward: [Image?] = frames
        var carried: Image?
        for index in forward.indices {
            if let frame = forward[index] { carried = frame } else { forward[index] = carried }
        }
        // A gap at the very start has nothing before it, so it is filled from
        // whatever comes after instead.
        carried = nil
        for index in forward.indices.reversed() {
            if let frame = forward[index] { carried = frame } else { forward[index] = carried }
        }
        return forward.compactMap { $0 }
    }
}
