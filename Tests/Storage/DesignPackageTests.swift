import XCTest

/// A package is the only thing that crosses between the Mac that builds a
/// design and the phone that shows it, so everything it drops is a design that
/// arrives looking broken with nothing to say why.
final class DesignPackageTests: XCTestCase {
    private var store: DesignStore!
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("package-tests-\(UUID().uuidString)")
        store = try DesignStore(containerURL: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Builds a design on disk with `count` frames of known, distinguishable
    /// content, so a package that shuffles them is caught rather than passing
    /// because every frame is the same bytes.
    @discardableResult
    private func stageDesign(frames count: Int) throws -> DesignDocument {
        let design = DesignDocument.new(name: "Packed", sourceVideoName: "source.mov")
        try store.createFolder(for: design.id)
        try store.save(design)
        try store.clearFrames(for: design.id)

        for index in 0 ..< count {
            let body = Data(repeating: UInt8(index % 251), count: 16 + index)
            try body.write(to: store.frameURL(for: design.id, index: index))
        }
        try Data("wallpaper".utf8).write(to: store.wallpaperURL(for: design.id))
        try Data("plain".utf8).write(to: store.plainWallpaperURL(for: design.id))
        try store.writeWidgetBackdrop(Data("backdrop".utf8), ext: "png", for: design.id)

        var manifest = BuildManifest(
            designID: design.id,
            buildGeneration: 1,
            fontFamilyBase: "MFontTest",
            laneCount: 32,
            framesPerSecond: 16,
            loopFrameCount: count,
            animationCrop: CGRect(x: 0, y: 0, width: 100, height: 100),
            widgetRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            screenSize: CGSize(width: 200, height: 400),
            wallpaperName: "wallpaper.png",
            totalFontBytes: 0,
            builtAt: Date()
        )
        manifest.frameCount = count
        try store.save(manifest)
        return design
    }

    func testAPackedDesignComesBackFrameForFrame() throws {
        let design = try stageDesign(frames: 6)
        let data = try DesignPackage.write(designID: design.id, store: store)

        let destination = try DesignStore(
            containerURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("package-in-\(UUID().uuidString)")
        )
        let restored = try DesignPackage.read(data, into: destination)

        XCTAssertEqual(restored.id, design.id)
        XCTAssertEqual(destination.frameCount(for: design.id), 6)
        for index in 0 ..< 6 {
            let original = try Data(contentsOf: store.frameURL(for: design.id, index: index))
            let arrived = try Data(contentsOf: destination.frameURL(for: design.id, index: index))
            XCTAssertEqual(arrived, original, "frame \(index) did not survive the round trip")
        }
        XCTAssertEqual(
            try Data(contentsOf: destination.wallpaperURL(for: design.id)),
            Data("wallpaper".utf8)
        )
        XCTAssertNotNil(destination.existingWidgetBackdropURL(for: design.id))
        XCTAssertEqual(try destination.loadManifest(id: design.id).frameCount, 6)
    }

    /// Every clip travels, not only the design's own.
    ///
    /// A variant is a whole alternate animation, and half of one on the phone
    /// is a clip that can be chosen and then cannot be drawn - which is what
    /// switching to it looks like from the sofa.
    func testEveryVariantTravelsWithTheDesign() throws {
        let design = try stageDesign(frames: 4)
        let variant = UUID()
        try store.clearFrames(for: design.id, variant: variant)
        for index in 0 ..< 3 {
            try Data(repeating: 200, count: 20 + index)
                .write(to: store.frameURL(for: design.id, index: index, variant: variant))
        }
        var manifest = try store.loadManifest(id: design.id)
        manifest.clipVariants = [BuildManifest.VariantBuild(
            id: variant,
            name: "Second",
            fontFamilyBase: "MFontTestV",
            totalFontBytes: 0,
            loopFrameCount: 3,
            frameCount: 3
        )]
        try store.save(manifest)

        let destination = try DesignStore(
            containerURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("package-variants-\(UUID().uuidString)")
        )
        try DesignPackage.read(
            try DesignPackage.write(designID: design.id, store: store),
            into: destination
        )

        XCTAssertEqual(destination.frameCount(for: design.id), 4, "the design's own clip")
        XCTAssertEqual(destination.frameCount(for: design.id, variant: variant), 3, "the variant")
        XCTAssertEqual(destination.frameFolders(for: design.id).count, 2)
        for index in 0 ..< 3 {
            XCTAssertEqual(
                try Data(contentsOf: destination.frameURL(for: design.id, index: index, variant: variant)),
                try Data(contentsOf: store.frameURL(for: design.id, index: index, variant: variant)),
                "variant frame \(index) did not survive"
            )
        }
        XCTAssertEqual(try destination.loadManifest(id: design.id).builtVariants.first?.frameCount, 3)
    }

    /// A rebuild that drops a variant must not leave its frames behind, or the
    /// phone goes on offering a clip the design no longer has.
    func testADroppedVariantDoesNotSurviveTheNextDelivery() throws {
        let design = try stageDesign(frames: 4)
        let gone = UUID()
        try store.clearFrames(for: design.id, variant: gone)
        try Data(repeating: 1, count: 10)
            .write(to: store.frameURL(for: design.id, index: 0, variant: gone))

        let destination = try DesignStore(
            containerURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("package-dropped-\(UUID().uuidString)")
        )
        try DesignPackage.read(
            try DesignPackage.write(designID: design.id, store: store),
            into: destination
        )
        XCTAssertEqual(destination.frameCount(for: design.id, variant: gone), 1)

        try store.clearAllFrames(for: design.id)
        for index in 0 ..< 4 {
            try Data(repeating: 2, count: 10)
                .write(to: store.frameURL(for: design.id, index: index))
        }
        try DesignPackage.read(
            try DesignPackage.write(designID: design.id, store: store),
            into: destination
        )
        XCTAssertEqual(destination.frameCount(for: design.id, variant: gone), 0)
        XCTAssertEqual(destination.frameFolders(for: design.id).count, 1)
    }

    /// The identity travels with the design, so delivering the same design
    /// twice replaces it rather than filling the phone with copies.
    func testDeliveringTwiceReplacesRatherThanAccumulates() throws {
        let design = try stageDesign(frames: 4)
        let data = try DesignPackage.write(designID: design.id, store: store)
        let destination = try DesignStore(
            containerURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("package-twice-\(UUID().uuidString)")
        )
        try DesignPackage.read(data, into: destination)
        try DesignPackage.read(data, into: destination)
        XCTAssertEqual(destination.loadAll().filter { $0.id == design.id }.count, 1)
        XCTAssertEqual(destination.frameCount(for: design.id), 4)
    }

    /// A shorter second delivery must not leave the tail of the first behind:
    /// those lanes would play as the end of a loop that no longer exists.
    func testAShorterDeliveryDoesNotLeaveTheOldTailBehind() throws {
        let long = try stageDesign(frames: 8)
        let longData = try DesignPackage.write(designID: long.id, store: store)
        let destination = try DesignStore(
            containerURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("package-shrink-\(UUID().uuidString)")
        )
        try DesignPackage.read(longData, into: destination)
        XCTAssertEqual(destination.frameCount(for: long.id), 8)

        try store.clearFrames(for: long.id)
        for index in 0 ..< 3 {
            try Data(repeating: 9, count: 12).write(to: store.frameURL(for: long.id, index: index))
        }
        var manifest = try store.loadManifest(id: long.id)
        manifest.frameCount = 3
        try store.save(manifest)

        try DesignPackage.read(
            try DesignPackage.write(designID: long.id, store: store),
            into: destination
        )
        XCTAssertEqual(destination.frameCount(for: long.id), 3)
    }

    /// A design built as fonts cannot be delivered at all, and saying so is the
    /// difference between a clear refusal and a widget that arrives black.
    func testAFontBuiltDesignIsRefusedWithAReasonRatherThanPackedEmpty() throws {
        let design = try stageDesign(frames: 4)
        var manifest = try store.loadManifest(id: design.id)
        manifest.frameCount = nil
        try store.save(manifest)

        XCTAssertThrowsError(try DesignPackage.write(designID: design.id, store: store)) { error in
            XCTAssertTrue(
                "\(error)".contains("built as fonts"),
                "the refusal has to say what to do about it: \(error)"
            )
        }
    }

    func testSomethingThatIsNotAPackageIsRefused() {
        XCTAssertThrowsError(try DesignPackage.header(of: Data(repeating: 7, count: 400)))
        XCTAssertThrowsError(try DesignPackage.header(of: Data()))
    }

    /// Truncation is what a half-finished download looks like, and it has to
    /// fail rather than write frames made of the next frame's bytes.
    func testATruncatedPackageIsRefusedRatherThanWrittenShifted() throws {
        let design = try stageDesign(frames: 5)
        let data = try DesignPackage.write(designID: design.id, store: store)
        let destination = try DesignStore(
            containerURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("package-cut-\(UUID().uuidString)")
        )
        XCTAssertThrowsError(
            try DesignPackage.read(data.prefix(data.count - 20), into: destination)
        )
    }
}
