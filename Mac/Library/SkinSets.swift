import Foundation
import os

/// A named group of app-and-artwork pairs drawn in one style - a themed icon
/// pack. "Neon" holds a neon Mail, a neon Spotify, a neon Maps; "Pixel" holds
/// the same apps drawn again.
///
/// Applying a set to a tile is what populates the slot the phone chooses from:
/// the tile's own app takes the set's artwork for it, and every other entry
/// becomes a swappable alternate carrying its own. The set itself never ships -
/// it is authoring shorthand for what already travels on the tile.
struct SkinSet: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var entries: [Entry] = []
    /// Which entry a tile takes when the set is applied and the tile's own app
    /// is not in it. Nil means the first, which is what a set with no opinion
    /// about its own default should do.
    var defaultAppID: String?

    /// One app drawn in this set's style. The skin is a filename in the skin
    /// library, already keyed, trimmed and squared to one size at import.
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        var appID: String
        var skin: String

        /// The appID: a set holds one picture per app, so adding an app again
        /// replaces its picture rather than offering it twice.
        var id: String { appID }
    }

    init(id: UUID = UUID(), name: String, entries: [Entry] = []) {
        self.id = id
        self.name = name
        self.entries = entries
    }

    /// Adds or replaces the entry for an app - replacing is the point: a set's
    /// picture for Mail can be swapped for a new file of the same size without
    /// touching the link it carries.
    mutating func setEntry(appID: String, skin: String) {
        if let index = entries.firstIndex(where: { $0.appID == appID }) {
            entries[index].skin = skin
        } else {
            entries.append(Entry(appID: appID, skin: skin))
        }
    }

    /// The tile with this set applied.
    ///
    /// The tile keeps its place and its app - the default occupant - and takes
    /// the set's artwork for that app when the set has one. Every other entry
    /// becomes an alternate, so on the phone the slot swaps within the set:
    /// same style, same size, different app and link. Alternates are replaced,
    /// not appended: applying a set answers "what can this slot show" in full.
    /// The entry the set stands for: what a tile becomes when the set itself
    /// is put on it rather than one of its entries, and what the editor marks
    /// as the default. Falls back to the first, so a set always has one.
    var defaultEntry: Entry? {
        defaultAppID.flatMap { id in entries.first { $0.appID == id } } ?? entries.first
    }

    func applied(to tile: PlacedTile) -> PlacedTile {
        var updated = tile
        if let own = entries.first(where: { $0.appID == tile.appID }) {
            updated.skin = own.skin
            updated.icon = nil
        }
        // A tile whose app the set does not cover keeps its own artwork.
        // Overwriting it with the set's default would silently replace a
        // picture somebody chose, which applying a set to every tile at once
        // would do to every tile the set does not name.
        updated.alternates = entries
            .filter { $0.appID != tile.appID }
            .map { TileAlternate(appID: $0.appID, skin: $0.skin) }
        return updated
    }
}

/// Persists the sets beside the skins they reference, outside any one design,
/// because a set is reusable authoring material exactly like the artwork is.
struct SkinSetStore {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "SkinSets")

    let fileURL: URL

    init() throws {
        fileURL = try SkinLibrary().root.appendingPathComponent("skin-sets.json")
    }

    /// Injectable for tests, which must not touch the real library.
    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func all() throws -> [SkinSet] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            return try JSONDecoder().decode([SkinSet].self, from: Data(contentsOf: fileURL))
        } catch {
            // Loudly: silently returning [] would read as every set vanishing,
            // and saving over the unread file would make that permanent.
            Self.logger.error("could not read \(fileURL.path, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    func save(_ sets: [SkinSet]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sets).write(to: fileURL, options: .atomic)
    }
}
