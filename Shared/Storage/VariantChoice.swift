import Foundation
import os

/// Which clip a design shows, chosen on the phone.
///
/// Clips are whole lane-font sets, all compiled into the bundle, so which one
/// the widget draws is free to change at runtime - the same reason a slot's
/// occupant is. The choice lives in the app group beside `ActiveDesign` and
/// `SlotChoices`.
enum VariantChoice {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "VariantChoice")

    /// Stored value meaning the design's own clip, chosen deliberately.
    ///
    /// Distinct from nothing stored, which means the phone has not chosen and
    /// takes whichever clip the design leads with. Without the distinction a
    /// design whose default is a variant could never be put back to its own
    /// clip: picking it would write "nothing chosen" and resolve straight back.
    static let primaryValue = "primary"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: DesignStore.appGroupIdentifier)
    }

    private static func key(for designID: UUID) -> String {
        "clipVariant-\(designID.uuidString)"
    }

    static func stored(designID: UUID) -> String? {
        defaults?.string(forKey: key(for: designID))
    }

    /// nil is the design's own clip.
    static func identifier(designID: UUID) -> UUID? {
        stored(designID: designID).flatMap(UUID.init(uuidString:))
    }

    static func set(_ id: UUID?, designID: UUID) {
        defaults?.set(id?.uuidString ?? primaryValue, forKey: key(for: designID))
        logger.info("""
        clip of \(designID.uuidString, privacy: .public) \
        -> \(id?.uuidString ?? primaryValue, privacy: .public)
        """)
    }

    /// Forgets the phone's choice, so the design's own default leads again.
    static func clear(designID: UUID) {
        defaults?.removeObject(forKey: key(for: designID))
    }

    /// The built clip to draw, or nil for the design's own.
    ///
    /// Nothing stored takes the design's default, which is what the studio
    /// chose to lead with. A stored id that this build no longer carries is
    /// treated the same way rather than silently becoming the primary: a
    /// rebuild that renamed a clip should land on what the design now leads
    /// with, not on whatever happens to be first.
    static func resolved(in manifest: BuildManifest, stored: String?) -> BuildManifest.VariantBuild? {
        func fallback() -> BuildManifest.VariantBuild? {
            guard let id = manifest.defaultVariantID else { return nil }
            return manifest.builtVariants.first { $0.id == id }
        }

        guard let stored else { return fallback() }
        if stored == primaryValue { return nil }
        guard let chosen = UUID(uuidString: stored) else { return fallback() }
        guard let variant = manifest.builtVariants.first(where: { $0.id == chosen }) else {
            logger.error("""
            design \(manifest.designID.uuidString, privacy: .public) chose clip \
            \(stored, privacy: .public), which this build does not carry
            """)
            return fallback()
        }
        return variant
    }

    /// The old shape, kept because a UUID is what most callers have.
    static func resolved(in manifest: BuildManifest, stored: UUID?) -> BuildManifest.VariantBuild? {
        resolved(in: manifest, stored: stored?.uuidString ?? primaryValue)
    }

    static func resolved(in manifest: BuildManifest) -> BuildManifest.VariantBuild? {
        resolved(in: manifest, stored: stored(designID: manifest.designID))
    }

    /// What a clip is called, the design's own included.
    static func title(of variant: BuildManifest.VariantBuild?, in manifest: BuildManifest) -> String {
        variant?.name ?? manifest.primaryClipTitle
    }
}
