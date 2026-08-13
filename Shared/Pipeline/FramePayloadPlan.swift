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

    /// The whole frame set, not one frame. Well under the archive figures in
    /// `docs/widget-animation-surface.md` (10MB by one Apple engineer, 30 by
    /// another) and comfortable to send: the sweep archived 64 frames at
    /// 1620px clean, and this is about what that set weighs.
    static let byteBudget = 12 * 1_048_576

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

    static func fits(totalBytes: Int) -> Bool { totalBytes <= byteBudget }

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
    static func retry(totalBytes: Int, at quality: Double) -> Double? {
        guard !fits(totalBytes: totalBytes) else { return nil }
        return nextQuality(after: quality)
    }
}
