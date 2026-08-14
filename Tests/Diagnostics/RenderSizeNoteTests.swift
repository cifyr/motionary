import XCTest

/// The render log is the only thing that can be read back off a phone, so a
/// line in it that means two different things is worse than no line at all.
final class RenderSizeNoteTests: XCTestCase {
    func testAMeasuredRenderReportsItsPixels() {
        XCTAssertEqual(
            WidgetStatus.sizeNote(CGSize(width: 359.67, height: 548.33), scale: 3),
            "1079x1645px",
            "the size a full-screen widget was photographed at"
        )
    }

    func testAnUnmeasuredRenderSaysSoRatherThanSayingZero() {
        // Body evaluation runs before onAppear, so this is every extension
        // process's first render - the one worth reading after a delivery.
        XCTAssertEqual(WidgetStatus.sizeNote(.zero, scale: 3), "size-not-measured-yet")
    }

    func testAHalfMeasuredRenderIsNotMeasured() {
        XCTAssertEqual(
            WidgetStatus.sizeNote(CGSize(width: 359, height: 0), scale: 3),
            "size-not-measured-yet"
        )
    }
}
