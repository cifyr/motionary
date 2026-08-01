import CoreGraphics
import XCTest

/// Alignment is a toolbar button now rather than a steady hand, so these rules
/// are what a row of launchers actually comes out as.
final class LayoutActionsTests: XCTestCase {
    private func tile(_ x: CGFloat, _ y: CGFloat, size: CGFloat = 100) -> PlacedTile {
        PlacedTile(appID: "spotify", center: CGPoint(x: x, y: y), size: size)
    }

    private let frame = CGRect(x: 100, y: 200, width: 800, height: 1000)

    func testAligningTwoOrMoreUsesTheSelectionsOwnBox() {
        let a = tile(200, 400)
        let b = tile(600, 800)
        let aligned = LayoutActions.aligned(
            [a, b], selection: [a.id, b.id], to: .left, widgetRect: frame
        )
        // The selection's own left edge is a's, at 200 - 50.
        XCTAssertEqual(aligned[0].center.x, 200)
        XCTAssertEqual(aligned[1].center.x, 200)
        XCTAssertEqual(aligned[1].center.y, 800, "aligning one axis must not move the other")
    }

    /// A lone tile has nothing to line up against, so it goes to the widget
    /// frame - the region it has to be in to answer a tap.
    func testAligningOneUsesTheWidgetFrame() {
        let a = tile(500, 700)
        let aligned = LayoutActions.aligned([a], selection: [a.id], to: .left, widgetRect: frame)
        XCTAssertEqual(aligned[0].center.x, frame.minX + 50)
    }

    func testAligningLeavesUnselectedTilesAlone() {
        let a = tile(200, 400)
        let untouched = tile(600, 800)
        let aligned = LayoutActions.aligned(
            [a, untouched], selection: [a.id], to: .right, widgetRect: frame
        )
        XCTAssertEqual(aligned[1].center, untouched.center)
    }

    /// A tile moved by a button is no longer in the cell it was put in; the
    /// layer list must not go on claiming one.
    func testAligningTakesTheTileOffItsCell() {
        var a = tile(200, 400)
        a.cell = GridCell(row: 0, column: 0)
        let aligned = LayoutActions.aligned([a], selection: [a.id], to: .right, widgetRect: frame)
        XCTAssertNil(aligned[0].cell)
    }

    func testSpacingEvenlyEqualisesTheGaps() {
        let a = tile(100, 500)
        let b = tile(180, 500)
        let c = tile(700, 500)
        let spaced = LayoutActions.spacedEvenly([a, b, c], selection: [a.id, b.id, c.id])

        XCTAssertEqual(spaced[0].center.x, 100, "the ends stay put")
        XCTAssertEqual(spaced[2].center.x, 700)
        let firstGap = spaced[1].center.x - spaced[0].center.x
        let secondGap = spaced[2].center.x - spaced[1].center.x
        XCTAssertEqual(firstGap, secondGap, accuracy: 0.01)
    }

    /// Two tiles have no interior to space, so nothing should jump.
    func testSpacingFewerThanThreeChangesNothing() {
        let a = tile(100, 500)
        let b = tile(700, 500)
        let spaced = LayoutActions.spacedEvenly([a, b], selection: [a.id, b.id])
        XCTAssertEqual(spaced.map(\.center), [a.center, b.center])
    }

    func testMakingARowAlignsTopsAndSetsEqualGaps() {
        let a = tile(300, 500)
        let b = tile(100, 620)
        let c = tile(700, 400)
        let row = LayoutActions.madeIntoRow([a, b, c], selection: [a.id, b.id, c.id], gap: 40)

        XCTAssertEqual(Set(row.map(\.center.y)).count, 1, "tops are not aligned")
        // Left to right in the order they already sat: b (100), a (300), c (700).
        let ordered = row.sorted { $0.center.x < $1.center.x }
        XCTAssertEqual(ordered[0].id, b.id)
        XCTAssertEqual(ordered[1].id, a.id)
        XCTAssertEqual(ordered[2].id, c.id)

        let firstGap = ordered[1].center.x - ordered[0].center.x - 100
        let secondGap = ordered[2].center.x - ordered[1].center.x - 100
        XCTAssertEqual(firstGap, 40, accuracy: 0.01)
        XCTAssertEqual(secondGap, 40, accuracy: 0.01)
    }

    /// The row keeps the selection's own left edge and top rather than jumping
    /// somewhere else on the canvas.
    func testARowStaysWhereTheSelectionWas() {
        let a = tile(300, 500)
        let b = tile(100, 620)
        let row = LayoutActions.madeIntoRow([a, b], selection: [a.id, b.id], gap: 40)
        let box = LayoutActions.bounds(of: row)
        XCTAssertEqual(box.minX, 50, accuracy: 0.01, "b's left edge was 100 - 50")
        XCTAssertEqual(box.minY, 450, accuracy: 0.01, "a's top was 500 - 50")
    }

    /// A rotated tile reaches wider than its side, so the box it is aligned by
    /// has to account for it.
    func testBoundsAccountForRotation() {
        var rotated = tile(500, 500, size: 100)
        rotated.rotation = 45
        let box = LayoutActions.bounds(of: [rotated])
        XCTAssertEqual(box.width, rotated.boundingExtent, accuracy: 0.01)
        XCTAssertGreaterThan(box.width, 100)
    }
}

/// The grid is what stops new tiles stacking and what "Snap to cell" means.
final class WidgetGridTests: XCTestCase {
    private let frame = DeviceGeometry.widgetRect

    func testTheDefaultGridIsFourAcrossByTwoDown() {
        let grid = WidgetGrid()
        XCTAssertEqual(grid.cellCount, 8)
        XCTAssertEqual(grid.allCells.count, 8)
        XCTAssertEqual(grid.allCells.first?.label, "R1C1")
        XCTAssertEqual(grid.allCells.last?.label, "R2C4")
    }

    /// Reading order: a row is filled left to right before the next one starts.
    func testCellsAreInReadingOrder() {
        let cells = WidgetGrid().allCells
        XCTAssertEqual(cells.prefix(4).map(\.label), ["R1C1", "R1C2", "R1C3", "R1C4"])
    }

    func testEveryCellFallsInsideTheWidgetFrame() {
        let grid = WidgetGrid()
        for cell in grid.allCells {
            XCTAssertTrue(
                frame.contains(grid.cellRect(cell, in: frame)),
                "\(cell.label) falls outside the frame a tap can reach"
            )
        }
    }

    func testCellsDoNotOverlap() {
        let grid = WidgetGrid()
        let rects = grid.allCells.map { grid.cellRect($0, in: frame) }
        for (index, rect) in rects.enumerated() {
            for other in rects[(index + 1)...] {
                XCTAssertFalse(rect.intersects(other), "cells overlap")
            }
        }
    }

    func testTheNextFreeCellSkipsTakenOnes() {
        let grid = WidgetGrid()
        let taken: Set<GridCell> = [
            GridCell(row: 0, column: 0),
            GridCell(row: 0, column: 1),
        ]
        XCTAssertEqual(grid.firstFreeCell(occupied: taken)?.label, "R1C3")
    }

    /// A full grid answers nil, which is what the editor reports rather than
    /// silently stacking a tile on one already there.
    func testAFullGridHasNoFreeCell() {
        let grid = WidgetGrid()
        XCTAssertNil(grid.firstFreeCell(occupied: Set(grid.allCells)))
    }

    func testTheNearestCellIsTheOneAPointSitsIn() {
        let grid = WidgetGrid()
        let target = GridCell(row: 1, column: 2)
        let centre = grid.cellCenter(target, in: frame)
        XCTAssertEqual(grid.nearestCell(to: centre, in: frame), target)
    }

    /// A tile is square and a cell need not be, so the default side has to fit
    /// the smaller dimension or tiles would overhang their cells.
    func testTheDefaultTileSideFitsACell() {
        let grid = WidgetGrid()
        let rect = grid.cellRect(GridCell(row: 0, column: 0), in: frame)
        let side = grid.tileSide(in: frame)
        XCTAssertLessThanOrEqual(side, rect.width)
        XCTAssertLessThanOrEqual(side, rect.height)
    }

    /// A design written before the grid existed has no such key, and Swift does
    /// not apply property defaults to missing keys.
    func testADesignWithoutAGridStillDecodes() throws {
        let design = DesignDocument.new(name: "Test", sourceVideoName: "source.mp4")
        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try JSONEncoder().encode(design)) as? [String: Any]
        )
        json.removeValue(forKey: "grid")
        let decoded = try JSONDecoder().decode(
            DesignDocument.self,
            from: try JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertEqual(decoded.grid, WidgetGrid())
    }

    func testATileWithoutACellStillDecodes() throws {
        let tile = PlacedTile(appID: "spotify", center: .zero, size: 100)
        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try JSONEncoder().encode(tile)) as? [String: Any]
        )
        json.removeValue(forKey: "cell")
        let decoded = try JSONDecoder().decode(
            PlacedTile.self,
            from: try JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertNil(decoded.cell)
    }

    func testACellSurvivesATileRoundTrip() throws {
        var tile = PlacedTile(appID: "spotify", center: .zero, size: 100)
        tile.cell = GridCell(row: 1, column: 3)
        let decoded = try JSONDecoder().decode(
            PlacedTile.self,
            from: try JSONEncoder().encode(tile)
        )
        XCTAssertEqual(decoded.cell?.label, "R2C4")
    }
}

/// A scene is its clip, so taking the design's own clip out is a swap: one of
/// the variants steps into its place. Getting it wrong leaves the document
/// pointing at a file that is gone, which is a design that will not build.
final class ClipPromotionTests: XCTestCase {
    private func design(variants: [ClipVariant], default id: UUID? = nil) -> DesignDocument {
        var subject = DesignDocument.new(name: "Scene", sourceVideoName: "own.mp4")
        subject.variants = variants
        subject.defaultVariantID = id
        subject.primaryClipName = "Rainy day"
        return subject
    }

    func testTheLastClipCannotGo() {
        XCTAssertNil(ClipPromotion.promoting(in: design(variants: [])))
    }

    func testTheFirstVariantTakesOverWhenTheSceneLeadsWithItsOwn() throws {
        let storm = ClipVariant(name: "Storm", sourceVideoName: "storm.gif")
        let sunset = ClipVariant(name: "Sunset", sourceVideoName: "sunset.gif")
        let result = try XCTUnwrap(ClipPromotion.promoting(in: design(variants: [storm, sunset])))

        XCTAssertEqual(result.design.sourceVideoName, "storm.gif")
        XCTAssertEqual(result.design.primaryClipName, "Storm")
        XCTAssertEqual(result.design.variants.map(\.name), ["Sunset"])
        XCTAssertEqual(result.retiredFileName, "own.mp4")
    }

    /// The clip a phone already shows is the one to keep, so it is the one that
    /// takes over rather than whichever happens to be first.
    func testTheClipTheSceneLeadsWithTakesOver() throws {
        let storm = ClipVariant(name: "Storm", sourceVideoName: "storm.gif")
        let sunset = ClipVariant(name: "Sunset", sourceVideoName: "sunset.gif")
        let result = try XCTUnwrap(
            ClipPromotion.promoting(in: design(variants: [storm, sunset], default: sunset.id))
        )

        XCTAssertEqual(result.design.sourceVideoName, "sunset.gif")
        XCTAssertEqual(result.design.primaryClipName, "Sunset")
        XCTAssertEqual(result.design.variants.map(\.name), ["Storm"])
    }

    /// It is the design's own clip now, and that is what nil means. Leaving the
    /// id would name a variant that no longer exists, and the build writes no
    /// default at all for one of those.
    func testThePromotedClipStopsBeingTheNamedDefault() throws {
        let sunset = ClipVariant(name: "Sunset", sourceVideoName: "sunset.gif")
        let result = try XCTUnwrap(
            ClipPromotion.promoting(in: design(variants: [sunset], default: sunset.id))
        )
        XCTAssertNil(result.design.defaultVariantID)
    }

    /// A default pointing at some other variant is still valid, so it stays.
    func testAnUnrelatedDefaultIsLeftAlone() throws {
        let storm = ClipVariant(name: "Storm", sourceVideoName: "storm.gif")
        let sunset = ClipVariant(name: "Sunset", sourceVideoName: "sunset.gif")
        var subject = design(variants: [storm, sunset], default: sunset.id)
        subject.defaultVariantID = sunset.id
        // Leads with Sunset, so Sunset takes over; nothing else is named.
        let result = try XCTUnwrap(ClipPromotion.promoting(in: subject))
        XCTAssertNil(result.design.defaultVariantID)

        subject.defaultVariantID = nil
        let plain = try XCTUnwrap(ClipPromotion.promoting(in: subject))
        XCTAssertNil(plain.design.defaultVariantID, "Storm took over, and it was not the default")
    }

    func testEverythingElseAboutTheDesignSurvives() throws {
        var subject = design(variants: [ClipVariant(name: "Storm", sourceVideoName: "storm.gif")])
        subject.tiles = [PlacedTile(appID: "spotify", center: CGPoint(x: 10, y: 20), size: 100)]
        subject.loopStartFrame = 7
        let result = try XCTUnwrap(ClipPromotion.promoting(in: subject))

        XCTAssertEqual(result.design.id, subject.id)
        XCTAssertEqual(result.design.tiles, subject.tiles)
        XCTAssertEqual(result.design.mediaTransform, subject.mediaTransform)
        XCTAssertEqual(result.design.loopStartFrame, 7)
    }
}
