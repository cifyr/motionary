import XCTest

/// The lab is only readable if every lane in the stack belongs to exactly one
/// card. A gap shows as a black flash and an overlap shows as two cards at
/// once, and both look like the mask failing rather than the lab being wrong -
/// which would answer the question backwards.
final class MaskLabTests: XCTestCase {
    private let phasing = MaskLab.Phasing()

    func testEveryLaneIsClaimedByExactlyOneCard() {
        var claimed: [Int: Int] = [:]
        for card in 0 ..< phasing.cardCount {
            for lane in phasing.lanes(card: card) {
                XCTAssertNil(claimed[lane], "lane \(lane) is in two cards")
                claimed[lane] = card
            }
        }
        XCTAssertEqual(Set(claimed.keys), Set(0 ..< phasing.laneCount))
        for (lane, card) in claimed {
            XCTAssertEqual(phasing.card(forLane: lane), card)
        }
    }

    /// Each card holds a contiguous run, so it stays up long enough to be
    /// photographed instead of flickering once per frame.
    func testACardHoldsAContiguousRunLongEnoughToSee() {
        for card in 0 ..< phasing.cardCount {
            XCTAssertEqual(phasing.lanes(card: card).count, phasing.lanesPerCard)
        }
        XCTAssertGreaterThanOrEqual(phasing.cardDuration, 0.2)
        XCTAssertEqual(phasing.cycleDuration, 2.0, accuracy: 0.001)
    }

    /// The two halves are drawn separately - a mask isolates one lane only
    /// within a half - so between them they have to be the whole stack.
    func testTheHalvesCoverTheStackWithoutOverlapping() {
        XCTAssertEqual(phasing.lanes(half: 0).lowerBound, 0)
        XCTAssertEqual(phasing.lanes(half: 0).upperBound, phasing.lanesPerHalf)
        XCTAssertEqual(phasing.lanes(half: 1).lowerBound, phasing.lanesPerHalf)
        XCTAssertEqual(phasing.lanes(half: 1).upperBound, phasing.laneCount)
    }

    /// The measurement the sweep exists for: one distinct frame per lane, which
    /// is what a real design costs.
    func testOneCardPerLaneIsAValidStack() {
        let perLane = MaskLab.Phasing(laneCount: 32, cardCount: 32, cardPixels: 540)
        XCTAssertTrue(perLane.isValid)
        XCTAssertEqual(perLane.lanesPerCard, 1)
        XCTAssertEqual(perLane.card(forLane: 31), 31)
        XCTAssertEqual(perLane.cardDuration, perLane.frameDuration, accuracy: 0.0001)
    }

    /// The same negation the composition uses. Getting the sign wrong shows one
    /// card forever, which is exactly the result that would be read as "a live
    /// mask does not gate pictures".
    func testTheOffsetIsTheCompositionsOwnNegatedLaneOffset() {
        XCTAssertEqual(phasing.blinkOffset(lane: 0), 0)
        XCTAssertEqual(phasing.blinkOffset(lane: 1), -phasing.frameDuration, accuracy: 0.0001)
        XCTAssertEqual(phasing.blinkOffset(lane: 4), -4 * phasing.frameDuration, accuracy: 0.0001)
    }

    /// A card count that does not divide the stack would leave lanes unclaimed,
    /// and a stack with holes in it is not a result.
    func testAnUnevenSplitIsRefusedRatherThanDrawnWithHoles() {
        XCTAssertTrue(phasing.isValid)
        XCTAssertFalse(MaskLab.Phasing(laneCount: 32, cardCount: 5).isValid)
        XCTAssertEqual(MaskLab.Phasing(laneCount: 32, cardCount: 5).lanesPerCard, 0)
        XCTAssertFalse(MaskLab.Phasing(laneCount: 32, cardCount: 0).isValid)
    }

    /// A sweep is driven by argument, and a malformed one has to leave the
    /// previous point standing rather than silently measuring the default.
    func testTheSweepArgumentIsParsedOrRefused() throws {
        let parsed = try XCTUnwrap(
            MaskLab.launchPhasing(in: ["-MotionaryMaskLabStack", "32,32,540"])
        )
        XCTAssertEqual(parsed, MaskLab.Phasing(laneCount: 32, cardCount: 32, cardPixels: 540))
        XCTAssertNil(MaskLab.launchPhasing(in: ["-MotionaryMaskLabStack", "32,5,540"]))
        XCTAssertNil(MaskLab.launchPhasing(in: ["-MotionaryMaskLabStack", "32,32"]))
        XCTAssertNil(MaskLab.launchPhasing(in: ["-MotionaryMaskLabStack"]))
        XCTAssertNil(MaskLab.launchPhasing(in: []))
    }

    /// Pixels, not points: the caps this measures against are on pixel area and
    /// on the extension's footprint, and both are counted in real pixels.
    func testACardIsSizedInPixels() {
        let size = MaskLab.cardPixelSize(MaskLab.Phasing(cardPixels: 600))
        XCTAssertEqual(size.width, 600)
        XCTAssertEqual(size.height, 400)
    }
}
