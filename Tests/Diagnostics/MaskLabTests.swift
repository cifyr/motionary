import XCTest

/// The lab is only readable if every lane in the stack belongs to exactly one
/// card. A gap shows as a black flash and an overlap shows as two cards at
/// once, and both look like the mask failing rather than the lab being wrong -
/// which would answer the question backwards.
final class MaskLabTests: XCTestCase {
    private let phasing = MaskLab.Phasing()

    func testEveryLaneIsClaimedByExactlyOneCard() {
        var claimed: [Int: Int] = [:]
        for half in 0 ..< 2 {
            for card in 0 ..< phasing.cardCount {
                for lane in phasing.lanes(card: card, half: half) {
                    XCTAssertNil(claimed[lane], "lane \(lane) is in two cards")
                    claimed[lane] = card
                }
            }
        }
        XCTAssertEqual(claimed.count, phasing.laneCount)
        XCTAssertEqual(Set(claimed.keys), Set(0 ..< phasing.laneCount))
    }

    /// Each card holds a contiguous run, so it stays up long enough to be
    /// photographed instead of flickering once per frame.
    func testACardHoldsAContiguousRunLongEnoughToSee() {
        for half in 0 ..< 2 {
            for card in 0 ..< phasing.cardCount {
                let lanes = phasing.lanes(card: card, half: half)
                XCTAssertEqual(lanes.count, phasing.lanesPerCard)
                XCTAssertEqual(lanes.upperBound - lanes.lowerBound, lanes.count)
            }
        }
        XCTAssertGreaterThanOrEqual(phasing.cardDuration, 0.2)
        XCTAssertEqual(phasing.cycleDuration, 2.0, accuracy: 0.001)
    }

    /// The second half is gated as a group, so a card's lanes in it must be the
    /// second half's lanes and not a repeat of the first's.
    func testTheSecondHalfCoversTheSecondHalfOfTheStack() {
        XCTAssertEqual(phasing.lanes(card: 0, half: 0).lowerBound, 0)
        XCTAssertEqual(phasing.lanes(card: 0, half: 1).lowerBound, phasing.lanesPerHalf)
        XCTAssertEqual(
            phasing.lanes(card: phasing.cardCount - 1, half: 1).upperBound,
            phasing.laneCount
        )
    }

    /// The same negation the composition uses. Getting the sign wrong shows one
    /// card forever, which is exactly the result that would be read as "a live
    /// mask does not gate pictures".
    func testTheOffsetIsTheCompositionsOwnNegatedLaneOffset() {
        XCTAssertEqual(phasing.blinkOffset(lane: 0), 0)
        XCTAssertEqual(phasing.blinkOffset(lane: 1), -phasing.frameDuration, accuracy: 0.0001)
        XCTAssertEqual(phasing.blinkOffset(lane: 4), -4 * phasing.frameDuration, accuracy: 0.0001)
    }

    /// A card count that does not divide the half would leave lanes unclaimed,
    /// and a stack with holes in it is not a result.
    func testAnUnevenSplitIsRefusedRatherThanDrawnWithHoles() {
        XCTAssertTrue(phasing.isValid)
        XCTAssertFalse(MaskLab.Phasing(laneCount: 32, cardCount: 5).isValid)
        XCTAssertEqual(MaskLab.Phasing(laneCount: 32, cardCount: 5).lanesPerCard, 0)
    }
}
