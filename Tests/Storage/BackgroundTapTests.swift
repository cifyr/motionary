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

    /// Every row on offer has to lead somewhere, or the picker has an entry
    /// that quietly does nothing.
    func testEveryDestinationIsUsable() {
        for destination in BackgroundTap.allDestinations {
            XCTAssertNotNil(BackgroundTap.url(for: destination.address), destination.name)
            if let scheme = destination.scheme {
                XCTAssertNotNil(URL(string: scheme), destination.name)
            }
        }
        let ids = BackgroundTap.allDestinations.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "two destinations share an id")
        XCTAssertFalse(ids.contains(BackgroundTap.customValue), "a destination shadows the custom row")
    }

    // MARK: - Opening the browser itself

    /// A widget cannot open a custom scheme, so a browser goes through
    /// Motionary the same way every icon does - carrying its own scheme and
    /// its page, so an uninstalled browser lands somewhere rather than nowhere.
    func testABrowserTravelsThroughTheAppWithAFallback() throws {
        BackgroundTap.isEnabled = true
        BackgroundTap.choice = "arc"

        let link = try XCTUnwrap(BackgroundTap.widgetDestination)
        XCTAssertEqual(link.scheme, LaunchLink.scheme, "a widget cannot open arcmobile2:// itself")
        XCTAssertEqual(
            LaunchLink.candidates(from: link).map(\.absoluteString),
            ["arcmobile2://", "https://arc.net/"]
        )
    }

    /// A page needs no detour: https is the one thing a widget can hand
    /// straight to the browser.
    func testAPageGoesStraightOut() throws {
        BackgroundTap.isEnabled = true
        BackgroundTap.choice = "duckduckgo"
        XCTAssertEqual(
            try XCTUnwrap(BackgroundTap.widgetDestination).absoluteString,
            "https://duckduckgo.com"
        )
    }

    func testATypedPageGoesStraightOutToo() throws {
        BackgroundTap.isEnabled = true
        BackgroundTap.choice = BackgroundTap.customValue
        BackgroundTap.customAddress = "example.com"
        XCTAssertEqual(
            try XCTUnwrap(BackgroundTap.widgetDestination).absoluteString,
            "https://example.com"
        )
    }

    func testNothingAnswersWhenItIsOff() {
        BackgroundTap.choice = "arc"
        XCTAssertNil(BackgroundTap.widgetDestination)
    }

    // MARK: - The stored setting

    override func tearDown() {
        let defaults = UserDefaults(suiteName: DesignStore.appGroupIdentifier)
        defaults?.removeObject(forKey: "backgroundTapEnabled")
        defaults?.removeObject(forKey: "backgroundTapAddress")
        defaults?.removeObject(forKey: "backgroundTapChoice")
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
        BackgroundTap.choice = "duckduckgo"
        XCTAssertEqual(BackgroundTap.destination?.absoluteString, "https://duckduckgo.com")
    }

    /// The typed address is only used when it is what was chosen, so switching
    /// back to an engine does not leave the old one in force.
    func testAnEngineWinsOverWhateverWasTyped() {
        BackgroundTap.isEnabled = true
        BackgroundTap.customAddress = "example.com"
        BackgroundTap.choice = "bing"
        XCTAssertEqual(BackgroundTap.destination?.absoluteString, "https://www.bing.com")

        BackgroundTap.choice = BackgroundTap.customValue
        XCTAssertEqual(BackgroundTap.destination?.absoluteString, "https://example.com")
    }

    /// Switched on with something unusable typed, the widget must draw no link
    /// rather than one that refuses.
    func testAnUnusableAddressLeavesNoDestination() {
        BackgroundTap.isEnabled = true
        BackgroundTap.choice = BackgroundTap.customValue
        BackgroundTap.customAddress = "spotify://"
        XCTAssertNil(BackgroundTap.destination)
    }
}
