import XCTest

/// Photographs the app's own full-screen preview of a runtime-frame design
/// repeatedly.
///
/// The app cannot draw the widget's animation - the mask is timer text and only
/// the system widget renderer advances that - so it swaps one picture on a timer
/// instead, choosing it from the same cycle phase the mask would. That is easy to
/// get subtly wrong in a way no unit test sees: a preview that never advances, or
/// one that advances on its own clock and disagrees with the widget beside it.
/// The only evidence either way is the same screen photographed twice.
///
/// Shots are named the way the widget burst names them, so `read-frames.py` reads
/// both without knowing which produced them.
///
/// Environment: MOTIONARY_BURST_COUNT, MOTIONARY_BURST_GAP_MS.
final class AppPreviewTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The import sheet is reachable and drawn.
    ///
    /// Not the whole flow: handing a clip over is `PHPickerViewController`'s job,
    /// it runs out of process, and driving it is not evidence about this app. What
    /// this does cover is that the button exists, the sheet opens, and the
    /// controls that decide the build are on it - which is what silently broke
    /// when the old library UI was archived.
    func testTheImportSheetOpens() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-MotionaryFontLabOff"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))

        let add = app.buttons["Add a clip from Photos"]
        XCTAssertTrue(add.waitForExistence(timeout: 15), "there is no way to add a clip")
        add.tap()

        XCTAssertTrue(
            app.staticTexts["Add a clip"].waitForExistence(timeout: 10),
            "the import sheet did not open"
        )
        XCTAssertTrue(app.buttons["Choose a video or GIF"].waitForExistence(timeout: 5))
        // The two settings that decide what the build costs. A sheet without them
        // builds whatever the defaults are and gives no way to say otherwise.
        XCTAssertTrue(app.buttons["Frame rate"].exists || app.staticTexts["Frame rate"].exists)
        XCTAssertTrue(app.buttons["Frames on disk"].exists || app.staticTexts["Frames on disk"].exists)
        XCTAssertFalse(app.buttons["Build"].isEnabled, "Build is offered before a clip was chosen")
    }

    func testCaptureTheAppAnimating() throws {
        let environment = ProcessInfo.processInfo.environment
        let count = Int(environment["MOTIONARY_BURST_COUNT"] ?? "") ?? 24
        let gap = UInt32(environment["MOTIONARY_BURST_GAP_MS"] ?? "") ?? 200

        let app = XCUIApplication()
        // Off, explicitly. The font lab lives in the app group's defaults and a
        // simulator left with it on shows the lab rather than the design.
        app.launchArguments = ["-MotionaryFontLabOff"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        // The frames are decoded off the main thread after launch; photographing
        // straight away catches the wallpaper on its own and says the preview
        // does not animate when it has not started yet.
        usleep(4_000_000)

        let folder = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        for index in 0 ..< count {
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            let screenshot = XCUIScreen.main.screenshot()
            let url = folder.appendingPathComponent("burst-\(String(format: "%03d", index))-\(stamp).png")
            try screenshot.pngRepresentation.write(to: url)
            usleep(gap * 1000)
        }
        print("SHOT \(folder.path)")
    }
}
