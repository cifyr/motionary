import CoreGraphics
import XCTest

/// Geometry for phones nobody has measured.
///
/// The bar these have to clear is not "accurate" - only hardware settles that,
/// and the note on `DeviceModel` records an earlier derivation that came out
/// 22px wrong. The bar is that a phone which is not an iPhone 17 Pro stops
/// being handed a composition of entirely the wrong size.
final class DerivedGeometryTests: XCTestCase {
    private let iPhone16e = CGSize(width: 1170, height: 2532)
    private let iPhone17ProMax = CGSize(width: 1320, height: 2868)

    /// The measured phone must come back untouched. Everything else here is an
    /// approximation, and the one device that is not must not become one.
    func testTheMeasuredPhoneIsReturnedExactly() {
        let model = DeviceModel.matching(
            screenPixelSize: CGSize(width: 1206, height: 2622), scale: 3
        )
        XCTAssertEqual(model, .iPhone17Pro)
        XCTAssertTrue(model.isMeasured)
        XCTAssertEqual(model.widgetRect, CGRect(x: 66, y: 270, width: 1074, height: 1632))
    }

    func testAnUnmeasuredPhoneIsDerivedAndSaysSo() {
        let model = DeviceModel.matching(screenPixelSize: iPhone16e, scale: 3)
        XCTAssertFalse(model.isMeasured, "a scaled model must never claim to be measured")
        XCTAssertEqual(model.screenPixelSize, iPhone16e)
    }

    /// The whole point: the composition is the size of the screen it is for.
    func testTheCompositionIsTheSizeOfTheScreen() {
        for size in [iPhone16e, iPhone17ProMax] {
            let model = DeviceModel.matching(screenPixelSize: size, scale: 3)
            XCTAssertEqual(model.screenPixelSize, size)
            XCTAssertTrue(
                CGRect(origin: .zero, size: size).contains(model.widgetRect),
                "the widget frame must sit on the screen it was derived for"
            )
            XCTAssertTrue(
                CGRect(origin: .zero, size: size).contains(model.widgetRenderedRect),
                "so must the frame the system actually hands over"
            )
        }
    }

    /// The rendered frame contains the cut frame on the measured phone, and that
    /// relationship is what the padded backdrop relies on. Scaling must not
    /// invert it.
    func testTheCutFrameStillSitsInsideTheRenderedOne() {
        for size in [iPhone16e, iPhone17ProMax] {
            let model = DeviceModel.matching(screenPixelSize: size, scale: 3)
            XCTAssertTrue(
                model.widgetRenderedRect.contains(model.widgetRect),
                "\(size) inverted the two frames"
            )
        }
    }

    /// Proportions carry across, which is the one thing a scaled model can
    /// honestly promise.
    func testProportionsAreKept() {
        let base = DeviceModel.iPhone17Pro
        let model = DeviceModel.matching(screenPixelSize: iPhone17ProMax, scale: 3)
        let baseShare = base.widgetPixelSize.width / base.screenPixelSize.width
        let share = model.widgetPixelSize.width / model.screenPixelSize.width
        XCTAssertEqual(share, baseShare, accuracy: 0.002)
    }

    /// Corners scale with the narrow axis. Scaling them by height would make a
    /// taller phone's widget read as a rounder rectangle than it is.
    func testCornersFollowTheWidthNotTheHeight() {
        let model = DeviceModel.matching(screenPixelSize: iPhone17ProMax, scale: 3)
        let byWidth = DeviceModel.iPhone17Pro.widgetCornerRadius
            * (iPhone17ProMax.width / DeviceModel.iPhone17Pro.screenPixelSize.width)
        XCTAssertEqual(model.widgetCornerRadius, byWidth.rounded())
    }

    /// The icon grid is the part most likely to be wrong - iOS sizes icons in
    /// points per device class, not as a fraction of the screen - but it still
    /// has to land on the screen rather than off the bottom of it.
    func testTheIconGridStaysOnTheScreen() {
        for size in [iPhone16e, iPhone17ProMax] {
            let model = DeviceModel.matching(screenPixelSize: size, scale: 3)
            let last = model.iconRect(row: 5, column: 3)
            XCTAssertTrue(
                CGRect(origin: .zero, size: size).contains(last),
                "the last icon of the grid falls off a \(size) screen"
            )
        }
    }

    /// A phone smaller than the measured one is the case that would push the
    /// composition off the edge if anything were carried across unscaled.
    func testASmallerPhoneKeepsEverythingInside() {
        let small = CGSize(width: 750, height: 1334)      // iPhone SE, 2x
        let model = DeviceModel.matching(screenPixelSize: small, scale: 2)
        let screen = CGRect(origin: .zero, size: small)
        XCTAssertTrue(screen.contains(model.widgetRenderedRect))
        XCTAssertTrue(screen.contains(model.iconRect(row: 5, column: 3)))
        XCTAssertEqual(model.scale, 2)
    }
}
