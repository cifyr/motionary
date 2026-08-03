import CoreGraphics
import ImageIO
import XCTest

/// The backdrop is the one still in the payload, so it can afford to be
/// lossless when lossless is also the smaller file. Everything else in a build
/// is `lanes x 15` copies of a frame and has no such choice.
final class BackdropFormatTests: XCTestCase {
    private var root: URL!
    private var store: DesignStore!
    private let designID = UUID()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("motionary-backdrop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try DesignStore(containerURL: root)
        try store.createFolder(for: designID)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A flat background is what the choice exists for: PNG came out about
    /// seven times smaller than JPEG on the grey gradient this was found on.
    func testAFlatBackgroundIsKeptLossless() throws {
        let (data, ext) = try FrameEncoder.backdropData(gradient(width: 200, height: 400), quality: 0.95)
        XCTAssertEqual(ext, "png")

        let decoded = try decode(data)
        let original = try Pixel.all(of: gradient(width: 200, height: 400))
        XCTAssertEqual(try Pixel.all(of: decoded), original, "png was chosen, so nothing may have moved")
    }

    /// The other half of the rule. Noise is the case JPEG exists for, and a
    /// rule that always took PNG would put megabytes into the app bundle.
    func testANoisyBackgroundStaysJPEG() throws {
        let (_, ext) = try FrameEncoder.backdropData(noise(width: 200, height: 400), quality: 0.95)
        XCTAssertEqual(ext, "jpg")
    }

    /// Whichever is chosen must be the smaller one; that is the whole rule.
    func testTheSmallerEncodingWins() throws {
        for image in [gradient(width: 200, height: 400), noise(width: 200, height: 400)] {
            let (data, ext) = try FrameEncoder.backdropData(image, quality: 0.95)
            let other = ext == "png"
                ? FrameEncoder.jpegData(image, quality: 0.95)
                : try FrameEncoder.pngData(image)
            XCTAssertLessThanOrEqual(data.count, try XCTUnwrap(other).count)
        }
    }

    /// A design that switches format must not keep both. The reader prefers
    /// PNG, so a leftover PNG under a JPEG build is a stale backdrop drawn
    /// under a live design.
    func testWritingOneFormatRemovesTheOther() throws {
        try store.writeWidgetBackdrop(Data("png".utf8), ext: "png", for: designID)
        XCTAssertEqual(store.existingWidgetBackdropURL(for: designID)?.pathExtension, "png")

        try store.writeWidgetBackdrop(Data("jpeg".utf8), ext: "jpg", for: designID)
        XCTAssertEqual(store.existingWidgetBackdropURL(for: designID)?.pathExtension, "jpg")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.widgetBackdropURL(for: designID, ext: "png").path),
            "the png it replaced is still there, and it is the one the reader takes"
        )
    }

    func testNoBackdropReadsAsNoneRatherThanAMissingFile() {
        XCTAssertNil(store.existingWidgetBackdropURL(for: designID))
    }

    // MARK: - Fixtures

    private func context(width: Int, height: Int) -> CGContext {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
    }

    private func gradient(width: Int, height: Int) -> CGImage {
        let context = context(width: width, height: height)
        for y in 0 ..< height {
            let level = CGFloat(y) / CGFloat(height) * 0.4 + 0.2
            context.setFillColor(CGColor(red: level, green: level, blue: level, alpha: 1))
            context.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        return context.makeImage()!
    }

    /// Deterministic, so a run that fails is a run that can be repeated.
    private func noise(width: Int, height: Int) -> CGImage {
        let context = context(width: width, height: height)
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        for y in 0 ..< height {
            for x in 0 ..< width {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let value = CGFloat((seed >> 33) & 0xFF) / 255
                context.setFillColor(CGColor(red: value, green: 1 - value, blue: value, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return context.makeImage()!
    }

    private func decode(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private enum Pixel {
        static func all(of image: CGImage) throws -> [UInt8] {
            let width = image.width
            let height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            bytes.withUnsafeMutableBytes { raw in
                CGContext(
                    data: raw.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                )?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return bytes
        }
    }
}
