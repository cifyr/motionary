import XCTest

/// Applying a set is what fills a slot's swap list, so these rules decide what
/// the phone can put in each spot - and a wrong merge here ships in a manifest.
final class SkinSetTests: XCTestCase {
    private let neon = SkinSet(name: "Neon", entries: [
        .init(appID: "mail", skin: "neon-mail.png"),
        .init(appID: "spotify", skin: "neon-spotify.png"),
        .init(appID: "maps", skin: "neon-maps.png"),
    ])

    private func tile(appID: String) -> PlacedTile {
        PlacedTile(appID: appID, center: CGPoint(x: 300, y: 900), size: 180)
    }

    func testTheTilesOwnAppTakesTheSetsArtwork() {
        let applied = neon.applied(to: tile(appID: "mail"))
        XCTAssertEqual(applied.appID, "mail", "the default occupant does not change")
        XCTAssertEqual(applied.skin, "neon-mail.png")
        XCTAssertNil(applied.icon)
    }

    func testTheRestOfTheSetBecomesTheSwapList() {
        let applied = neon.applied(to: tile(appID: "mail"))
        XCTAssertEqual(applied.alternates.map(\.appID), ["spotify", "maps"])
        XCTAssertEqual(applied.alternates.map(\.skin), ["neon-spotify.png", "neon-maps.png"])
    }

    /// A tile whose app the set does not cover keeps its own artwork, and the
    /// whole set becomes its swap list.
    func testATileOutsideTheSetKeepsItsArtwork() {
        var outside = tile(appID: "calendar")
        outside.skin = "own-calendar.png"
        let applied = neon.applied(to: outside)
        XCTAssertEqual(applied.skin, "own-calendar.png")
        XCTAssertEqual(applied.alternates.count, 3)
    }

    /// Re-applying replaces the swap list rather than growing it - a set is
    /// the full answer to what a slot can show.
    func testApplyingTwiceDoesNotAccumulate() {
        let once = neon.applied(to: tile(appID: "mail"))
        let twice = neon.applied(to: once)
        XCTAssertEqual(twice.alternates.count, 2)
    }

    func testApplyingADifferentSetReplacesTheFirst() {
        let pixel = SkinSet(name: "Pixel", entries: [
            .init(appID: "mail", skin: "pixel-mail.png"),
            .init(appID: "photos", skin: "pixel-photos.png"),
        ])
        let applied = pixel.applied(to: neon.applied(to: tile(appID: "mail")))
        XCTAssertEqual(applied.skin, "pixel-mail.png", "the same app draws differently per set")
        XCTAssertEqual(applied.alternates.map(\.appID), ["photos"])
    }

    /// One picture per app: adding an app again replaces its image - which is
    /// how a reference picture is swapped for a new one of the same size.
    func testAddingAnExistingAppReplacesItsPicture() {
        var set = neon
        set.setEntry(appID: "mail", skin: "neon-mail-v2.png")
        XCTAssertEqual(set.entries.count, 3)
        XCTAssertEqual(set.entries.first { $0.appID == "mail" }?.skin, "neon-mail-v2.png")
    }

    func testSetsRoundTripThroughTheStore() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("motionary-skinsets-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let store = SkinSetStore(fileURL: file)
        XCTAssertTrue(try store.all().isEmpty, "a missing file is an empty library, not an error")

        try store.save([neon])
        let loaded = try store.all()
        XCTAssertEqual(loaded, [neon])
    }

    /// A corrupt file must fail loudly: returning [] and saving over it would
    /// erase every set without a word.
    func testACorruptStoreSaysSoInsteadOfErasing() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("motionary-skinsets-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not json".utf8).write(to: file)

        XCTAssertThrowsError(try SkinSetStore(fileURL: file).all())
    }
}

/// A set's default decides what a tile takes when its own app is not in the
/// set - which is the case for most tiles most of the time.
final class SkinSetDefaultTests: XCTestCase {
    private let neon = SkinSet(name: "Neon", entries: [
        .init(appID: "mail", skin: "neon-mail.png"),
        .init(appID: "spotify", skin: "neon-spotify.png"),
    ])

    private func tile(appID: String) -> PlacedTile {
        PlacedTile(appID: appID, center: CGPoint(x: 300, y: 900), size: 180)
    }

    func testWithoutAChoiceTheFirstEntryIsTheDefault() {
        XCTAssertEqual(neon.defaultEntry?.appID, "mail")
    }

    func testTheChosenDefaultWins() {
        var set = neon
        set.defaultAppID = "spotify"
        XCTAssertEqual(set.defaultEntry?.appID, "spotify")
    }

    /// A default naming an entry the set no longer has falls back rather than
    /// leaving a tile with no artwork at all.
    func testAStaleDefaultFallsBackToTheFirst() {
        var set = neon
        set.defaultAppID = "gone"
        XCTAssertEqual(set.defaultEntry?.appID, "mail")
    }

    /// Applying a set must not overwrite artwork it has no entry for: doing
    /// that to every tile at once would replace pictures somebody chose.
    func testApplyingASetLeavesArtworkItDoesNotCoverAlone() {
        var set = neon
        set.defaultAppID = "spotify"
        var outside = tile(appID: "calendar")
        outside.skin = "own-calendar.png"
        XCTAssertEqual(set.applied(to: outside).skin, "own-calendar.png")
        // It still gets the whole set to swap to.
        XCTAssertEqual(set.applied(to: outside).alternates.count, 2)
    }

    func testTheDefaultSurvivesTheStore() throws {
        var set = neon
        set.defaultAppID = "spotify"
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("motionary-default-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = SkinSetStore(fileURL: file)
        try store.save([set])
        XCTAssertEqual(try store.all().first?.defaultAppID, "spotify")
    }

    /// A set written before defaults existed has no such key.
    func testASetWithoutADefaultStillDecodes() throws {
        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try JSONEncoder().encode(neon)) as? [String: Any]
        )
        json.removeValue(forKey: "defaultAppID")
        let decoded = try JSONDecoder().decode(
            SkinSet.self, from: try JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertNil(decoded.defaultAppID)
        XCTAssertEqual(decoded.defaultEntry?.appID, "mail")
    }
}
