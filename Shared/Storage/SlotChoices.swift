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

    // MARK: - Spots the design left empty

    /// A tile the phone put in a grid cell the design placed nothing in.
    ///
    /// It carries everything a synthesised tile needs, because there is no
    /// authored tile underneath to fall back to: the artwork, what it opens,
    /// and what it is called.
    struct Addition: Codable, Equatable, Sendable {
        var cell: GridCell
        /// A skin that shipped with the design. Nil draws the catalogue plate.
        var skin: String?
        var target: CustomTarget?
        var name: String = ""
    }

    private static func additionsKey(_ designID: UUID) -> String {
        "slotAdditions-\(designID.uuidString)"
    }

    static func additions(designID: UUID) -> [Addition] {
        guard let raw = defaults?.data(forKey: additionsKey(designID)) else { return [] }
        do {
            return try JSONDecoder().decode([Addition].self, from: raw)
        } catch {
            // Loudly: a spot the phone filled silently disappearing reads as
            // the app forgetting, which is indistinguishable from never
            // having saved it.
            logger.error("""
            could not read the added spots of \(designID.uuidString, privacy: .public): \
            \(String(describing: error), privacy: .public)
            """)
            return []
        }
    }

    static func addition(designID: UUID, cell: GridCell) -> Addition? {
        additions(designID: designID).first { $0.cell == cell }
    }

    /// Adds or replaces what fills a cell. Nil empties it again.
    static func setAddition(_ addition: Addition?, designID: UUID, cell: GridCell) {
        var all = additions(designID: designID).filter { $0.cell != cell }
        if let addition { all.append(addition) }
        guard let data = try? JSONEncoder().encode(all) else {
            logger.error("could not write the added spots of \(designID.uuidString, privacy: .public)")
            return
        }
        defaults?.set(data, forKey: additionsKey(designID))
        logger.info("""
        spot \(cell.label, privacy: .public) of \(designID.uuidString, privacy: .public) \
        -> \(addition == nil ? "empty" : "filled", privacy: .public)
        """)
    }

    /// The id an added tile draws under.
    ///
    /// Derived from the design and the cell rather than generated, so the tile
    /// is the same one across renders - the widget and the app both rebuild it
    /// from storage, and a fresh UUID each time would break every per-tile
    /// lookup. The marker byte keeps it out of the authored tiles' space.
    static func addedTileID(designID: UUID, cell: GridCell) -> UUID {
        var bytes = withUnsafeBytes(of: designID.uuid) { Array($0) }
        bytes[13] = 0xAD
        bytes[14] = UInt8(truncatingIfNeeded: cell.row)
        bytes[15] = UInt8(truncatingIfNeeded: cell.column)
        return NSUUID(uuidBytes: bytes) as UUID
    }

    /// Every tile the phone wants drawn: the design's own, as chosen, plus the
    /// ones it added to empty cells.
    static func effectiveTiles(manifest: BuildManifest) -> [PlacedTile] {
        let authored = apply(to: manifest.placedTiles, designID: manifest.designID)
        guard let grid = manifest.grid else { return authored }
        let taken = occupiedCells(grid: grid, frame: manifest.widgetRect, tiles: authored)
        let added = additions(designID: manifest.designID)
            .filter { !taken.contains($0.cell) }
            .map { tile(for: $0, manifest: manifest, grid: grid) }
        return authored + added
    }

    /// The cells with nothing in them, which are the spots the phone can fill.
    static func freeCells(manifest: BuildManifest) -> [GridCell] {
        guard let grid = manifest.grid else { return [] }
        let taken = occupiedCells(
            grid: grid,
            frame: manifest.widgetRect,
            tiles: effectiveTiles(manifest: manifest)
        )
        return grid.allCells.filter { !taken.contains($0) }
    }

    /// By where tiles actually are rather than by the cell they were tagged
    /// with: a tile dragged off grid still covers a cell, and offering that
    /// cell as empty would stack a second icon on top of it.
    private static func occupiedCells(grid: WidgetGrid, frame: CGRect, tiles: [PlacedTile]) -> Set<GridCell> {
        Set(tiles.compactMap { tile in
            grid.allCells.first { grid.cellRect($0, in: frame).contains(tile.center) }
        })
    }

    private static func tile(for addition: Addition, manifest: BuildManifest, grid: WidgetGrid) -> PlacedTile {
        // Shaped like the design's own tiles, so a filled spot does not read as
        // a foreign object next to them.
        let sibling = manifest.placedTiles.first
        return PlacedTile(
            id: addedTileID(designID: manifest.designID, cell: addition.cell),
            appID: addition.target?.name ?? addition.name,
            center: grid.cellCenter(addition.cell, in: manifest.widgetRect),
            size: sibling?.size ?? grid.tileSide(in: manifest.widgetRect),
            cornerRadius: sibling?.cornerRadius ?? 0.22,
            showsLabel: sibling?.showsLabel ?? true,
            skin: addition.skin,
            custom: addition.target,
            cell: addition.cell
        )
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
