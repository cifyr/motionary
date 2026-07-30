import XCTest

/// The calibration target is only worth photographing if its pixels are where it
/// says they are: every reading taken from it is relative to that promise.
final class EdgeLabTests: XCTestCase {
    func testBandsRepeatEveryThreeBlocks() {
        XCTAssertEqual(EdgeLab.bandLevel(atPixelY: 0), 0.25)
        XCTAssertEqual(EdgeLab.bandLevel(atPixelY: EdgeLab.bandHeightPixels - 1), 0.25)
        XCTAssertEqual(EdgeLab.bandLevel(atPixelY: EdgeLab.bandHeightPixels), 0.5)
        XCTAssertEqual(EdgeLab.bandLevel(atPixelY: EdgeLab.bandHeightPixels * 2), 0.75)
        XCTAssertEqual(EdgeLab.bandLevel(atPixelY: EdgeLab.bandHeightPixels * 3), 0.25)
    }

    /// Three levels, not one: an added rim moves them all by the same amount and
    /// a gain moves them in proportion, which one level cannot tell apart.
    func testThereAreEnoughLevelsToTellAnOffsetFromAGain() {
        XCTAssertGreaterThanOrEqual(EdgeLab.bandLevels.count, 2)
        XCTAssertEqual(Set(EdgeLab.bandLevels).count, EdgeLab.bandLevels.count)
        for level in EdgeLab.bandLevels {
            XCTAssertGreaterThan(level, 0.1, "a rim could clip at black and read as no effect")
            XCTAssertLessThan(level, 0.9, "a rim could clip at white and read as no effect")
        }
    }

    func testGridLinesSitOnTheSpacingAndNotOnTheEdge() {
        XCTAssertFalse(EdgeLab.isGridLine(pixel: 0), "a line on the boundary would hide the rings")
        XCTAssertTrue(EdgeLab.isGridLine(pixel: EdgeLab.gridSpacingPixels))
        XCTAssertFalse(EdgeLab.isGridLine(pixel: EdgeLab.gridSpacingPixels - 1))
    }

    /// Saturated and distinct, so any blend the composite applies shows up as a
    /// channel that should be 0 or 255 and is not.
    func testRingsAreOnePixelApartAndSaturated() {
        XCTAssertEqual(EdgeLab.rings.map(\.inset), Array(0 ..< EdgeLab.rings.count))
        XCTAssertLessThan(EdgeLab.rings.count, EdgeLab.fieldInset + 1)
        for ring in EdgeLab.rings {
            for channel in [ring.rgb.0, ring.rgb.1, ring.rgb.2] {
                XCTAssertTrue(channel == 0 || channel == 1, "\(ring.name) is not saturated")
            }
        }
        XCTAssertEqual(Set(EdgeLab.rings.map(\.name)).count, EdgeLab.rings.count)
    }
}
