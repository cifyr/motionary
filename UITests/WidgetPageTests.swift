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
    @discardableResult
    private func save(_ name: String) throws -> XCUIScreenshot {
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
        return screenshot
    }

    private func goHome() {
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
    }

    func testCaptureTheWidgetPage() throws {
        goHome()

        // Photographed rather than searched for by label: SpringBoard's element
        // tree changes underfoot while it is being queried, and the query
        // failing is not evidence about the widget.
        try save("page-0")
    }

    /// Photographs every Home Screen page, so the one holding the widget can be
    /// found without knowing in advance where iOS chose to put it.
    func testCaptureEveryPage() throws {
        goHome()
        for page in 0 ..< 4 {
            try save("page-\(page)")
            springboard.swipeLeft()
            usleep(1_200_000)
        }
    }

    /// Photographs the widget page repeatedly, stamping each shot with the wall
    /// clock it was taken at.
    ///
    /// This is the whole measurement for an animation nothing in the process
    /// drives: the extension is asked for one timeline and never runs again, so
    /// the only evidence that a frame changed is two pictures of the same
    /// widget taken at different times.
    ///
    /// Environment: MOTIONARY_BURST_COUNT, MOTIONARY_BURST_GAP_MS.
    func testCaptureABurst() throws {
        let environment = ProcessInfo.processInfo.environment
        let count = Int(environment["MOTIONARY_BURST_COUNT"] ?? "") ?? 24
        let gap = UInt32(environment["MOTIONARY_BURST_GAP_MS"] ?? "") ?? 250

        goHome()
        let page = Int(environment["MOTIONARY_BURST_PAGE"] ?? "") ?? 0
        for _ in 0 ..< page {
            springboard.swipeLeft()
            usleep(1_200_000)
        }
        usleep(1_500_000)

        for index in 0 ..< count {
            // Stamped before the capture: the name only has to order the shots
            // and say roughly when each was taken, and the capture itself is
            // the slow part.
            // Interpolated rather than formatted: milliseconds since 1970 do
            // not fit the 32-bit `%d` that `String(format:)` reaches for, and
            // the names came out negative and counting downwards.
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            try save("burst-\(String(format: "%03d", index))-\(stamp)")
            usleep(gap * 1000)
        }
    }
}
