import XCTest
import SwiftUI

/// What happens to a frame set that is already on the phone and too big to
/// draw.
///
/// Over the archive limit the widget is not drawn at all - not partially, not
/// with an error, black with `ok` written beside it. A build now shrinks its
/// frames to stay under, but a design delivered before that change is sitting
/// on a phone at whatever it was packed at and the extension cannot re-encode
/// it. This is the last line: draw fewer lanes rather than none.
final class OversizedFrameSetTests: XCTestCase {
    /// A set that fits is drawn whole. Thinning one that had room would cost
    /// smoothness nobody asked for.
    func testASetThatFitsIsDrawnWhole() {
        XCTAssertEqual(FramePayloadPlan.laneStride(forBytes: 1_000_000), 1)
        XCTAssertEqual(FramePayloadPlan.laneStride(forBytes: FramePayloadPlan.archiveLimit), 1)
    }

    /// The stride has to actually get the set under the limit, or it has bought
    /// nothing and the widget is still black.
    func testTheStrideGetsAnOversizedSetUnderTheLimit() {
        let limit = FramePayloadPlan.archiveLimit
        // 11.4MB is the real one: Aethetic Photos, delivered under the old
        // 12MB budget, black on a Home Screen until it was sent again.
        for bytes in [11_678_000, limit * 2, limit * 7 + 1] {
            let stride = FramePayloadPlan.laneStride(forBytes: bytes)
            XCTAssertGreaterThan(stride, 1, "\(bytes) bytes is over the limit")
            XCTAssertLessThanOrEqual(
                bytes / stride, limit,
                "1 lane in \(stride) still leaves \(bytes / stride) bytes"
            )
        }
    }

    /// The lanes that remain keep their own places in the cycle rather than
    /// closing up.
    ///
    /// This is the difference between a lower frame rate and a faster clip. The
    /// mask gates lane `n` at a fixed offset, so leaving gaps holds each
    /// surviving frame on top for `stride` phases and the loop still takes
    /// exactly as long; renumbering them would play the whole clip in a
    /// fraction of the time and repeat it.
    func testThinningLowersTheFrameRateRatherThanShorteningTheLoop() {
        // 80 lanes, every other one drawn: 40 frames, each up for two phases.
        let stride = 2
        let laneCount = 80
        let drawn = Array(Swift.stride(from: 0, to: laneCount, by: stride))
        XCTAssertEqual(drawn.count, 40)
        XCTAssertEqual(drawn.last, 78, "the last lane still sits at the end of the cycle")

        // Frame per drawn lane, which is what FrameStackLayer indexes with.
        let frames = drawn.map { FrameStackLayer.frameIndex(lane: $0 / stride, frameCount: 40) }
        XCTAssertEqual(frames, Array(0 ..< 40), "each frame is used once, in order")
    }

    /// A clip shorter than the stack still repeats around it after thinning,
    /// rather than leaving the rest of the cycle black.
    func testAShortClipStillRepeatsAroundTheCycle() {
        let stride = 2
        let drawn = Array(Swift.stride(from: 0, to: 80, by: stride))
        let frames = drawn.map { FrameStackLayer.frameIndex(lane: $0 / stride, frameCount: 10) }
        XCTAssertEqual(frames.count, 40)
        XCTAssertEqual(Set(frames), Set(0 ..< 10))
        XCTAssertEqual(frames.prefix(12), [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1])
    }
}
