import XCTest

/// Photographs the screens the App Store listing is built from, so the frames
/// in Tools/store-frames are made of real app UI rather than mockups.
final class StoreShotTests: XCTestCase {
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
    }

    func testCaptureTheEditingScreens() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-welcomeSeen", "YES"]
        app.launch()

        let edit = app.buttons["Edit the spots: change an icon, fill an empty one, choose what it opens"]
        XCTAssertTrue(edit.waitForExistence(timeout: 15))
        edit.tap()
        // The spots only read as selectable once editing is on, which is the
        // state worth photographing.
        Thread.sleep(forTimeInterval: 1.5)
        try save("store-editing")

        // Whichever spot this design carries: the bundled starter's tiles are
        // named after the apps they open.
        let spot = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Change '")).firstMatch
        XCTAssertTrue(spot.waitForExistence(timeout: 10), "no editable spot on the bundled design")
        spot.tap()
        Thread.sleep(forTimeInterval: 2)
        try save("store-slot-editor")
    }
}
