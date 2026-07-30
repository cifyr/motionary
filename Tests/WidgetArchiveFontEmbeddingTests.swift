import SwiftUI
import XCTest

/// Pins down the one private WidgetKit switch that could have let a design built
/// on the phone reach the widget renderer.
///
/// It does not, and that is now measured rather than open: with the flag set and
/// read back as `true` inside the widget extension's own archived render, the
/// archived timeline is unchanged and the font is still written as a URL. See
/// `Tools/font-embed-shot.sh`. What is left here is the shim itself, kept as a
/// probe against a future iOS changing its mind, so these tests guard the shim's
/// two remaining properties: the accessors are still exported and callable with
/// the right convention, and the shim declines to call them when they are not.
///
/// What these cannot settle: they run in the simulator, which has none of the
/// device's sandbox restrictions, so nothing here says whether a font would
/// draw on a phone.
final class WidgetArchiveFontEmbeddingTests: XCTestCase {
    /// The accessors are reachable on the OS this test is running on.
    ///
    /// Worth failing loudly on. Not because a shipped build would break - it no
    /// longer references them - but because their disappearance is the one event
    /// that would make the probe's result stale.
    func testWidgetKitStillExportsTheEmbeddingAccessors() {
        XCTAssertTrue(
            WidgetArchiveFontEmbedding.isSymbolPresent,
            "WidgetKit no longer exports _wantsCustomFontsEmbeddedInArchive"
        )
    }

    /// The test target builds with the shim, so a failure here means the rest of
    /// this suite is silently testing stubs.
    func testTheProbeIsCompiledIntoTheTestBuild() {
        XCTAssertTrue(
            WidgetArchiveFontEmbedding.isLinked,
            "FONT_EMBED_PROBE is not set for MotionaryTests; these tests prove nothing"
        )
    }

    /// With the symbols reported absent, the modifier must not reach them.
    ///
    /// This is the whole safety story. The accessors are strong bindings resolved
    /// at launch, so on an OS that dropped them the stub is null and calling it
    /// takes the widget extension down. Asserted by observing that nothing was
    /// written back: `lastObserved` is only ever set from inside the closure that
    /// touches private API.
    @MainActor
    func testTheModifierDoesNotTouchTheAccessorsWhenTheSymbolIsAbsent() {
        WidgetArchiveFontEmbedding.resetLastObservedForTesting()
        let guarded = Text("12:34").embeddingCustomFontsInArchive(true, symbolPresent: false)
        let renderer = ImageRenderer(content: guarded)
        XCTAssertNotNil(renderer.uiImage, "the guarded view has to still render")
        XCTAssertNil(
            WidgetArchiveFontEmbedding.lastObserved,
            "the shim called into WidgetKit despite the symbol being reported missing"
        )
    }

    /// The same view with the symbol present does reach them, so the test above
    /// is measuring the guard rather than a modifier that never does anything.
    @MainActor
    func testTheModifierDoesTouchTheAccessorsWhenTheSymbolIsPresent() {
        WidgetArchiveFontEmbedding.resetLastObservedForTesting()
        let flagged = Text("12:34").embeddingCustomFontsInArchive(true, symbolPresent: true)
        let renderer = ImageRenderer(content: flagged)
        XCTAssertNotNil(renderer.uiImage)
        XCTAssertEqual(WidgetArchiveFontEmbedding.lastObserved, true)
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
