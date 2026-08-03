import XCTest

/// The phone chooses which app occupies each slot, and the widget applies the
/// same rules from the same store - so a wrong resolution here is a tile that
/// shows one app and launches another, or a slot that quietly vanishes.
final class SlotChoicesTests: XCTestCase {
    private func slot(
        appID: String = "spotify",
        alternates: [TileAlternate] = []
    ) -> PlacedTile {
        PlacedTile(
            appID: appID,
            center: CGPoint(x: 300, y: 900),
            size: 180,
            icon: IconAsset(prefix: "simple-icons", name: "spotify"),
            skin: "spotify-skin.png",
            tintHex: "#1db954",
            alternates: alternates
        )
    }

    func testNoChoiceKeepsTheAuthoredOccupant() {
        let tile = slot(alternates: [TileAlternate(appID: "apple-music")])
        XCTAssertEqual(SlotChoices.resolved(tile, value: nil), tile)
    }

    func testHiddenDropsTheSlot() {
        let tile = slot()
        XCTAssertNil(SlotChoices.resolved(tile, value: SlotChoices.hiddenValue))
    }

    func testASwapChangesTheAppAndItsArtwork() throws {
        let tile = slot(alternates: [TileAlternate(appID: "apple-music", skin: "vinyl.png")])
        let swapped = try XCTUnwrap(SlotChoices.resolved(tile, value: "apple-music"))

        XCTAssertEqual(swapped.appID, "apple-music")
        XCTAssertEqual(swapped.skin, "vinyl.png")
        // The authored artwork belongs to the authored app.
        XCTAssertNil(swapped.icon)
        XCTAssertNil(swapped.tintHex)
        // The slot itself does not move: only the occupant changes.
        XCTAssertEqual(swapped.id, tile.id)
        XCTAssertEqual(swapped.center, tile.center)
        XCTAssertEqual(swapped.size, tile.size)
        XCTAssertEqual(swapped.rotation, tile.rotation)
    }

    func testASwapWithoutASkinCarriesNoArtworkAtAll() throws {
        let tile = slot(alternates: [TileAlternate(appID: "youtube-music")])
        let swapped = try XCTUnwrap(SlotChoices.resolved(tile, value: "youtube-music"))
        XCTAssertNil(swapped.skin, "the authored skin must not dress a different app")
        XCTAssertNil(swapped.icon)
    }

    /// A rebuild can drop the chosen alternate from the slot's list; the
    /// authored occupant is the one guaranteed to exist.
    func testAChoiceNoLongerOfferedFallsBackToTheAuthoredApp() throws {
        let tile = slot(alternates: [TileAlternate(appID: "apple-music")])
        let resolved = try XCTUnwrap(SlotChoices.resolved(tile, value: "tidal"))
        XCTAssertEqual(resolved, tile)
    }

    func testChoosingTheAuthoredAppKeepsItsArtwork() throws {
        let tile = slot(alternates: [TileAlternate(appID: "apple-music")])
        let resolved = try XCTUnwrap(SlotChoices.resolved(tile, value: "spotify"))
        XCTAssertEqual(resolved.skin, "spotify-skin.png")
        XCTAssertNotNil(resolved.icon)
    }

    func testChoicesOnlyTouchTheirOwnSlot() throws {
        let swappable = slot(alternates: [TileAlternate(appID: "apple-music")])
        let untouched = PlacedTile(appID: "calendar", center: CGPoint(x: 600, y: 900), size: 160)

        let applied = SlotChoices.apply(
            to: [swappable, untouched],
            choices: [swappable.id.uuidString: "apple-music"]
        )
        XCTAssertEqual(applied.count, 2)
        XCTAssertEqual(applied.first?.appID, "apple-music")
        XCTAssertEqual(applied.last, untouched)
    }

    func testAHiddenSlotLeavesTheOthersInOrder() {
        let first = slot()
        let second = PlacedTile(appID: "calendar", center: CGPoint(x: 600, y: 900), size: 160)
        let third = PlacedTile(appID: "arc", center: CGPoint(x: 900, y: 900), size: 160)

        let applied = SlotChoices.apply(
            to: [first, second, third],
            choices: [second.id.uuidString: SlotChoices.hiddenValue]
        )
        XCTAssertEqual(applied.map(\.appID), ["spotify", "arc"])
    }

    /// The sentinel can never collide with a real app, or that app would become
    /// impossible to choose.
    func testTheHiddenSentinelIsNotACatalogueApp() {
        XCTAssertNil(AppCatalog.app(id: SlotChoices.hiddenValue))
    }
}

/// The phone can point a slot at any app it has and dress it in any icon that
/// shipped - so a design is a starting point rather than the final word.
final class SlotOverrideTests: XCTestCase {
    private let design = UUID()

    private func tile() -> PlacedTile {
        PlacedTile(appID: "spotify", center: .zero, size: 100, skin: "authored.png")
    }

    override func tearDown() {
        let defaults = UserDefaults(suiteName: DesignStore.appGroupIdentifier)
        defaults?.removeObject(forKey: "slotIcons-\(design.uuidString)")
        defaults?.removeObject(forKey: "slotLinks-\(design.uuidString)")
        super.tearDown()
    }

    func testAnIconChosenOnThePhoneReplacesTheAuthoredOne() {
        let subject = tile()
        SlotChoices.setIcon("neon-mail.png", designID: design, tileID: subject.id)
        let applied = SlotChoices.apply(to: [subject], designID: design)
        XCTAssertEqual(applied.first?.skin, "neon-mail.png")
    }

    func testClearingTheChoiceGivesTheAuthoredIconBack() {
        let subject = tile()
        SlotChoices.setIcon("neon-mail.png", designID: design, tileID: subject.id)
        SlotChoices.setIcon(nil, designID: design, tileID: subject.id)
        XCTAssertEqual(SlotChoices.apply(to: [subject], designID: design).first?.skin, "authored.png")
    }

    func testALinkChosenOnThePhoneIsWhatTheTileOpens() throws {
        let subject = tile()
        SlotChoices.setLink(
            CustomTarget(name: "Bear", scheme: "bear"),
            designID: design, tileID: subject.id
        )
        let applied = try XCTUnwrap(SlotChoices.apply(to: [subject], designID: design).first)

        XCTAssertEqual(applied.displayName, "Bear")
        XCTAssertEqual(LaunchLink.target(from: LaunchLink.url(for: applied)),
                       .url(try XCTUnwrap(URL(string: "bear://"))))
    }

    func testClearingTheLinkReturnsTheSlotToItsApp() {
        let subject = tile()
        SlotChoices.setLink(CustomTarget(name: "Bear", scheme: "bear"), designID: design, tileID: subject.id)
        SlotChoices.setLink(nil, designID: design, tileID: subject.id)
        let applied = SlotChoices.apply(to: [subject], designID: design).first
        XCTAssertNil(applied?.custom)
        XCTAssertEqual(applied?.displayName, "Spotify")
    }

    /// The overrides are per slot, so setting one must not reach the others.
    func testAnOverrideOnlyTouchesItsOwnSlot() {
        let first = tile()
        let second = PlacedTile(appID: "calendar", center: .zero, size: 100, skin: "second.png")
        SlotChoices.setIcon("neon-mail.png", designID: design, tileID: first.id)
        let applied = SlotChoices.apply(to: [first, second], designID: design)
        XCTAssertEqual(applied.last?.skin, "second.png")
    }
}
