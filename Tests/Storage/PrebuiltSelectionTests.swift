import XCTest

/// The widget draws whichever bundled design the app last chose, and nothing
/// else. It used to prefer any built design sitting in the app group, which a
/// phone kept forever once one had been generated there: the wrong design, not
/// animated because its fonts were never bundled, and deaf to switching.
final class PrebuiltSelectionTests: XCTestCase {
    func testEveryBundledDesignCanBeSelectedByID() throws {
        let entries = PrebuiltDesign.entries
        try XCTSkipIf(entries.isEmpty, "no design is bundled into the test host")
        for entry in entries {
            XCTAssertEqual(
                PrebuiltDesign.selected(id: entry.id)?.id,
                entry.id,
                "\(entry.name) cannot be selected, so switching to it would do nothing"
            )
        }
    }

    /// A design that is not bundled cannot be drawn, so the selection has to
    /// fall back rather than leave the widget with nothing.
    func testAnUnknownSelectionFallsBackToTheFirstBundledDesign() throws {
        let entries = PrebuiltDesign.entries
        try XCTSkipIf(entries.isEmpty, "no design is bundled into the test host")
        XCTAssertEqual(PrebuiltDesign.selected(id: UUID())?.id, entries.first?.id)
        XCTAssertEqual(PrebuiltDesign.selected(id: nil)?.id, entries.first?.id)
    }

    /// Switching only means anything if the manifest follows the selection: the
    /// widget reads its geometry, its lanes and its tiles from there.
    func testTheManifestFollowsTheSelection() throws {
        let entries = PrebuiltDesign.entries
        try XCTSkipIf(entries.count < 2, "needs two bundled designs to switch between")
        for entry in entries {
            let manifest = PrebuiltDesign.selected(id: entry.id)?.manifest
            XCTAssertEqual(manifest?.designID, entry.id, "\(entry.name) resolves to another design's manifest")
        }
    }
}

/// The launch hook that stands in for a swipe, so a script can switch designs
/// without driving anybody's screen.
final class DesignLaunchSelectionTests: XCTestCase {
    func testAnIndexPicksThatBundledDesign() throws {
        let entries = PrebuiltDesign.entries
        try XCTSkipIf(entries.isEmpty, "no design is bundled into the test host")
        for (index, entry) in entries.enumerated() {
            XCTAssertEqual(
                PrebuiltDesign.launchSelection(in: ["-MotionaryDesignIndex", "\(index)"]),
                entry.id
            )
        }
    }

    /// nil rather than a guess, so a normal launch leaves whatever was swiped to
    /// alone instead of resetting it.
    func testNothingIsChosenWithoutTheArgument() {
        XCTAssertNil(PrebuiltDesign.launchSelection(in: []))
        XCTAssertNil(PrebuiltDesign.launchSelection(in: ["-MotionaryDesignIndex"]))
        XCTAssertNil(PrebuiltDesign.launchSelection(in: ["-MotionaryDesignIndex", "nonsense"]))
        XCTAssertNil(PrebuiltDesign.launchSelection(in: ["-MotionaryDesignIndex", "-1"]))
        XCTAssertNil(PrebuiltDesign.launchSelection(in: ["-MotionaryDesignIndex", "99"]))
    }
}
