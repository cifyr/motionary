import XCTest

/// A blanked slot draws nothing and answers no taps, but it has not gone away:
/// the editor still has to offer it, or blanking would be the one change that
/// cannot be undone from the screen it was made on.
final class BlankSlotTests: XCTestCase {
    private let design = UUID()

    private func manifest(tiles: [PlacedTile]) -> BuildManifest {
        BuildManifest(
            designID: design,
            buildGeneration: 1,
            fontFamilyBase: "MFontTestL",
            laneCount: 32,
            framesPerSecond: 16,
            loopFrameCount: 32,
            animationCrop: CGRect(x: 0, y: 0, width: 1000, height: 600),
            widgetRect: CGRect(x: 0, y: 0, width: 1000, height: 600),
            screenSize: CGSize(width: 1000, height: 600),
            wallpaperName: "wallpaper.png",
            totalFontBytes: 0,
            builtAt: Date(),
            tiles: tiles
        )
    }

    private func tile(_ appID: String = "spotify") -> PlacedTile {
        PlacedTile(appID: appID, center: CGPoint(x: 200, y: 200), size: 180, skin: "\(appID).png")
    }

    override func tearDown() {
        UserDefaults(suiteName: DesignStore.appGroupIdentifier)?
            .removeObject(forKey: "slotChoices-\(design.uuidString)")
        super.tearDown()
    }

    func testABlankedSlotIsNotDrawn() {
        let subject = tile()
        SlotChoices.set(.hidden, designID: design, tileID: subject.id)
        XCTAssertTrue(SlotChoices.effectiveTiles(manifest: manifest(tiles: [subject])).isEmpty)
    }

    /// The editor asks for these alongside the drawn ones. Without them a
    /// blanked slot is gone from the screen it would have to be tapped on.
    func testABlankedSlotIsStillOfferedToTheEditor() {
        let subject = tile()
        SlotChoices.set(.hidden, designID: design, tileID: subject.id)
        XCTAssertEqual(SlotChoices.blankedTiles(manifest: manifest(tiles: [subject])).map(\.id), [subject.id])
    }

    func testAnUntouchedSlotIsNotBlank() {
        XCTAssertTrue(SlotChoices.blankedTiles(manifest: manifest(tiles: [tile()])).isEmpty)
    }

    func testASwappedSlotIsNotBlank() {
        let subject = tile()
        SlotChoices.set(.app("mail"), designID: design, tileID: subject.id)
        XCTAssertTrue(SlotChoices.blankedTiles(manifest: manifest(tiles: [subject])).isEmpty)
    }

    func testBlankingOneSlotLeavesTheOthersAlone() {
        let first = tile("spotify")
        let second = tile("mail")
        SlotChoices.set(.hidden, designID: design, tileID: first.id)
        let subject = manifest(tiles: [first, second])

        XCTAssertEqual(SlotChoices.effectiveTiles(manifest: subject).map(\.id), [second.id])
        XCTAssertEqual(SlotChoices.blankedTiles(manifest: subject).map(\.id), [first.id])
    }

    /// Blanking is reversible from storage alone - the editor writes `standard`
    /// back and the slot returns with the artwork it was built with.
    func testUnblankingBringsTheSlotBack() throws {
        let subject = tile()
        SlotChoices.set(.hidden, designID: design, tileID: subject.id)
        SlotChoices.set(.standard, designID: design, tileID: subject.id)

        let drawn = try XCTUnwrap(SlotChoices.effectiveTiles(manifest: manifest(tiles: [subject])).first)
        XCTAssertEqual(drawn.skin, "spotify.png")
        XCTAssertTrue(SlotChoices.blankedTiles(manifest: manifest(tiles: [subject])).isEmpty)
    }
}

/// Picking an icon picks the app it was drawn for: the set pairs the two, so
/// choosing the Spotify drawing has to point the slot at Spotify and name it
/// Spotify, not leave a Spotify picture opening whatever was there before.
final class SlotSetSelectionTests: XCTestCase {
    private func slot() -> PlacedTile {
        PlacedTile(
            appID: "safari", center: .zero, size: 100, skin: "pack-safari.png",
            alternates: [
                .init(appID: "spotify", skin: "pack-spotify.png"),
                .init(appID: "games", skin: "pack-games.png"),
            ]
        )
    }

    func testChoosingAnEntryTakesItsArtworkAndItsName() throws {
        let chosen = try XCTUnwrap(SlotChoices.resolved(slot(), value: "spotify"))
        XCTAssertEqual(chosen.skin, "pack-spotify.png")
        XCTAssertEqual(chosen.displayName, "Spotify")
        XCTAssertEqual(LaunchLink.target(from: LaunchLink.url(for: chosen)), .app("spotify"))
    }

    /// A set drawn for a category has no catalogue entry behind it, so the
    /// editor has to ask for a name rather than showing the raw id forever.
    func testAnEntryTheCatalogueDoesNotKnowHasNoNameOfItsOwn() throws {
        let chosen = try XCTUnwrap(SlotChoices.resolved(slot(), value: "games"))
        XCTAssertNil(AppCatalog.app(id: chosen.appID))
        XCTAssertEqual(chosen.displayName, "games")
        XCTAssertFalse(chosen.canLaunch, "nothing to open until this phone says what it is")
    }

    /// The name typed on the phone wins over the id, which is the whole point
    /// of letting a category be named at all.
    func testANameGivenOnThePhoneIsWhatTheSlotIsCalled() throws {
        var chosen = try XCTUnwrap(SlotChoices.resolved(slot(), value: "games"))
        chosen.custom = CustomTarget(name: "Clash Royale", scheme: "clashroyale")
        XCTAssertEqual(chosen.displayName, "Clash Royale")
        XCTAssertTrue(chosen.canLaunch)
    }

    /// The blank is offered by every set, and it is a slot's own id space -
    /// colliding with a real app would make that app impossible to choose.
    func testTheBlankSentinelIsNotACatalogueApp() {
        XCTAssertNil(AppCatalog.app(id: SlotChoices.blankValue))
    }
}
