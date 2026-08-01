import XCTest

/// A tap that misses every icon. The address has to become a real web URL or
/// the widget draws a link that answers nothing, which looks exactly like a
/// widget whose gaps were meant to be dead.
final class BackgroundTapTests: XCTestCase {
    func testAPlainHostBecomesHTTPS() {
        XCTAssertEqual(BackgroundTap.url(for: "google.com")?.absoluteString, "https://google.com")
    }

    func testAWrittenSchemeIsLeftAlone() {
        XCTAssertEqual(BackgroundTap.url(for: "http://example.com")?.absoluteString, "http://example.com")
        XCTAssertEqual(BackgroundTap.url(for: "https://bbc.co.uk/news")?.absoluteString, "https://bbc.co.uk/news")
    }

    func testSurroundingSpaceIsIgnored() {
        XCTAssertEqual(BackgroundTap.url(for: "  example.com \n")?.absoluteString, "https://example.com")
    }

    func testNothingTypedIsNoDestination() {
        XCTAssertNil(BackgroundTap.url(for: ""))
        XCTAssertNil(BackgroundTap.url(for: "   "))
    }

    /// An app's own scheme is refused rather than passed on: a widget cannot
    /// open one reliably - which is why every tile goes through Motionary -
    /// so accepting it here would make a tap that silently does nothing.
    func testAnAppSchemeIsRefused() {
        XCTAssertNil(BackgroundTap.url(for: "spotify://"))
        XCTAssertNil(BackgroundTap.url(for: "motionary://launch/spotify"))
        XCTAssertNil(BackgroundTap.url(for: "mailto:someone@example.com"))
    }

    /// A scheme with nothing after it is not somewhere to go.
    func testAHostlessAddressIsRefused() {
        XCTAssertNil(BackgroundTap.url(for: "https://"))
    }

    func testTheDefaultAddressIsUsable() {
        XCTAssertNotNil(BackgroundTap.url(for: BackgroundTap.defaultAddress))
    }

    // MARK: - The stored setting

    override func tearDown() {
        let defaults = UserDefaults(suiteName: DesignStore.appGroupIdentifier)
        defaults?.removeObject(forKey: "backgroundTapEnabled")
        defaults?.removeObject(forKey: "backgroundTapAddress")
        super.tearDown()
    }

    /// A Home Screen whose gaps do something unexpected is worse than one
    /// whose gaps do nothing, so this stays off until it is asked for.
    func testItIsOffUntilSwitchedOn() {
        XCTAssertFalse(BackgroundTap.isEnabled)
        XCTAssertNil(BackgroundTap.destination)
    }

    func testSwitchingItOnGivesTheWidgetSomewhereToGo() {
        BackgroundTap.isEnabled = true
        BackgroundTap.address = "example.com"
        XCTAssertEqual(BackgroundTap.destination?.absoluteString, "https://example.com")
    }

    /// Switched on with something unusable typed, the widget must draw no link
    /// rather than one that refuses.
    func testAnUnusableAddressLeavesNoDestination() {
        BackgroundTap.isEnabled = true
        BackgroundTap.address = "spotify://"
        XCTAssertNil(BackgroundTap.destination)
    }
}
