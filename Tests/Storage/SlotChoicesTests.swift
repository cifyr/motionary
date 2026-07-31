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
