import SwiftUI
import XCTest

/// Pins down the one private WidgetKit switch that could let a design built on
/// the phone reach the widget renderer.
///
/// What these tests can and cannot settle. They run in the simulator, which has
/// none of the device's sandbox restrictions, so nothing here says a font will
/// draw on a phone. What they do settle is entirely OS-level and carries across:
/// whether WidgetKit still exports the accessors, whether calling them through
/// `@_silgen_name` has the right calling convention, and what the flag's default
/// is. Those are facts about the framework, not about the sandbox. The
/// question these cannot touch - whether a `true` flag actually changes what the
/// archiver writes - needs a widget render, and on device.
///
/// Written to fail loudly if the symbols disappear, because that is the event
/// worth being told about: the accessors are strong undefined symbols and their
/// removal takes the widget extension down in dyld at launch.
final class WidgetArchiveFontEmbeddingTests: XCTestCase {
    /// The accessors are reachable on the OS this test is running on.
    ///
    /// If this fails, the widget extension in this build cannot launch at all,
    /// so it is the first thing to check and the reason to check it here.
    func testWidgetKitStillExportsTheEmbeddingAccessors() {
        XCTAssertTrue(
            WidgetArchiveFontEmbedding.isSymbolPresent,
            "WidgetKit no longer exports _wantsCustomFontsEmbeddedInArchive; the extension will die in dyld"
        )
    }

    /// The setter runs inside a real SwiftUI environment and the value sticks -
    /// i.e. the `@_silgen_name` declarations match the real accessors' calling
    /// convention.
    ///
    /// This is the load-bearing assertion. Two wrong shims for these same
    /// symbols both link cleanly: a free function taking `inout
    /// EnvironmentValues`, and `dlsym` plus `@convention(c)`. Both segfault,
    /// and the free-function one can even round-trip `true` before it does,
    /// because the getter and setter agree on the same wrong `self`. So neither
    /// "it linked" nor "a value came back" is enough on its own - it has to
    /// survive a real render.
    @MainActor
    func testSettingTheFlagTakesEffectInARealRender() {
        XCTAssertTrue(WidgetArchiveFontEmbedding.roundTripsInARealRender())
    }

    /// The flag round-trips through the app group the widget extension reads.
    func testEnabledFlagRoundTripsThroughTheAppGroup() {
        let original = WidgetArchiveFontEmbedding.isEnabled
        defer { WidgetArchiveFontEmbedding.isEnabled = original }

        WidgetArchiveFontEmbedding.isEnabled = true
        XCTAssertTrue(WidgetArchiveFontEmbedding.isEnabled)
        WidgetArchiveFontEmbedding.isEnabled = false
        XCTAssertFalse(WidgetArchiveFontEmbedding.isEnabled)
    }

    func testLaunchArgumentsDriveTheFlag() {
        XCTAssertEqual(WidgetArchiveFontEmbedding.launchOverride(in: ["-MotionaryFontEmbeddingOn"]), true)
        XCTAssertEqual(WidgetArchiveFontEmbedding.launchOverride(in: ["-MotionaryFontEmbeddingOff"]), false)
        XCTAssertNil(WidgetArchiveFontEmbedding.launchOverride(in: ["-something-else"]))
    }

    /// Applying the modifier does not itself blow up the view tree.
    ///
    /// Weak on its own - a SwiftUI body is lazy - but it does exercise the
    /// `transformEnvironment(\.self)` closure, which is the part with private
    /// API in it.
    @MainActor
    func testModifierAppliesWithoutTrapping() {
        let flagged = Text("12:34").embeddingCustomFontsInArchive(true)
        let renderer = ImageRenderer(content: flagged)
        XCTAssertNotNil(renderer.uiImage, "a view carrying the flag would not render")
    }
}

/// Covers the classifier that decides which log lines are WidgetKit archiving
/// complaints, so the diagnostic does not go quiet by accident.
final class ArchiverErrorLogTests: XCTestCase {
    /// The strings matched here are `ArchivingError.errorDescription`'s own,
    /// verbatim from WidgetKit. `failedToEncode`'s is the one that matters: it
    /// names the offending types, which is the information this project was
    /// bisecting font routes to rediscover.
    func testRecognisesWidgetKitArchivingDescriptions() {
        let failedToEncode = "The body of the Widget entries' view contains the "
            + "following unsupported types: [SwiftUI.Font]"
        XCTAssertTrue(ArchiverErrorLog.isArchivingDiagnostic(failedToEncode))

        let imageTooLarge = "The body of the Widget entries' view contains an image of "
            + "size {4000, 6000} which is beyond the maximum of {2000, 1000}"
        XCTAssertTrue(ArchiverErrorLog.isArchivingDiagnostic(imageTooLarge))

        XCTAssertTrue(ArchiverErrorLog.isArchivingDiagnostic("Failed due to missing Widget metrics"))
        XCTAssertTrue(ArchiverErrorLog.isArchivingDiagnostic("Failed to lookup Widget bundle due to x"))
    }

    /// `badTimelineData` is a reload reason, not an archiving error. It must not
    /// be what this reports, or the diagnostic just reproduces the old mistake.
    func testIgnoresUnrelatedLines() {
        XCTAssertFalse(ArchiverErrorLog.isArchivingDiagnostic("reload reason: badTimelineData"))
        XCTAssertFalse(ArchiverErrorLog.isArchivingDiagnostic("ask timeline preview=false"))
    }

    /// Reading the current process's log works, or says why in one line rather
    /// than returning an empty list that reads as "no errors".
    func testReadingTheProcessLogEitherWorksOrSaysWhy() {
        let lines = ArchiverErrorLog.recent(within: 5)
        if let first = lines.first, lines.count == 1, first.hasPrefix("log unreadable:") {
            XCTFail("OSLogStore refused the current process: \(first)")
        }
    }
}
