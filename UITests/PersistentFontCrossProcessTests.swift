import CoreText
import XCTest

/// Asks the one question the persistent font scope exists to answer: after an
/// app installs a font, can a *different* process draw with it?
///
/// This is the whole reason the scope was worth investigating. Every route
/// tried so far registers into one process, and the widget is rasterised by
/// another (`WidgetRenderer_Default`), so a scope that does not cross a process
/// boundary cannot help no matter how cleanly it registers.
///
/// The test runner is a separate app from Motionary, with its own CoreText
/// state and its own font cache, so it stands in for the renderer well enough
/// to settle the structural question. It is a weaker stand-in in one direction
/// only: the runner is a normal app and the renderer is a system process with
/// less reach, so anything the runner *cannot* see the renderer certainly
/// cannot either.
///
/// The font installed is one of Motionary's own bundled fonts, not a generated
/// one. That is deliberate: CoreText restricts the persistent scope to files
/// "in the application's bundle or an on-demand resource", so installing from
/// the bundle removes the location objection and isolates the sharing question.
/// A negative result therefore also rules out the fallback idea of somehow
/// getting generated fonts into the bundle.
///
/// What this test records is that the app is refused at the entitlement, and
/// that nothing reaches the second process. It does not, and cannot, show what
/// would happen with the Fonts capability granted - the simulator will not sign
/// one in. That gap does not matter for the decision, because the entitlement
/// is not what closes this route; the ban on installing fonts the app did not
/// ship is, and no entitlement lifts it. See `PersistentFontProbe`.
final class PersistentFontCrossProcessTests: XCTestCase {
    /// The shaping template, which is bundled in Motionary and deliberately not
    /// in its `UIAppFonts` - so nothing but the persistent install could make
    /// this name resolve anywhere, in either process.
    private let resource = "MotionTemplate-Regular"
    private let postScriptName = "CatFont0-Regular"

    override func setUp() {
        continueAfterFailure = true
    }

    func testAFontInstalledByTheAppIsNotVisibleToAnotherProcess() throws {
        XCTAssertFalse(
            PersistentFontProbe.resolves(postScriptName),
            "the runner already resolves \(postScriptName), so this test cannot tell a shared install from a local one"
        )

        let app = XCUIApplication()
        app.launchArguments += [PersistentFontProbe.installArgument, resource, postScriptName]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "Motionary did not launch")

        // Without this the test can pass while the app installed nothing at
        // all - which is exactly what happened when the resource name and the
        // PostScript name were assumed to be the same string.
        let banner = app.staticTexts[PersistentFontProbe.resultAccessibilityIdentifier]
        XCTAssertTrue(banner.waitForExistence(timeout: 15), "the app reported no install attempt at all")
        let appSide = banner.label

        // Motionary does not carry the Fonts capability, so the install is
        // refused before location ever comes into it. That refusal is the
        // finding, not a flaw in the test: it names the exact gate, and the
        // gate turns out to be the least of the three problems - see
        // PersistentFontProbe's notes.
        XCTAssertTrue(
            appSide.contains("302 missingEntitlement"),
            "the persistent install stopped failing on the entitlement; re-read what it does now: \(appSide)"
        )

        // The install happens in the app's `init`, so the banner is already
        // past it; the pause is for the font daemon, which works off the
        // calling thread.
        Thread.sleep(forTimeInterval: 3)

        let resolvedPlainly = PersistentFontProbe.resolves(postScriptName)
        // The documented way for a second process to reach a font installed by
        // a font provider app. If the answer is going to be yes anywhere, it is
        // here - and a widget renderer still could not do this, because on iOS
        // it puts a dialog in front of the user.
        let resolvedAfterRequest = PersistentFontProbe.requestFonts(named: postScriptName)

        let summary = """
        app side: \(appSide) | runner side: plain=\(resolvedPlainly) \
        afterRequestFonts=\(resolvedAfterRequest) \
        runnerPersistentRegistry=\(PersistentFontProbe.persistentlyRegisteredNames())
        """
        print("PROBE \(summary)")
        add(XCTAttachment(string: summary))

        XCTAssertFalse(
            resolvedPlainly,
            "a persistent install crossed a process boundary unaided - the whole route needs re-opening: \(summary)"
        )
        XCTAssertFalse(
            resolvedAfterRequest,
            "CTFontManagerRequestFonts pulled the font across - worth re-opening, though a widget renderer cannot call it: \(summary)"
        )
    }
}
