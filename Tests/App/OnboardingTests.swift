import UIKit
import XCTest

/// Whether the welcome shows is decided by one flag, and a flag that is wrong
/// in either direction is invisible from a simulator that only ever installs
/// fresh: it would show on every launch, or never.
final class OnboardingTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "OnboardingTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testAFreshPhoneIsWelcomed() {
        XCTAssertTrue(Onboarding.needsWelcome(in: defaults))
    }

    func testSeeingItOnceIsEnough() {
        Onboarding.markWelcomeSeen(in: defaults)
        XCTAssertFalse(Onboarding.needsWelcome(in: defaults))
    }

    /// The options sheet offers it again, and that has to bring it back rather
    /// than only clearing something the welcome then ignores.
    func testAskingAgainBringsItBack() {
        Onboarding.markWelcomeSeen(in: defaults)
        Onboarding.resetWelcome(in: defaults)
        XCTAssertTrue(Onboarding.needsWelcome(in: defaults))
    }

    // MARK: - The steps

    /// Every page and every row is an SF Symbol plus two strings; a symbol
    /// name that does not exist draws nothing and says nothing.
    func testEverySymbolExists() {
        for step in SetupGuide.steps + SetupGuide.notes {
            XCTAssertNotNil(UIImage(systemName: step.symbol), "\(step.id): no symbol named \(step.symbol)")
        }
    }

    func testEveryStepSaysSomething() {
        for step in SetupGuide.steps + SetupGuide.notes {
            XCTAssertFalse(step.title.isEmpty, step.id)
            XCTAssertFalse(step.body.isEmpty, step.id)
            // Written as multi-line literals with continuation slashes; a
            // missing slash puts a hard break in the middle of a sentence.
            XCTAssertFalse(step.body.contains("\n"), "\(step.id): a line break inside the body")
            XCTAssertEqual(step.body, step.body.trimmingCharacters(in: .whitespacesAndNewlines), step.id)
        }
    }

    /// The welcome tags its pages by id, and two pages with one id would
    /// collapse into a single page without any warning.
    func testStepsAreDistinct() {
        let ids = (SetupGuide.steps + SetupGuide.notes).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "two steps share an id: \(ids)")
        XCTAssertGreaterThanOrEqual(SetupGuide.steps.count, 3, "a welcome needs the three steps that happen outside the app")
    }

    /// The three things the Home Screen needs done outside the app, in the
    /// order they happen. Reordering the list reorders the welcome.
    func testTheOutsideStepsComeInOrder() {
        let ids = SetupGuide.steps.map(\.id)
        let save = ids.firstIndex(of: "save")
        let wallpaper = ids.firstIndex(of: "wallpaper")
        let widget = ids.firstIndex(of: "widget")
        XCTAssertNotNil(save)
        XCTAssertNotNil(wallpaper)
        XCTAssertNotNil(widget)
        XCTAssertLessThan(save ?? 0, wallpaper ?? 0, "the wallpaper is saved before it is set")
        XCTAssertLessThan(wallpaper ?? 0, widget ?? 0, "the widget goes over a wallpaper that is already set")
    }

    /// The support link is built from this; an address with a typo sends
    /// every message nowhere.
    func testTheSupportAddressIsAnAddress() {
        let parts = AboutView.supportAddress.split(separator: "@")
        XCTAssertEqual(parts.count, 2, AboutView.supportAddress)
        XCTAssertTrue(parts.last?.contains(".") ?? false, AboutView.supportAddress)
        XCTAssertNotNil(URL(string: "mailto:\(AboutView.supportAddress)"))
    }
}
