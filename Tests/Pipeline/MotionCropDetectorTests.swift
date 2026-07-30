import CoreGraphics
import XCTest

/// The crop the detector returns is the whole cost model: every pixel inside it
/// is re-encoded into all 480 glyph selections, and every pixel outside it comes
/// free from the still backdrop. So what matters is not "did it find the motion"
/// but "how much still picture did it drag in with it".
final class MotionCropDetectorTests: XCTestCase {
    /// A 64-column grid over a 640-wide screen makes one analysis cell exactly
    /// 10x10 pixels, so a block's size in cells can be stated rather than
    /// guessed at.
    private let screen = CGSize(width: 640, height: 1280)
    private let cell: CGFloat = 10

    private func frame(blocks: [CGRect]) -> CGImage {
        let context = CGContext(
            data: nil, width: Int(screen.width), height: Int(screen.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(origin: .zero, size: screen))
        context.setFillColor(gray: 1, alpha: 1)
        // Blocks are given in the space the detector answers in - top-left
        // origin, the same as `CGImage.cropping(to:)` - while a CGContext fills
        // from the bottom up. Flipping here keeps every expectation below in the
        // coordinates the crop is actually used in.
        context.translateBy(x: 0, y: screen.height)
        context.scaleBy(x: 1, y: -1)
        for block in blocks { context.fill(block) }
        return context.makeImage()!
    }

    /// In cells, converted once here so the expectations read in cell terms.
    private func block(column: Int, row: Int, columns: Int, rows: Int) -> CGRect {
        CGRect(
            x: CGFloat(column) * cell, y: CGFloat(row) * cell,
            width: CGFloat(columns) * cell, height: CGFloat(rows) * cell
        )
    }

    private func detect(
        _ frames: [CGImage],
        minimumClusterCells: Int = 8
    ) -> MotionCropDetector.Result {
        var detector = MotionCropDetector()
        detector.minimumClusterCells = minimumClusterCells
        return detector.detect(frames: frames, screenSize: screen)
    }

    // MARK: - The basics it has always had to do

    func testASingleFrameAnimatesEverything() {
        // Nothing can be compared against, so refusing to guess is right: a
        // full-screen crop is expensive but never wrong.
        let result = detect([frame(blocks: [])])
        XCTAssertEqual(result.crop, CGRect(origin: .zero, size: screen))
        XCTAssertEqual(result.movingCellFraction, 1)
    }

    func testNothingMovingGivesAnEmptyCrop() {
        let still = frame(blocks: [block(column: 10, row: 10, columns: 20, rows: 20)])
        let result = detect([still, still, still])
        XCTAssertEqual(result.crop, .zero)
        XCTAssertEqual(result.clusterCount, 0)
    }

    func testTheCropCoversTheMovingBlockAndNotTheWholeScreen() {
        let moving = block(column: 20, row: 40, columns: 20, rows: 20)
        let result = detect([frame(blocks: []), frame(blocks: [moving])])
        XCTAssertTrue(result.crop.contains(moving), "the motion has to be inside the crop")
        XCTAssertLessThan(
            result.crop.width * result.crop.height,
            screen.width * screen.height / 2,
            "a block covering 1% of the screen should not cost half of it"
        )
    }

    // MARK: - What one stray cell costs

    /// The regression this exists for. A real 5s clip produced ten clusters -
    /// one of 1161 cells and nine of 1 to 24 - and those stragglers took the box
    /// from 28% of the widget to 51%, all of it still picture re-encoded 480
    /// times.
    func testAnIsolatedSpeckDoesNotWidenTheBox() {
        let subject = block(column: 20, row: 40, columns: 20, rows: 20)
        let speck = block(column: 2, row: 110, columns: 1, rows: 1)

        let withoutSpeck = detect([frame(blocks: []), frame(blocks: [subject])])
        let withSpeck = detect([frame(blocks: []), frame(blocks: [subject, speck])])

        XCTAssertEqual(
            withSpeck.crop, withoutSpeck.crop,
            "one moving cell in a far corner must not change the crop at all"
        )
        XCTAssertGreaterThan(withSpeck.discardedClusterCount, 0)
    }

    func testWithoutTheClusterFloorTheSpeckStillCostsTheBox() {
        // The previous behaviour, kept as a test so the saving is a measurement
        // rather than a claim.
        let subject = block(column: 20, row: 40, columns: 20, rows: 20)
        let speck = block(column: 2, row: 110, columns: 1, rows: 1)
        let loose = detect([frame(blocks: []), frame(blocks: [subject, speck])], minimumClusterCells: 1)
        let tight = detect([frame(blocks: []), frame(blocks: [subject, speck])])

        XCTAssertGreaterThan(
            loose.crop.height, tight.crop.height,
            "with no floor the box has to reach the speck"
        )
        XCTAssertEqual(loose.discardedClusterCount, 0)
        XCTAssertGreaterThan(
            loose.crop.width * loose.crop.height,
            tight.crop.width * tight.crop.height * 1.5,
            "the speck should cost noticeably more than half again the area"
        )
    }

    func testTwoRealRegionsAreBothCovered() {
        // Only small clusters are dropped. Two genuine subjects still have to be
        // inside one box, because there is only one glyph stack to put them in.
        let first = block(column: 5, row: 10, columns: 12, rows: 12)
        let second = block(column: 45, row: 100, columns: 12, rows: 12)
        let result = detect([frame(blocks: []), frame(blocks: [first, second])])
        XCTAssertTrue(result.crop.contains(first))
        XCTAssertTrue(result.crop.contains(second))
        XCTAssertEqual(result.discardedClusterCount, 0)
    }

    /// A crop of nothing fails the build outright, so when every cluster is
    /// below the floor the biggest one still gets animated.
    func testAllMotionBelowTheFloorStillAnimatesTheBiggestOfIt() {
        let dot = block(column: 30, row: 60, columns: 2, rows: 2)
        let result = detect([frame(blocks: []), frame(blocks: [dot])], minimumClusterCells: 5_000)
        XCTAssertFalse(result.crop.isEmpty)
        XCTAssertTrue(result.crop.intersects(dot))
    }

    func testOccupancyReportsHowMuchOfTheBoxActuallyMoves() {
        let solid = block(column: 20, row: 40, columns: 20, rows: 20)
        let result = detect([frame(blocks: []), frame(blocks: [solid])])
        XCTAssertGreaterThan(result.boxOccupancy, 0.8, "a solid block nearly fills its own box")

        // Two blocks on opposite diagonals of the same box leave most of it
        // still, which is what a low occupancy is meant to say.
        let sparse = detect([
            frame(blocks: []),
            frame(blocks: [
                block(column: 5, row: 10, columns: 10, rows: 10),
                block(column: 45, row: 100, columns: 10, rows: 10),
            ]),
        ])
        XCTAssertLessThan(sparse.boxOccupancy, 0.3)
    }

    // MARK: - Clustering itself

    func testDiagonalTouchingCellsAreOneCluster() {
        // 8-connected on purpose: an edge sweeping across the grid touches cells
        // corner to corner, and 4-connectivity would shatter it into singletons
        // and then discard every one of them.
        let columns = 8, rows = 8
        var moving = [Bool](repeating: false, count: columns * rows)
        for step in 0 ..< 5 { moving[step * columns + step] = true }
        let clusters = MotionCropDetector().clusters(in: moving, columns: columns, rows: rows)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters.first?.cells, 5)
    }

    func testSeparatedCellsAreSeparateClusters() {
        let columns = 8, rows = 8
        var moving = [Bool](repeating: false, count: columns * rows)
        moving[0] = true
        moving[7 * columns + 7] = true
        let clusters = MotionCropDetector().clusters(in: moving, columns: columns, rows: rows)
        XCTAssertEqual(clusters.count, 2)
        XCTAssertEqual(clusters.map(\.cells), [1, 1])
    }
}
