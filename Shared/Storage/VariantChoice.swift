import Foundation
import os

/// Which clip variant a design shows, chosen on the phone.
///
/// Variants are whole lane-font sets, all compiled into the bundle, so which
/// one the widget draws is free to change at runtime - the same reason a slot's
/// occupant is. The choice lives in the app group beside `ActiveDesign` and
/// `SlotChoices`.
enum VariantChoice {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "VariantChoice")

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: DesignStore.appGroupIdentifier)
    }

    private static func key(for designID: UUID) -> String {
        "clipVariant-\(designID.uuidString)"
    }

    /// nil is the primary clip - the design's own, and the default.
    static func identifier(designID: UUID) -> UUID? {
        defaults?.string(forKey: key(for: designID)).flatMap(UUID.init(uuidString:))
    }

    static func set(_ id: UUID?, designID: UUID) {
        defaults?.set(id?.uuidString, forKey: key(for: designID))
        logger.info("""
        variant of \(designID.uuidString, privacy: .public) \
        -> \(id?.uuidString ?? "primary", privacy: .public)
        """)
    }

    /// The built variant a stored choice names, or nil for the primary -
    /// including when the choice points at a variant this build no longer
    /// carries, because the primary is the one clip guaranteed to exist.
    static func resolved(in manifest: BuildManifest, stored: UUID?) -> BuildManifest.VariantBuild? {
        guard let stored else { return nil }
        guard let variant = manifest.builtVariants.first(where: { $0.id == stored }) else {
            logger.error("""
            design \(manifest.designID.uuidString, privacy: .public) chose variant \
            \(stored.uuidString, privacy: .public), which this build does not carry; showing the primary
            """)
            return nil
        }
        return variant
    }

    static func resolved(in manifest: BuildManifest) -> BuildManifest.VariantBuild? {
        resolved(in: manifest, stored: identifier(designID: manifest.designID))
    }
}
