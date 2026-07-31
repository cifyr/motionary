import XCTest

/// The phone can fill a spot the design left empty, which means synthesising a
/// tile from nothing but a cell and a stored choice. Getting the geometry or the
/// occupancy wrong puts an icon on top of another one, or offers a cell that is
/// already taken - neither of which looks like a bug until the widget draws it.
final class SlotAdditionTests: XCTestCase {
    private let design = UUID()
    private let frame = CGRect(x: 0, y: 0, width: 1000, height: 600)
    private let grid = WidgetGrid(columns: 4, rows: 2, margin: 56, gap: 40)

    /// Cell (0,0) centres on (152, 168) for this frame; (0,1) on (384, 168).
    private var firstCentre: CGPoint { grid.cellCenter(GridCell(row: 0, column: 0), in: frame) }

    private func manifest(tiles: [PlacedTile] = [], grid: WidgetGrid? = nil) -> BuildManifest {
        BuildManifest(
            designID: design,
            buildGeneration: 1,
            fontFamilyBase: "MFontTestL",
            laneCount: 32,
            framesPerSecond: 16,
            loopFrameCount: 32,
            animationCrop: frame,
            widgetRect: frame,
            screenSize: CGSize(width: 1000, height: 600),
            wallpaperName: "wallpaper.png",
            totalFontBytes: 0,
            builtAt: Date(),
            tiles: tiles,
            grid: grid ?? self.grid
        )
    }

    private func tile(at centre: CGPoint, appID: String = "spotify") -> PlacedTile {
        PlacedTile(appID: appID, center: centre, size: 180, cornerRadius: 0.3, showsLabel: false)
    }

    override func tearDown() {
        UserDefaults(suiteName: DesignStore.appGroupIdentifier)?
            .removeObject(forKey: "slotAdditions-\(design.uuidString)")
        super.tearDown()
    }

    private func fill(_ cell: GridCell, skin: String? = "neon-bear.png", target: CustomTarget? = nil) {
        SlotChoices.setAddition(
            SlotChoices.Addition(cell: cell, skin: skin, target: target, name: target?.name ?? "Spot"),
            designID: design,
            cell: cell
        )
    }

    // MARK: - What a filled spot becomes

    func testAFilledSpotBecomesATileOnItsCell() throws {
        let cell = GridCell(row: 0, column: 0)
        fill(cell)
        let tiles = SlotChoices.effectiveTiles(manifest: manifest())

        let added = try XCTUnwrap(tiles.first)
        XCTAssertEqual(tiles.count, 1)
        XCTAssertEqual(added.center, firstCentre)
        XCTAssertEqual(added.skin, "neon-bear.png")
        XCTAssertEqual(added.cell, cell)
    }

    /// An added tile next to the design's own should not read as a foreign
    /// object, so it takes their shape rather than a default.
    func testAnAddedTileIsShapedLikeTheDesignsOwn() throws {
        fill(GridCell(row: 1, column: 3))
        let sibling = tile(at: firstCentre)
        let tiles = SlotChoices.effectiveTiles(manifest: manifest(tiles: [sibling]))

        let added = try XCTUnwrap(tiles.last)
        XCTAssertEqual(added.size, sibling.size)
        XCTAssertEqual(added.cornerRadius, sibling.cornerRadius)
        XCTAssertEqual(added.showsLabel, sibling.showsLabel)
    }

    /// With no tile to copy, the cell decides - a tile sized to nothing would
    /// not be drawable at all.
    func testAnAddedTileOnItsOwnIsSizedToTheCell() throws {
        fill(GridCell(row: 0, column: 0))
        let added = try XCTUnwrap(SlotChoices.effectiveTiles(manifest: manifest()).first)
        XCTAssertEqual(added.size, grid.tileSide(in: frame))
    }

    func testAFilledSpotOpensWhatWasChosen() throws {
        let cell = GridCell(row: 0, column: 2)
        fill(cell, target: CustomTarget(name: "Bear", scheme: "bear"))
        let added = try XCTUnwrap(SlotChoices.effectiveTiles(manifest: manifest()).first)

        XCTAssertEqual(added.displayName, "Bear")
        XCTAssertEqual(
            LaunchLink.target(from: LaunchLink.url(for: added)),
            .url(try XCTUnwrap(URL(string: "bear://")))
        )
    }

    func testEmptyingASpotRemovesItsTile() {
        let cell = GridCell(row: 0, column: 0)
        fill(cell)
        SlotChoices.setAddition(nil, designID: design, cell: cell)
        XCTAssertTrue(SlotChoices.effectiveTiles(manifest: manifest()).isEmpty)
    }

    func testFillingTheSameSpotTwiceReplacesIt() throws {
        let cell = GridCell(row: 1, column: 1)
        fill(cell, skin: "first.png")
        fill(cell, skin: "second.png")
        let tiles = SlotChoices.effectiveTiles(manifest: manifest())
        XCTAssertEqual(tiles.count, 1)
        XCTAssertEqual(try XCTUnwrap(tiles.first).skin, "second.png")
    }

    // MARK: - Which spots are on offer

    func testEveryCellOfAnEmptyGridIsOffered() {
        XCTAssertEqual(SlotChoices.freeCells(manifest: manifest()).count, grid.cellCount)
    }

    func testACellWithATileInItIsNotOffered() {
        let free = SlotChoices.freeCells(manifest: manifest(tiles: [tile(at: firstCentre)]))
        XCTAssertEqual(free.count, grid.cellCount - 1)
        XCTAssertFalse(free.contains(GridCell(row: 0, column: 0)))
    }

    /// Occupancy is decided by where a tile actually is, not by the cell it was
    /// tagged with: a tile dragged off grid still covers a cell, and offering
    /// that cell would stack a second icon on top of it.
    func testATileDraggedOffGridStillHoldsItsCell() {
        var dragged = tile(at: CGPoint(x: firstCentre.x + 20, y: firstCentre.y - 15))
        dragged.cell = nil
        XCTAssertFalse(
            SlotChoices.freeCells(manifest: manifest(tiles: [dragged])).contains(GridCell(row: 0, column: 0))
        )
    }

    func testAFilledSpotIsNoLongerOffered() {
        let cell = GridCell(row: 1, column: 2)
        fill(cell)
        XCTAssertFalse(SlotChoices.freeCells(manifest: manifest()).contains(cell))
    }

    /// A design rebuilt with a tile moved onto a cell the phone had filled must
    /// not draw both: the authored tile is the one that exists.
    func testAnAdditionUnderAnAuthoredTileIsDropped() {
        fill(GridCell(row: 0, column: 0))
        let tiles = SlotChoices.effectiveTiles(manifest: manifest(tiles: [tile(at: firstCentre)]))
        XCTAssertEqual(tiles.count, 1)
        XCTAssertEqual(tiles.first?.appID, "spotify")
    }

    /// A build made before the grid travelled has no cells to address, and must
    /// simply offer nothing rather than guessing at a layout.
    func testAManifestWithoutAGridOffersNoSpots() {
        var subject = manifest()
        subject.grid = nil
        fill(GridCell(row: 0, column: 0))
        XCTAssertTrue(SlotChoices.freeCells(manifest: subject).isEmpty)
        XCTAssertTrue(SlotChoices.effectiveTiles(manifest: subject).isEmpty)
    }

    // MARK: - The synthesised id

    /// Both the app and the widget rebuild an added tile from storage, so its
    /// id has to be the same one every time or every per-tile lookup misses.
    func testAnAddedTileKeepsItsIdAcrossRebuilds() {
        let cell = GridCell(row: 1, column: 1)
        XCTAssertEqual(
            SlotChoices.addedTileID(designID: design, cell: cell),
            SlotChoices.addedTileID(designID: design, cell: cell)
        )
    }

    func testEverySpotHasItsOwnID() {
        let ids = grid.allCells.map { SlotChoices.addedTileID(designID: design, cell: $0) }
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testTwoDesignsDoNotShareASpotsID() {
        let cell = GridCell(row: 0, column: 0)
        XCTAssertNotEqual(
            SlotChoices.addedTileID(designID: design, cell: cell),
            SlotChoices.addedTileID(designID: UUID(), cell: cell)
        )
    }
}

/// A slot's icon picker offers its set, not the whole library: a slot styled
/// for one pack should not offer another pack's drawing of the same app.
final class SlotSetSkinTests: XCTestCase {
    func testASlotOffersItsOwnArtworkFirst() {
        let subject = PlacedTile(
            appID: "spotify", center: .zero, size: 100, skin: "neon-spotify.png",
            alternates: [.init(appID: "mail", skin: "neon-mail.png")]
        )
        XCTAssertEqual(subject.setSkins, ["neon-spotify.png", "neon-mail.png"])
    }

    func testTheSameArtworkIsNotOfferedTwice() {
        let subject = PlacedTile(
            appID: "spotify", center: .zero, size: 100, skin: "neon.png",
            alternates: [.init(appID: "mail", skin: "neon.png")]
        )
        XCTAssertEqual(subject.setSkins, ["neon.png"])
    }

    /// An alternate with no artwork draws the catalogue plate, so it contributes
    /// no swatch - offering a blank one would look like a broken icon.
    func testAnAlternateWithoutArtworkOffersNothing() {
        let subject = PlacedTile(
            appID: "spotify", center: .zero, size: 100,
            alternates: [.init(appID: "mail"), .init(appID: "maps", skin: "maps.png")]
        )
        XCTAssertEqual(subject.setSkins, ["maps.png"])
    }
}
