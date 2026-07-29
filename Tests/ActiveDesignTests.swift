import XCTest

/// One selection drives both the app's home and the widget, so these fallbacks
/// are what stop a placed widget from going blank after a design is removed or
/// before anything has been chosen.
final class ActiveDesignTests: XCTestCase {
    private var container: URL!
    private var store: DesignStore!

    override func setUpWithError() throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("motionary-tests-\(UUID().uuidString)", isDirectory: true)
        store = try DesignStore(containerURL: container)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: container)
    }

    @discardableResult
    private func makeDesign(named name: String, built: Bool) throws -> DesignDocument {
        var design = DesignDocument.new(name: name, sourceVideoName: "source.mov")
        design.widgetSize = .large
        try store.save(design)
        if built {
            try store.save(BuildManifest(
                designID: design.id,
                buildGeneration: 1,
                fontFamilyBase: design.fontFamilyBase,
                laneCount: 32,
                framesPerSecond: 16,
                loopFrameCount: 32,
                animationCrop: CGRect(x: 0, y: 0, width: 100, height: 100),
                widgetRect: design.widgetRect,
                screenSize: DeviceGeometry.screenPixelSize,
                wallpaperName: "wallpaper.png",
                totalFontBytes: 1024,
                builtAt: Date()
            ))
        }
        return design
    }

    func testSelectionWins() throws {
        try makeDesign(named: "First", built: true)
        let chosen = try makeDesign(named: "Second", built: true)

        let resolved = ActiveDesign.resolve(in: store, selection: chosen.id)
        XCTAssertEqual(resolved?.id, chosen.id)
    }

    func testUnbuiltSelectionFallsBackToABuiltDesign() throws {
        let built = try makeDesign(named: "Built", built: true)
        let unbuilt = try makeDesign(named: "Unbuilt", built: false)

        // A design with no fonts on disk would render as an empty widget.
        let resolved = ActiveDesign.resolve(in: store, selection: unbuilt.id)
        XCTAssertEqual(resolved?.id, built.id)
    }

    func testRemovedSelectionSelfHeals() throws {
        let built = try makeDesign(named: "Built", built: true)
        let removed = UUID()

        let resolved = ActiveDesign.resolve(in: store, selection: removed)
        XCTAssertEqual(resolved?.id, built.id)
    }

    func testNoSelectionPicksTheMostRecentlyEditedBuildDesign() throws {
        try makeDesign(named: "Older", built: true)
        let newer = try makeDesign(named: "Newer", built: true)

        let resolved = ActiveDesign.resolve(in: store, selection: nil)
        XCTAssertEqual(resolved?.id, newer.id, "loadAll sorts by updatedAt descending")
    }

    func testEmptyLibraryResolvesToNothing() {
        XCTAssertNil(ActiveDesign.resolve(in: store, selection: nil))
    }

    func testUnbuiltOnlyLibraryStillResolvesSoTheEditorHasSomethingToShow() throws {
        let only = try makeDesign(named: "Only", built: false)
        XCTAssertEqual(ActiveDesign.resolve(in: store, selection: nil)?.id, only.id)
    }
}
