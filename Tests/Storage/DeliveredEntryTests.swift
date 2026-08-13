import XCTest

/// A delivered design has to be as showable as a bundled one: the app swipes
/// through both, and the wallpaper it hands over is half the illusion. The
/// entry is one type with two homes, so what these pin down is that the
/// delivered home is read from at all - the bundle's paths resolve to nothing
/// in a test bundle, so a delivered entry falling back to them looks empty.
final class DeliveredEntryTests: XCTestCase {
    private var store: DesignStore!
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("entry-\(UUID().uuidString)")
        store = try DesignStore(containerURL: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func stage(name: String, frameDriven: Bool) throws -> DesignDocument {
        let design = DesignDocument.new(name: name, sourceVideoName: "source.mov")
        try store.createFolder(for: design.id)
        try store.save(design)
        try Data("wallpaper".utf8).write(to: store.wallpaperURL(for: design.id))
        try Data("plain".utf8).write(to: store.plainWallpaperURL(for: design.id))
        try store.writeWidgetBackdrop(Data("backdrop".utf8), ext: "png", for: design.id)

        var manifest = BuildManifest(
            designID: design.id,
            buildGeneration: 1,
            fontFamilyBase: "MFontTest",
            laneCount: 32,
            framesPerSecond: 16,
            loopFrameCount: 4,
            animationCrop: CGRect(x: 0, y: 0, width: 10, height: 10),
            widgetRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            screenSize: CGSize(width: 20, height: 40),
            wallpaperName: "wallpaper.png",
            totalFontBytes: 0,
            builtAt: Date()
        )
        manifest.frameCount = frameDriven ? 4 : nil
        try store.save(manifest)
        return design
    }

    func testADeliveredDesignIsListedAndFindsItsOwnFiles() throws {
        let design = try stage(name: "Sent", frameDriven: true)
        let entry = try XCTUnwrap(PrebuiltDesign.delivered(in: store).first)

        XCTAssertEqual(entry.id, design.id)
        XCTAssertEqual(entry.name, "Sent")
        XCTAssertTrue(entry.isDelivered)
        XCTAssertEqual(entry.wallpaperURL?.lastPathComponent, "wallpaper.png")
        XCTAssertEqual(entry.plainWallpaperURL?.lastPathComponent, "wallpaper-plain.png")
        XCTAssertEqual(entry.backdropURL?.lastPathComponent, "widget-backdrop.png")
        XCTAssertEqual(entry.manifest?.frameCount, 4)
        XCTAssertEqual(entry.artFolder?.lastPathComponent, "Art")
    }

    /// A design built as fonts cannot animate unless those fonts shipped in the
    /// extension, so offering one here would be offering a design the Home
    /// Screen will not draw.
    func testAFontBuiltDesignInTheStoreIsNotOffered() throws {
        try stage(name: "Fonts", frameDriven: false)
        XCTAssertTrue(PrebuiltDesign.delivered(in: store).isEmpty)
    }

    /// No preview video travels with a delivery - the frames are the animation
    /// - and the app has to get nil rather than a path to nothing.
    func testADeliveredDesignHasNoPreviewVideo() throws {
        try stage(name: "Sent", frameDriven: true)
        XCTAssertNil(PrebuiltDesign.delivered(in: store).first?.previewURL)
    }

    /// Newest first, because a design just sent to the phone is the one to look
    /// at, and ahead of the bundled ones for the same reason.
    func testTheNewestDeliveryComesFirst() throws {
        try stage(name: "Older", frameDriven: true)
        // `updatedAt` is stamped on save, and two saves inside one second would
        // otherwise tie.
        Thread.sleep(forTimeInterval: 1.1)
        try stage(name: "Newer", frameDriven: true)

        XCTAssertEqual(PrebuiltDesign.delivered(in: store).map(\.name), ["Newer", "Older"])
        XCTAssertEqual(PrebuiltDesign.all(in: store).first?.name, "Newer")
    }

    /// The selection names one design out of both homes; naming nothing takes
    /// the first, which is what a fresh install does.
    func testSelectionPicksFromBothHomes() throws {
        let first = try stage(name: "One", frameDriven: true)
        XCTAssertEqual(PrebuiltDesign.selected(id: first.id, in: store)?.id, first.id)
        XCTAssertEqual(PrebuiltDesign.selected(id: UUID(), in: store)?.id, first.id)
        XCTAssertEqual(PrebuiltDesign.selected(id: nil, in: store)?.id, first.id)
    }
}
