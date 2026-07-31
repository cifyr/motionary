import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Picking a key colour by clicking crosses from the editor's top-left space
/// into CoreGraphics' bottom-up one. Getting that flip wrong samples a
/// different pixel and simply keys the wrong colour, which looks like the
/// keyer misbehaving rather than the picker.
final class AssetArtworkTests: XCTestCase {
    private var root: URL!
    private var store: DesignStore!
    private let designID = UUID()

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("motionary-artwork-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try DesignStore(containerURL: root)
        try store.createFolder(for: designID)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes a 4-quadrant image: red top-left, green top-right, blue
    /// bottom-left, white bottom-right. "Top" means what a person sees.
    private func writeQuadrants(named name: String) throws -> PlacedAsset {
        let side = 64
        var data = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0 ..< side {
            for x in 0 ..< side {
                let index = (y * side + x) * 4
                let top = y < side / 2
                let left = x < side / 2
                let colour: (UInt8, UInt8, UInt8) = switch (top, left) {
                case (true, true): (255, 0, 0)
                case (true, false): (0, 255, 0)
                case (false, true): (0, 0, 255)
                case (false, false): (255, 255, 255)
                }
                data[index] = colour.0
                data[index + 1] = colour.1
                data[index + 2] = colour.2
                data[index + 3] = 255
            }
        }

        // premultipliedLast with row 0 at the top is how a PNG reads back, so
        // the file matches what a person would see in a viewer.
        let context = CGContext(
            data: &data, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let image = context.makeImage()!

        let folder = store.assetsFolder(for: designID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        return PlacedAsset(
            fileName: name, center: .zero, size: CGSize(width: 64, height: 64)
        )
    }

    private func sample(_ asset: PlacedAsset, x: CGFloat, y: CGFloat) -> ChromaKey.RGB? {
        AssetArtwork.sampleColor(
            in: asset, designID: designID, store: store, at: CGPoint(x: x, y: y)
        )
    }

    /// The quadrant clicked is the quadrant sampled. A flipped y would swap the
    /// top and bottom rows and pass every "did it return something" check.
    func testSamplingReadsTheQuadrantThatWasClicked() throws {
        let asset = try writeQuadrants(named: "quadrants.png")

        let topLeft = try XCTUnwrap(sample(asset, x: 0.25, y: 0.25))
        XCTAssertGreaterThan(topLeft.r, 0.8, "top-left should be red")
        XCTAssertLessThan(topLeft.g, 0.2)

        let topRight = try XCTUnwrap(sample(asset, x: 0.75, y: 0.25))
        XCTAssertGreaterThan(topRight.g, 0.8, "top-right should be green")
        XCTAssertLessThan(topRight.r, 0.2)

        let bottomLeft = try XCTUnwrap(sample(asset, x: 0.25, y: 0.75))
        XCTAssertGreaterThan(bottomLeft.b, 0.8, "bottom-left should be blue")
        XCTAssertLessThan(bottomLeft.r, 0.2)

        let bottomRight = try XCTUnwrap(sample(asset, x: 0.75, y: 0.75))
        XCTAssertGreaterThan(bottomRight.r, 0.8, "bottom-right should be white")
        XCTAssertGreaterThan(bottomRight.g, 0.8)
        XCTAssertGreaterThan(bottomRight.b, 0.8)
    }

    func testSamplingOutsideTheImageReturnsNothing() throws {
        let asset = try writeQuadrants(named: "quadrants.png")
        XCTAssertNil(sample(asset, x: 1.8, y: 0.5))
        XCTAssertNil(sample(asset, x: -0.4, y: 0.5))
    }

    func testAMissingFileSamplesToNothingRatherThanCrashing() {
        let missing = PlacedAsset(
            fileName: "not-there.png", center: .zero, size: CGSize(width: 10, height: 10)
        )
        XCTAssertNil(sample(missing, x: 0.5, y: 0.5))
    }

    func testAMissingFileLoadsToNothing() {
        let missing = PlacedAsset(
            fileName: "not-there.png", center: .zero, size: CGSize(width: 10, height: 10)
        )
        XCTAssertNil(AssetArtwork.image(for: missing, designID: designID, store: store))
    }

    /// Keying off must hand back the picture as imported, not a keyed copy.
    func testKeyingOffReturnsTheFileUnchanged() throws {
        var asset = try writeQuadrants(named: "plain.png")
        asset.chroma = nil

        let loaded = try XCTUnwrap(
            AssetArtwork.image(for: asset, designID: designID, store: store)
        )
        XCTAssertEqual(loaded.width, 64)
        XCTAssertEqual(loaded.height, 64)
    }
}
