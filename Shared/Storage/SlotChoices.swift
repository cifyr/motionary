import CoreGraphics
import Foundation
import os

/// Which app occupies each slot of a design, chosen on the phone.
///
/// A design ships with an authored occupant per slot and a list of alternates.
/// The occupant is the one part of a design that can change after install -
/// tiles are live SwiftUI over the frozen animation, not part of it - so the
/// choice lives in the app group where both the app and the widget read it,
/// exactly like `ActiveDesign`.
enum SlotChoices {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "SlotChoices")

    /// Stored value meaning the slot draws nothing at all.
    static let hiddenValue = "-"

    /// What the editor calls the blank in a slot's set. Not a stored value -
    /// `hiddenValue` is - but it stands in the same id space as an appID, so it
    /// has to be as impossible to confuse with a real app as that one is.
    static let blankValue = "-blank-"

    /// What the phone asked a slot to show.
    enum Choice: Equatable {
        /// The authored app, exactly as the studio placed it.
        case standard
        case app(String)
        case hidden

        var storedValue: String? {
            switch self {
            case .standard: nil
            case .app(let id): id
            case .hidden: SlotChoices.hiddenValue
            }
        }
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: DesignStore.appGroupIdentifier)
    }

    /// Per design, so two bundled designs can assign the same slot ids - a
    /// duplicated design keeps its tile UUIDs - without sharing choices.
    private static func key(for designID: UUID) -> String {
        "slotChoices-\(designID.uuidString)"
    }

    static func stored(designID: UUID) -> [String: String] {
        defaults?.dictionary(forKey: key(for: designID)) as? [String: String] ?? [:]
    }

    // MARK: - Artwork and links chosen on the phone

    /// The icon the phone put on a slot, overriding whatever was authored.
    static func icon(designID: UUID, tileID: UUID) -> String? {
        defaults?.dictionary(forKey: "slotIcons-\(designID.uuidString)")
            .flatMap { $0[tileID.uuidString] as? String }
    }

    static func setIcon(_ skin: String?, designID: UUID, tileID: UUID) {
        let key = "slotIcons-\(designID.uuidString)"
        var values = defaults?.dictionary(forKey: key) as? [String: String] ?? [:]
        values[tileID.uuidString] = skin
        defaults?.set(values, forKey: key)
    }

    /// An app the phone pointed a slot at that the design never named - which
    /// is how a tile reaches something only this phone has.
    static func link(designID: UUID, tileID: UUID) -> CustomTarget? {
        guard let raw = defaults?.dictionary(forKey: "slotLinks-\(designID.uuidString)")
            .flatMap({ $0[tileID.uuidString] as? Data })
        else { return nil }
        return try? JSONDecoder().decode(CustomTarget.self, from: raw)
    }

    static func setLink(_ target: CustomTarget?, designID: UUID, tileID: UUID) {
        let key = "slotLinks-\(designID.uuidString)"
        var values = defaults?.dictionary(forKey: key) as? [String: Data] ?? [:]
        values[tileID.uuidString] = target.flatMap { try? JSONEncoder().encode($0) }
        defaults?.set(values, forKey: key)
        logger.info("slot link set on \(tileID.uuidString, privacy: .public)")
    }

    // MARK: - The slots as the phone wants them

    /// Every tile the widget should draw for this design.
    ///
    /// A blanked slot is not among them: it draws nothing and answers no taps.
    /// The editor asks for `blankedTiles` alongside this, because a slot that
    /// vanished from the screen could otherwise never be changed back.
    static func effectiveTiles(manifest: BuildManifest) -> [PlacedTile] {
        apply(to: manifest.placedTiles, designID: manifest.designID)
    }

    /// The slots the phone blanked, in the design's own order.
    static func blankedTiles(manifest: BuildManifest) -> [PlacedTile] {
        let values = stored(designID: manifest.designID)
        return manifest.placedTiles.filter { values[$0.id.uuidString] == hiddenValue }
    }

    static func choice(designID: UUID, tileID: UUID) -> Choice {
        switch stored(designID: designID)[tileID.uuidString] {
        case nil: .standard
        case hiddenValue: .hidden
        case .some(let id): .app(id)
        }
    }

    static func set(_ choice: Choice, designID: UUID, tileID: UUID) {
        var values = stored(designID: designID)
        values[tileID.uuidString] = choice.storedValue
        defaults?.set(values, forKey: key(for: designID))
        logger.info("""
        slot \(tileID.uuidString, privacy: .public) of \(designID.uuidString, privacy: .public) \
        -> \(choice.storedValue ?? "standard", privacy: .public)
        """)
    }

    /// The tiles as the phone wants them: swapped occupants applied and hidden
    /// slots dropped.
    static func apply(to tiles: [PlacedTile], designID: UUID) -> [PlacedTile] {
        apply(to: tiles, choices: stored(designID: designID)).map { tile in
            var updated = tile
            // The phone's own artwork and link, over whatever the occupant
            // swap produced: a slot can be pointed at an app the design never
            // named and dressed in any icon that shipped with it.
            if let skin = icon(designID: designID, tileID: tile.id) {
                updated.skin = skin.isEmpty ? nil : skin
                updated.icon = nil
            }
            if let target = link(designID: designID, tileID: tile.id) {
                updated.custom = target
            }
            return updated
        }
    }

    /// The choices are a parameter rather than read inside, so the resolution
    /// rules can be tested without a shared-defaults suite - the same shape as
    /// `ActiveDesign.resolve`.
    static func apply(to tiles: [PlacedTile], choices: [String: String]) -> [PlacedTile] {
        tiles.compactMap { resolved($0, value: choices[$0.id.uuidString]) }
    }

    /// One slot's effective tile, or nil when the slot is hidden.
    static func resolved(_ tile: PlacedTile, value: String?) -> PlacedTile? {
        guard let value else { return tile }
        if value == hiddenValue { return nil }
        if value == tile.appID { return tile }
        guard let alternate = tile.offeredAlternates.first(where: { $0.appID == value }) else {
            // A rebuild can drop the chosen alternate from the slot's list. The
            // authored occupant is the one guaranteed to exist, and falling
            // back beats a slot that silently launches an app it does not show.
            logger.error("""
            slot \(tile.id.uuidString, privacy: .public) chose \(value, privacy: .public), \
            which is no longer offered; showing \(tile.appID, privacy: .public)
            """)
            return tile
        }
        var swapped = tile
        swapped.appID = alternate.appID
        // The authored artwork belongs to the authored app: a swapped occupant
        // brings its own skin or falls back to its catalogue plate.
        swapped.icon = nil
        swapped.skin = alternate.skin
        swapped.tintHex = nil
        return swapped
    }
}
