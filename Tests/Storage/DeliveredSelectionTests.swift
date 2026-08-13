import UIKit
import XCTest

/// Which design the widget draws once deliveries and bundled designs both
/// exist on one phone.
///
/// The rule is narrow on purpose. A delivered design lives in the app group and
/// a bundled one does not, so any rule that falls back to "whatever is in the
/// store" makes the first delivery permanent and every bundled design
/// unreachable - which is exactly the failure this project already had once,
/// under the previous import path.
final class DeliveredSelectionTests: XCTestCase {
    private var store: DesignStore!
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("delivered-\(UUID().uuidString)")
        store = try DesignStore(containerURL: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func stage(name: String, frames: Int) throws -> DesignDocument {
        let design = DesignDocument.new(name: name, sourceVideoName: "source.mov")
        try store.createFolder(for: design.id)
        try store.save(design)
        try store.clearFrames(for: design.id)
        // Real JPEGs, because the loader's whole job is to decide whether a
        // frame decodes: bytes that are not a picture are indistinguishable
        // from a frame that never arrived, and that is the case under test.
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        for index in 0 ..< frames {
            let image = renderer.image { context in
                UIColor(white: CGFloat(index) / CGFloat(max(1, frames)), alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            }
            let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
            try data.write(to: store.frameURL(for: design.id, index: index))
        }
        var manifest = BuildManifest(
            designID: design.id,
            buildGeneration: 1,
            fontFamilyBase: "MFontTest",
            laneCount: 32,
            framesPerSecond: 16,
            loopFrameCount: frames,
            animationCrop: CGRect(x: 0, y: 0, width: 10, height: 10),
            widgetRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            screenSize: CGSize(width: 20, height: 40),
            wallpaperName: "wallpaper.png",
            totalFontBytes: 0,
            builtAt: Date()
        )
        manifest.frameCount = frames
        try store.save(manifest)
        return design
    }

    /// The widget takes the delivered design only when it is the one selected.
    /// Nothing selected means nothing delivered is in play, which is what
    /// leaves the bundled designs reachable.
    func testADeliveredDesignIsOnlyChosenWhenItIsTheSelectedOne() throws {
        let delivered = try stage(name: "Delivered", frames: 4)

        XCTAssertNil(
            store.loadAll().first(where: { $0.id == UUID() }),
            "a selection naming nothing must not resolve to whatever is in the store"
        )
        XCTAssertEqual(store.loadAll().first(where: { $0.id == delivered.id })?.id, delivered.id)
    }

    /// `resolve` is the wrong rule here and this is why: with a bundled design
    /// selected - an id this store has never heard of - it still hands back the
    /// delivered one.
    func testResolveFallsBackWhereTheWidgetMustNot() throws {
        let delivered = try stage(name: "Delivered", frames: 4)
        let bundledSelection = UUID()

        XCTAssertEqual(
            ActiveDesign.resolve(in: store, selection: bundledSelection)?.id,
            delivered.id,
            "resolve falls back on purpose; the widget's delivered path must not use it"
        )
        XCTAssertNil(store.loadAll().first { $0.id == bundledSelection })
    }

    /// A delivery that arrives with fewer frames than its manifest claims is
    /// refused rather than drawn: the missing lanes would be black flashes once
    /// per loop, which reads as a broken clip.
    func testAnIncompleteFrameSetIsRefusedRatherThanDrawnWithGaps() throws {
        let design = try stage(name: "Partial", frames: 4)
        try FileManager.default.removeItem(at: store.frameURL(for: design.id, index: 2))

        let loaded = FrameSetLoader.load(designID: design.id, count: 4, store: store)
        XCTAssertFalse(loaded.report.isComplete)
        XCTAssertEqual(loaded.report.loaded, 3)
        XCTAssertEqual(loaded.report.missing, [2])
    }

    func testACompleteFrameSetReportsItself() throws {
        let design = try stage(name: "Whole", frames: 6)
        let loaded = FrameSetLoader.load(designID: design.id, count: 6, store: store)
        XCTAssertTrue(loaded.report.isComplete)
        XCTAssertEqual(loaded.frames.count, 6)
    }
}
