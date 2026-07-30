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

    func testAssetsLiveInsideTheDesignFolder() {
        XCTAssertTrue(
            store.assetsFolder(for: designID).path.hasPrefix(store.folder(for: designID).path),
            "assets must travel with the design"
        )
    }
}
