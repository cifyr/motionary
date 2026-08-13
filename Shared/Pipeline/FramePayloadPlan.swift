import CoreGraphics
import Foundation

/// What a design built as pictures should be encoded at.
///
/// The font path's quality comes from `PayloadBudget`, which is sized against
/// the wrong thing entirely for this: there, one frame is base64'd into every
/// one of `lanes x 15` glyph selections, so the payload is the frame multiplied
/// by five hundred and quality has to be spent carefully. Here a frame is
/// written once. The same clip that had to be squeezed to fit thirty megabytes
/// of fonts came to 306KB of pictures, against a package whose two wallpapers
/// are 5.7MB - so the frames were being compressed for a ceiling they are
/// nowhere near.
///
/// Three real limits replace it, in the order they bite:
///
/// - **transfer**, because the package crosses a network or a share sheet;
/// - **the archive**, which the widget's stack is inlined into;
/// - **per-image pixel area**, which fails soft - the frame renders blank and
///   the widget looks broken rather than reporting anything.
enum FramePayloadPlan {
    /// Tried in order, best first, until the set fits. Starts far above what
    /// the font path can afford, because it can.
    static let qualityLadder: [Double] = [0.92, 0.85, 0.78, 0.7, 0.6, 0.5]

    static var bestQuality: Double { qualityLadder[0] }

    /// What one archive may weigh, and the first thing that makes a widget
    /// black.
    ///
    /// This was 12MB, described as "well under the archive figures" in
    /// `docs/widget-animation-surface.md` - which give 10MB by one Apple
    /// engineer and 30 by another. Twelve is not under ten. It then counted
    /// only the frames, which is how the design in `archiveBudget` below went
    /// black at 7.75MB of them.
    static var byteBudget: Int {
        // `MOTIONARY_BYTE_BUDGET` separates the two things that grow together
        // as a clip gets longer - how many lanes there are, and how many bytes
        // they come to - so a black widget can be attributed to one of them.
        ProcessInfo.processInfo.environment["MOTIONARY_BYTE_BUDGET"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? archiveBudget
    }

    /// Everything one archive carries, which is not only the frames.
    ///
    /// The widget's tree also holds the still backdrop behind the animation and
    /// the artwork on every placed tile, and those are inlined the same way the
    /// frames are. Budgeting the frames alone is how a design with photographic
    /// tiles went black while one with four times as many frames drew: 6.28MB
    /// of frames plus 1.20MB of artwork is 7.48MB and draws, and 7.75MB of
    /// frames plus 1.58MB of artwork is 9.32MB and does not.
    ///
    /// Measured on a phone, through iPhone Mirroring, on the extra-large
    /// portrait widget that fills the screen - not on a Simulator, whose widget
    /// is smaller and whose render server has a Mac's memory behind it. Every
    /// earlier number here was measured there and every one of them was too
    /// generous.
    static let archiveBudget = 7 * 1_048_576

    /// What is left for frames once the things that travel with them in the
    /// same archive are counted.
    static func frameBudget(companionBytes: Int, budget: Int = byteBudget) -> Int {
        max(1_048_576, budget - max(0, companionBytes))
    }

    /// Where the widget stops being drawn, as opposed to where a build aims.
    ///
    /// `archiveBudget` sits under this with room to spare. This is the number a
    /// set *already on a phone* is judged against, since it was packed by
    /// whatever budget was current when it was sent - and a design delivered
    /// under an older, more generous one is black until it is sent again.
    /// 9.32MB has been photographed drawing nothing.
    static let archiveLimit = 9 * 1_048_576

    /// How many lanes to skip so a frame set already on disk fits the archive.
    ///
    /// Taking every `n`th lane halves the frame rate rather than the loop: the
    /// mask gates each lane at a fixed offset, so the lanes that remain keep
    /// their places in the cycle and each one is simply held longer. The clip
    /// plays at the speed it was authored at, less smoothly.
    static func laneStride(forBytes totalBytes: Int, limit: Int = archiveLimit) -> Int {
        guard totalBytes > limit, limit > 0 else { return 1 }
        return Int((Double(totalBytes) / Double(limit)).rounded(.up))
    }

    /// The smallest per-image cap seen on shipping hardware is far lower than
    /// this, but the caps observed on modern phones cluster around 2.1M px
    /// [FORUM: 710745, 768169]. Over it, the render is dropped rather than
    /// refused, so this is a guard against a blank widget with no error.
    static let maximumPixelArea: Double = 2_121_055

    /// How much a frame of this size has to shrink to stay under the cap, or 1
    /// when it already does.
    static func scale(for size: CGSize) -> Double {
        let area = Double(size.width * size.height)
        guard area > maximumPixelArea, area > 0 else { return 1 }
        // Area scales with the square of the linear factor.
        return (maximumPixelArea / area).squareRoot()
    }

    static func fits(totalBytes: Int, budget: Int = byteBudget) -> Bool { totalBytes <= budget }

    /// The next quality worth trying, or nil when the ladder is spent.
    ///
    /// Spent is not a failure: a set that will not fit even at the bottom is
    /// still written, because a design that is slightly too big to send is more
    /// use than no design at all, and the caller says so rather than throwing.
    static func nextQuality(after quality: Double) -> Double? {
        guard let index = qualityLadder.firstIndex(where: { $0 <= quality + 0.0001 }) else {
            return qualityLadder.first
        }
        let next = index + 1
        return next < qualityLadder.count ? qualityLadder[next] : nil
    }

    /// The quality to encode at, given what one pass measured.
    ///
    /// Returns nil when the set already fits and nothing needs re-encoding.
    static func retry(totalBytes: Int, at quality: Double, budget: Int = byteBudget) -> Double? {
        guard !fits(totalBytes: totalBytes, budget: budget) else { return nil }
        return nextQuality(after: quality)
    }

    /// A frame set will not shrink below this, however many lanes ask for it.
    ///
    /// Half in each direction is a quarter of the pixels. Past that the frames
    /// are soft enough to see, and a long clip is better served by fewer of
    /// them than by a smear.
    static let minimumShrink = 0.5

    /// How far to shrink the frames so the set fits, once quality is spent.
    ///
    /// This is what buys a frame rate back. A clip's lanes cost `period x fps`
    /// pictures and they all go in one archive, so at ten seconds and 32fps the
    /// set is five times what it is at two - and over the archive limit the
    /// widget is not drawn at all. Compressing harder answers that with
    /// blocking, which is worse on a moving picture than a softer one is:
    /// JPEG bytes go roughly with pixel count, so the size is what should give.
    ///
    /// Returns 1 when nothing needs to shrink. Deliberately a single step
    /// computed from a measurement rather than a ladder walked one rung at a
    /// time - each pass re-encodes every frame in the loop.
    static func shrink(toFit budget: Int = byteBudget, measured totalBytes: Int) -> Double {
        guard totalBytes > budget, budget > 0 else { return 1 }
        // Area scales with the square of the linear factor, and a little under,
        // because a smaller JPEG keeps proportionally more of its header and
        // its low frequencies.
        let linear = (Double(budget) / Double(totalBytes)).squareRoot() * 0.95
        return max(minimumShrink, min(1, linear))
    }
}
