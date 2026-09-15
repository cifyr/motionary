import XCTest

/// Walks the first launch the way a new phone does, and photographs each page
/// so the welcome can be looked at rather than only compiled.
///
/// The flag lives in the app's standard defaults, which honour a launch
/// argument as an overriding domain - so `-welcomeSeen NO` forces the welcome
/// on a simulator that has already seen it, and a plain relaunch afterwards
/// shows whether finishing it was recorded.
final class WelcomeTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func save(_ name: String) throws {
        let screenshot = XCUIScreen.main.screenshot()
        let folder = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        let url = folder.appendingPathComponent("\(name).png")
        try screenshot.pngRepresentation.write(to: url)
        print("SHOT \(url.path)")

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTheWelcomeShowsOnceAndCanBeAskedForAgain() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-welcomeSeen", "NO"]
        app.launch()

        let next = app.buttons["Continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 10), "the welcome did not show on a first launch")
        try save("welcome-1")

        var page = 1
        while next.exists {
            next.tap()
            page += 1
            usleep(600_000)
            try save("welcome-\(page)")
        }
        XCTAssertEqual(page, 5, "the welcome has five pages")

        let finish = app.buttons["Get started"]
        XCTAssertTrue(finish.exists, "the last page does not offer to finish")
        finish.tap()

        let saveButton = app.buttons["Save the wallpaper to Photos"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 10), "finishing the welcome did not land on the design")
        XCTAssertFalse(next.exists)

        // The help lives behind the grid button, in the options sheet.
        app.buttons["Edit the spots: change an icon, fill an empty one, choose what it opens"].tap()
        app.buttons["Options"].tap()

        let guide = app.buttons["How to set it up"]
        XCTAssertTrue(guide.waitForExistence(timeout: 5), "the options sheet has no help section")
        if !guide.isHittable { app.swipeUp() }
        guide.tap()
        XCTAssertTrue(app.staticTexts["Place the widget"].waitForExistence(timeout: 5))
        try save("guide")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let about = app.buttons["About Motionary"]
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        about.tap()
        XCTAssertTrue(app.staticTexts["MOTIONARY"].waitForExistence(timeout: 5))
        try save("about")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let again = app.buttons["Show the welcome again"]
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        again.tap()
        XCTAssertTrue(next.waitForExistence(timeout: 10), "asking for the welcome again did not bring it back")
        app.buttons["Skip the welcome"].tap()
        XCTAssertTrue(saveButton.waitForExistence(timeout: 10))

        // A plain relaunch, with the recorded flag and nothing overriding it.
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(saveButton.waitForExistence(timeout: 10))
        XCTAssertFalse(next.waitForExistence(timeout: 2), "the welcome came back on a launch that should not show it")
    }
}
