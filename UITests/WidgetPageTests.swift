import XCTest

/// Puts the Home Screen page holding the Motionary widget on screen, and saves
/// what the widget looks like.
///
/// The widget can only be judged by looking at a rendered one, and until now
/// that meant mirroring a phone or posting mouse events at a simulator window -
/// both of which take over whoever's machine is running the build. XCUITest
/// drives SpringBoard from inside the simulator instead, so the whole loop can
/// run unattended.
final class WidgetPageTests: XCTestCase {
    private var springboard: XCUIApplication {
        XCUIApplication(bundleIdentifier: "com.apple.springboard")
    }

    override func setUp() {
        continueAfterFailure = false
    }

    /// Writes the current screen into the runner's Documents, where the host
    /// can pick it up out of the simulator's data directory.
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

    func testCaptureTheWidgetPage() throws {
        let springboard = self.springboard
        springboard.activate()
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 10))

        // Home from the home screen goes to the first page, so the sweep below
        // starts from a known place rather than wherever the last run left it -
        // which is how the widget's page got missed entirely.
        XCUIDevice.shared.press(.home)
        usleep(800_000)
        XCUIDevice.shared.press(.home)
        usleep(1_200_000)

        // Photographed rather than searched for by label: SpringBoard's element
        // tree changes underfoot while it is being queried, and the query
        // failing is not evidence about the widget.
        try save("page-0")
    }
}
