import Foundation
import os

/// Whether opening the app moves the design on to its next clip.
///
/// A design can carry several clips - `VariantChoice` holds which one is drawn,
/// and the options sheet and a sideways swipe both set it. Both are deliberate:
/// the clip only changes when you change it, so a Home Screen looks the same
/// today as it did yesterday.
///
/// With this on, the clip steps one place through `clipSequence` every time the
/// app comes to the foreground, so the widget is showing something different
/// the next time you look at it without anything having been chosen. Off by
/// default, for the same reason `BackgroundTap` is: a Home Screen that changes
/// on its own is a surprise unless it was asked for.
///
/// One flag for every design rather than one per design. The question it
/// answers is about the phone - "do my widgets move around" - and a per-design
/// answer would have to be found and set a dozen times to mean anything.
enum ClipRotation {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "ClipRotation")

    private static let enabledKey = "clipRotationEnabled"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: DesignStore.appGroupIdentifier)
    }

    static var isEnabled: Bool {
        get { defaults?.bool(forKey: enabledKey) ?? false }
        set {
            defaults?.set(newValue, forKey: enabledKey)
            logger.info("clip rotation \(newValue ? "on" : "off", privacy: .public)")
        }
    }

    /// The clip after the one showing, in the order the sheet lists and a swipe
    /// walks - so rotating and swiping cannot disagree about what comes next.
    ///
    /// Nil when there is nothing to move on to: a design with one clip, or a
    /// shuffled one, whose several clips are already inside a single stack and
    /// are not selectable at all.
    static func next(after current: UUID?, in manifest: BuildManifest) -> BuildManifest.ClipChoice? {
        guard !manifest.hasShuffledClipProgram else { return nil }
        let options = manifest.clipSequence
        guard options.count > 1 else { return nil }
        let position = options.firstIndex { $0.variantID == current } ?? 0
        return options[(position + 1) % options.count]
    }

    /// Whether this design has anything to rotate through.
    ///
    /// The setting itself belongs to the phone, so it is offered whatever design
    /// is open; this only decides what the note under it says.
    static func canRotate(_ manifest: BuildManifest) -> Bool {
        next(after: nil, in: manifest) != nil
    }

    /// Moves the design on, and says what it landed on so the caller can log or
    /// show it. Nil means nothing moved, which is the usual case.
    @discardableResult
    static func advance(_ manifest: BuildManifest) -> BuildManifest.ClipChoice? {
        guard isEnabled else { return nil }
        let current = VariantChoice.resolved(in: manifest)?.id
        guard let next = Self.next(after: current, in: manifest) else { return nil }
        VariantChoice.set(next.variantID, designID: manifest.designID)
        logger.info("""
        \(manifest.designID.uuidString, privacy: .public) rotated to \
        \(next.name, privacy: .public)
        """)
        return next
    }
}
