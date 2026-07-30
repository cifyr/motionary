import CoreGraphics
import XCTest

final class PlacedAssetTests: XCTestCase {
    private func asset(
        name: String = "sticker.png",
        center: CGPoint = CGPoint(x: 100, y: 200),
        size: CGSize = CGSize(width: 300, height: 150)
    ) -> PlacedAsset {
        PlacedAsset(fileName: name, center: center, size: size)
    }

    func testRectIsCentredOnTheAssetsCentre() {
        let placed = asset(center: CGPoint(x: 100, y: 200), size: CGSize(width: 300, height: 150))
        XCTAssertEqual(placed.rect, CGRect(x: -50, y: 125, width: 300, height: 150))
    }

    /// Free aspect is the point of an asset: a tile is square, a picture is not.
    func testAnAssetKeepsANonSquareSize() {
        XCTAssertEqual(asset(size: CGSize(width: 400, height: 100)).size.height, 100)
    }

    func testRoundTripsThroughCoding() throws {
        var placed = asset()
        placed.rotation = 12.5
        placed.opacity = 0.4
        placed.zIndex = 3
        var chroma = ChromaKey.Settings.default
        chroma.setKeyColor(ChromaKey.RGB(r: 0.05, g: 0.75, b: 0.1))
        placed.chroma = chroma

        let data = try JSONEncoder().encode(placed)
        XCTAssertEqual(try JSONDecoder().decode(PlacedAsset.self, from: data), placed)
    }

    /// The store skips designs it cannot read, so a document written before a
    /// field existed has to decode rather than take the design out of the
    /// library. Only fileName, center and size are genuinely required.
    func testDecodesADocumentMissingEveryOptionalField() throws {
        let json = """
        {"fileName":"old.png","center":[10,20],"size":[30,40]}
        """
        let decoded = try JSONDecoder().decode(PlacedAsset.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.fileName, "old.png")
        XCTAssertEqual(decoded.rotation, 0)
        XCTAssertEqual(decoded.opacity, 1)
        XCTAssertEqual(decoded.zIndex, 0)
        XCTAssertNil(decoded.chroma)
    }

    /// A design saved before assets existed must still open, with none.
    func testADesignWithoutAnAssetsKeyDecodesToNoAssets() throws {
        let json = """
        {
          "id":"3E4C1E5A-0000-4000-8000-000000000001",
          "name":"old design",
          "createdAt":0,"updatedAt":0,
          "sourceVideoName":"source.mov",
          "animationCrop":[[0,0],[100,100]]
        }
        """
        let decoded = try JSONDecoder().decode(DesignDocument.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.assets, [])
        XCTAssertEqual(decoded.tiles, [])
    }

    func testAssetsSurviveADesignRoundTrip() throws {
        let json = """
        {
          "id":"3E4C1E5A-0000-4000-8000-000000000002",
          "name":"design","createdAt":0,"updatedAt":0,
          "sourceVideoName":"source.mov",
          "animationCrop":[[0,0],[100,100]]
        }
        """
        var design = try JSONDecoder().decode(DesignDocument.self, from: Data(json.utf8))
        design.assets = [asset(name: "a.png"), asset(name: "b.png")]

        let data = try JSONEncoder().encode(design)
        let reloaded = try JSONDecoder().decode(DesignDocument.self, from: data)
        XCTAssertEqual(reloaded.assets.map(\.fileName), ["a.png", "b.png"])
    }
}

final class DesignStoreAssetTests: XCTestCase {
    private var root: URL!
    private var store: DesignStore!
    private let designID = UUID()

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("motionary-assets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try DesignStore(containerURL: root)
        try store.createFolder(for: designID)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func sourceFile(named name: String, bytes: String = "x") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    func testImportingCopiesTheFileInAndReturnsItsName() throws {
        let name = try store.importAsset(try sourceFile(named: "sticker.png"), for: designID)

        XCTAssertEqual(name, "sticker.png")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.assetURL(for: designID, name: name).path
        ))
    }

    /// Every second export is called `image.png`. Overwriting would silently
    /// replace the picture already placed on the design.
    func testASecondFileOfTheSameNameIsNumberedRatherThanOverwriting() throws {
        let first = try store.importAsset(try sourceFile(named: "image.png", bytes: "one"), for: designID)
        try FileManager.default.removeItem(at: root.appendingPathComponent("image.png"))
        let second = try store.importAsset(try sourceFile(named: "image.png", bytes: "two"), for: designID)

        XCTAssertEqual(first, "image.png")
        XCTAssertEqual(second, "image-2.png")

        let firstContents = try String(contentsOf: store.assetURL(for: designID, name: first), encoding: .utf8)
        XCTAssertEqual(firstContents, "one", "the first asset was overwritten")
    }

    func testRemovingAnAssetDeletesItsFile() throws {
        let name = try store.importAsset(try sourceFile(named: "gone.png"), for: designID)
        store.removeAsset(named: name, for: designID)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.assetURL(for: designID, name: name).path
        ))
    }

    /// A half-deleted design must still open rather than throwing on the way in.
    func testRemovingAnAssetThatIsNotThereIsNotAnError() {
        store.removeAsset(named: "never-existed.png", for: designID)
    }

    // MARK: - Duplicating

    private func design(name: String = "Board") -> DesignDocument {
        let json = """
        {
          "id":"\(designID.uuidString)",
          "name":"\(name)","createdAt":0,"updatedAt":0,
          "sourceVideoName":"source.mov",
          "animationCrop":[[0,0],[100,100]]
        }
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(DesignDocument.self, from: Data(json.utf8))
    }

    func testDuplicatingCarriesTheClipAndThePictures() throws {
        var original = design()
        try Data("clip".utf8).write(to: store.folder(for: designID).appendingPathComponent("source.mov"))
        let asset = try store.importAsset(try sourceFile(named: "sticker.png", bytes: "art"), for: designID)
        original.assets = [PlacedAsset(
            fileName: asset, center: .zero, size: CGSize(width: 10, height: 10)
        )]
        try store.save(original)

        let copy = try store.duplicate(original)

        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.assets.map(\.fileName), [asset])
        XCTAssertEqual(
            try String(contentsOf: store.assetURL(for: copy.id, name: asset), encoding: .utf8),
            "art",
            "the copy did not get its own picture"
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.folder(for: copy.id).appendingPathComponent("source.mov").path
        ))
    }

    /// Editing the copy's pictures must not reach back into the original.
    func testTheCopyOwnsItsPicturesIndependently() throws {
        var original = design()
        let asset = try store.importAsset(try sourceFile(named: "sticker.png", bytes: "art"), for: designID)
        original.assets = [PlacedAsset(
            fileName: asset, center: .zero, size: CGSize(width: 10, height: 10)
        )]
        try store.save(original)

        let copy = try store.duplicate(original)
        store.removeAsset(named: asset, for: copy.id)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: store.assetURL(for: designID, name: asset).path),
            "removing the copy's picture deleted the original's"
        )
    }

    /// A duplicate must not quietly add ~29MB of fonts to the next install.
    func testACopyIsNeverStarred() throws {
        var original = design()
        original.isStarred = true
        try store.save(original)

        XCTAssertFalse(try store.duplicate(original).isStarred)
    }

    /// Build outputs belong to the id that produced them; carrying them over
    /// would leave the copy claiming a build it does not have.
    func testACopyDoesNotInheritTheBuild() throws {
        let original = design()
        try store.save(original)
        try Data("{}".utf8).write(to: store.manifestURL(for: designID))

        let copy = try store.duplicate(original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.manifestURL(for: copy.id).path))
    }

    /// A downloaded clip is named by digest, and a design named after one says
    /// nothing at all - which is how a library ends up unreadable even once
    /// every name in it is unique.
    func testADigestFilenameFallsBackToTheDate() {
        let made = Date(timeIntervalSinceReferenceDate: 0)

        XCTAssertTrue(DesignStore.looksLikeADigest("461e10bd3c4e275f5fb6cf09a3b70cb4"))
        XCTAssertTrue(DesignStore.looksLikeADigest("3E4C1E5A-0000-4000-8000-000000000001"))
        XCTAssertNotEqual(
            DesignStore.suggestedName(for: "461e10bd3c4e275f5fb6cf09a3b70cb4", created: made),
            "461e10bd3c4e275f5fb6cf09a3b70cb4"
        )
        XCTAssertTrue(
            DesignStore.suggestedName(for: "461e10bd3c4e275f5fb6cf09a3b70cb4", created: made)
                .hasPrefix("Clip ")
        )
    }

    func testARealNameIsKept() {
        let made = Date(timeIntervalSinceReferenceDate: 0)

        XCTAssertFalse(DesignStore.looksLikeADigest("onewheel-dock"))
        XCTAssertFalse(DesignStore.looksLikeADigest("0729 (1)"))
        // Short enough to be a word rather than a digest.
        XCTAssertFalse(DesignStore.looksLikeADigest("beadface"))

        XCTAssertEqual(DesignStore.suggestedName(for: "onewheel-dock", created: made), "onewheel-dock")
        XCTAssertEqual(DesignStore.suggestedName(for: "0729 (1)", created: made), "0729 (1)")
    }

    func testAnEmptyFilenameFallsBackToTheDate() {
        XCTAssertTrue(
            DesignStore.suggestedName(for: "  ", created: Date(timeIntervalSinceReferenceDate: 0))
                .hasPrefix("Clip ")
        )
    }

    /// Nineteen designs in the real library were all named after one downloaded
    /// GIF, which made the list impossible to navigate.
    func testASecondDesignOfTheSameNameIsNumbered() {
        XCTAssertEqual(DesignStore.uniqueName("clip", among: []), "clip")
        XCTAssertEqual(DesignStore.uniqueName("clip", among: ["clip"]), "clip 2")
        XCTAssertEqual(DesignStore.uniqueName("clip", among: ["clip", "clip 2"]), "clip 3")
        XCTAssertEqual(DesignStore.uniqueName("clip", among: ["other"]), "clip")
    }

    func testDuplicatingTwiceDoesNotProduceTwoDesignsOfTheSameName() throws {
        let original = design(name: "Board")
        try store.save(original)

        let first = try store.duplicate(original)
        let second = try store.duplicate(original)

        XCTAssertEqual(first.name, "Board copy")
        XCTAssertNotEqual(second.name, first.name)
    }

    /// Carrying a design between stores is not editing it. Restamping it puts
    /// the library in the order of the batch job rather than the order of work.
    func testSavingWithoutTouchingKeepsTheEditedTime() throws {
        var original = design(name: "Board")
        let stamped = Date(timeIntervalSinceReferenceDate: 100_000)
        original.updatedAt = stamped

        try store.save(original, touch: false)
        XCTAssertEqual(try store.load(id: designID).updatedAt, stamped)

        try store.save(original)
        XCTAssertGreaterThan(try store.load(id: designID).updatedAt, stamped)
    }

    func testCopyNamesDoNotCollideWhenDuplicatingTwice() {
        XCTAssertEqual(DesignStore.copyName(for: "Board"), "Board copy")
        XCTAssertEqual(DesignStore.copyName(for: "Board copy"), "Board copy 2")
        XCTAssertEqual(DesignStore.copyName(for: "Board copy 2"), "Board copy 3")
    }

    func testAssetsLiveInsideTheDesignFolder() {
        XCTAssertTrue(
            store.assetsFolder(for: designID).path.hasPrefix(store.folder(for: designID).path),
            "assets must travel with the design"
        )
    }
}
