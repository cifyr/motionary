import XCTest

/// Puts a Motionary widget on the simulator's Home Screen.
///
/// There is no API for placing a widget, and the alternatives - mirroring a
/// phone, or posting mouse events at a simulator window - take over whoever's
/// machine is running the build. SpringBoard is driven from inside the
/// simulator instead, so a fresh simulator can be brought to a state where the
/// widget is visible without anyone touching it.
final class WidgetPlacementTests: XCTestCase {
    private var springboard: XCUIApplication {
        XCUIApplication(bundleIdentifier: "com.apple.springboard")
    }

    override func setUp() {
        continueAfterFailure = false
    }

    private func save(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        guard let folder = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        let url = folder.appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: url)
        print("SHOT \(url.path)")
    }

    /// Adds the widget only when there is not one already, so the test can be
    /// left in the loop and run on every pass without stacking up widgets.
    func testPlaceTheWidget() throws {
        let springboard = self.springboard
        springboard.activate()
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 10))
        XCUIDevice.shared.press(.home)
        usleep(1_500_000)

        if springboard.otherElements["Motionary"].exists {
            print("PLACEMENT already present")
            save("placement-done")
            return
        }

        // Empty space below the icon grid, where no icon or dock item can
        // intercept the press.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62))
            .press(forDuration: 1.6)
        usleep(2_000_000)

        springboard.buttons["Edit"].tap()
        usleep(1_500_000)
        springboard.buttons["Add Widget"].tap()
        usleep(2_500_000)

        // The list is long enough that Motionary can start below the fold; the
        // search field is the only stable way to reach it.
        let search = springboard.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("Motionary")
        usleep(2_000_000)

        // Tapped through a coordinate: the row's label reports itself as not
        // hittable while the search keyboard is up, and `tap()` refuses on that
        // basis even though the row underneath takes the touch.
        let row = springboard.staticTexts["Motionary"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Motionary is not in the widget gallery")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        usleep(2_500_000)
        save("placement-detail")

        // Tapped at a fixed place rather than by name. The gallery's list is in
        // SpringBoard's element tree, but the sheet that opens on top of it is
        // not: dumping the tree while the sheet is plainly on screen returns
        // the Home Screen behind it, with no Add Widget anywhere in it. The
        // button is the full-width pill just above the home indicator.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.904)).tap()
        usleep(3_000_000)

        // Leaves jiggle mode, which otherwise dims and scales every widget on
        // the page and would be photographed instead of the real thing.
        springboard.buttons["Done"].firstMatch.tap()
        usleep(1_500_000)
        XCUIDevice.shared.press(.home)
        usleep(1_500_000)
        save("placement-done")
    }
}
