import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// GIFs take a different decode path to video, and both feed the same fixed-rate
/// pipeline, so the resampling and the fit-to-screen step are what these cover.
final class MediaImportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("motionary-media-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Builds a real animated GIF so the decode path is exercised for real
    /// rather than against a stub.
    @discardableResult
    private func writeGIF(
        named name: String,
        frames: [CGColor],
        delay: Double = 0.1,
        size: CGSize = CGSize(width: 40, height: 40)
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frames.count, nil
        ))
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)

        for colour in frames {
            let context = try XCTUnwrap(CGContext(
                data: nil, width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(colour)
            context.fill(CGRect(origin: .zero, size: size))
            let image = try XCTUnwrap(context.makeImage())
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay],
            ] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func colour(_ r: Double, _ g: Double, _ b: Double) -> CGColor {
        CGColor(red: r, green: g, blue: b, alpha: 1)
    }

    // MARK: - Kind detection

    func testGIFIsDetectedByContentNotExtension() throws {
        // Photos can hand back a GIF under any filename, so the magic bytes
        // have to decide.
        let url = try writeGIF(named: "mislabelled.mov", frames: [colour(1, 0, 0), colour(0, 1, 0)])
        XCTAssertEqual(MediaKind.detect(at: url), .gif)
    }

    func testNonGIFFallsBackToVideo() throws {
        let url = directory.appendingPathComponent("clip.mov")
        try Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74]).write(to: url)
        XCTAssertEqual(MediaKind.detect(at: url), .video)
    }

    // MARK: - GIF decoding

    func testAnimatedGIFSummaryReportsFramesAndRate() async throws {
        let url = try writeGIF(
            named: "spin.gif",
            frames: [colour(1, 0, 0), colour(0, 1, 0), colour(0, 0, 1), colour(1, 1, 0)],
            delay: 0.25
        )
        let summary = try await MediaFrameExtractor(url: url).summary()

        XCTAssertEqual(summary.kind, .gif)
        XCTAssertEqual(summary.frameCount, 4)
        XCTAssertEqual(summary.duration, 1.0, accuracy: 0.05)
        XCTAssertEqual(summary.nominalFrameRate, 4, accuracy: 0.3)
        XCTAssertEqual(summary.naturalSize, CGSize(width: 40, height: 40))
    }

    /// A single-frame GIF cannot animate, and that should be said plainly at
    /// import rather than producing a widget that never moves.
    func testStillGIFIsRejectedWithAUsefulMessage() async throws {
        let url = try writeGIF(named: "still.gif", frames: [colour(1, 0, 0)])
        do {
            _ = try await MediaFrameExtractor(url: url).summary()
            XCTFail("a one-frame GIF should be rejected")
        } catch let error as MediaImportError {
            XCTAssertTrue("\(error)".contains("still image"), "\(error)")
        }
    }

    func testGIFFramesAreComposedToScreenSize() async throws {
        let url = try writeGIF(named: "two.gif", frames: [colour(1, 0, 0), colour(0, 0, 1)])
        let frames = try await MediaFrameExtractor(url: url).composedFrames(startFrame: 0, count: 4)

        XCTAssertEqual(frames.count, 4)
        for frame in frames {
            XCTAssertEqual(CGFloat(frame.width), DeviceGeometry.screenPixelSize.width)
            XCTAssertEqual(CGFloat(frame.height), DeviceGeometry.screenPixelSize.height)
        }
    }

    /// Sampling has to advance through the source, not return frame 0 forever.
    func testGIFResamplingAdvancesThroughTheSource() async throws {
        let url = try writeGIF(
            named: "alternating.gif",
            frames: [colour(1, 0, 0), colour(0, 0, 1)],
            delay: 0.5
        )
        let frames = try await MediaFrameExtractor(url: url).composedFrames(startFrame: 0, count: 2)
        XCTAssertNotEqual(centrePixel(frames[0]), centrePixel(frames[1]), "consecutive samples must differ")
    }

    func testGIFSamplingWrapsRatherThanRunningOut() async throws {
        let url = try writeGIF(named: "short.gif", frames: [colour(1, 0, 0), colour(0, 0, 1)])
        // Asking for more frames than the GIF holds must loop, not fail.
        let frames = try await MediaFrameExtractor(url: url).composedFrames(startFrame: 0, count: 8)
        XCTAssertEqual(frames.count, 8)
    }

    // MARK: - Placement

    func testScalingDownLeavesTheSourceSmallerOnScreen() async throws {
        let url = try writeGIF(named: "scale.gif", frames: [colour(1, 0, 0), colour(0, 1, 0)])

        let full = try await MediaFrameExtractor(url: url)
            .composedFrames(startFrame: 0, count: 1)[0]
        let shrunk = try await MediaFrameExtractor(
            url: url,
            transform: MediaTransform(scale: 0.4, offset: .zero, fillsBackground: false)
        ).composedFrames(startFrame: 0, count: 1)[0]

        // A corner is inside the source at full scale and outside it at 0.4.
        let corner = CGPoint(x: 20, y: 20)
        XCTAssertNotEqual(pixel(at: corner, in: full), pixel(at: corner, in: shrunk))
        XCTAssertEqual(pixel(at: corner, in: shrunk)[0], 0, "the uncovered corner should be black")
    }

    func testOffsetMovesTheSourceOnScreen() async throws {
        let url = try writeGIF(named: "offset.gif", frames: [colour(1, 0, 0), colour(0, 1, 0)])
        let centred = try await MediaFrameExtractor(
            url: url,
            transform: MediaTransform(scale: 0.3, offset: .zero, fillsBackground: false)
        ).composedFrames(startFrame: 0, count: 1)[0]
        let moved = try await MediaFrameExtractor(
            url: url,
            transform: MediaTransform(scale: 0.3, offset: CGPoint(x: 0, y: -700), fillsBackground: false)
        ).composedFrames(startFrame: 0, count: 1)[0]

        let high = CGPoint(x: DeviceGeometry.screenPixelSize.width / 2, y: 500)
        XCTAssertEqual(pixel(at: high, in: centred)[0], 0, "nothing there when centred")
        XCTAssertGreaterThan(pixel(at: high, in: moved)[0], 100, "moving up should bring the source here")
    }

    // MARK: - Shared placement

    /// The editor previews placement live and the generator bakes it. Both go
    /// through `placement`, so this pins the arithmetic they share.
    func testPlacementAspectFillsByDefault() {
        let screen = CGSize(width: 1206, height: 2622)
        // A square source has to be blown up to cover a tall screen, so it
        // overflows horizontally and sits flush top and bottom.
        let placed = MediaFrameExtractor.placement(
            sourceSize: CGSize(width: 400, height: 400),
            screenSize: screen,
            transform: .identity
        )
        XCTAssertEqual(placed.height, screen.height, accuracy: 0.01)
        XCTAssertEqual(placed.width, screen.height, accuracy: 0.01, "a square source scales uniformly")
        XCTAssertEqual(placed.midX, screen.width / 2, accuracy: 0.01)
        XCTAssertEqual(placed.midY, screen.height / 2, accuracy: 0.01)
    }

    func testPlacementScalesAboutTheCentre() {
        let screen = CGSize(width: 1206, height: 2622)
        let source = CGSize(width: 400, height: 400)
        let half = MediaFrameExtractor.placement(
            sourceSize: source,
            screenSize: screen,
            transform: MediaTransform(scale: 0.5, offset: .zero, fillsBackground: false)
        )
        let full = MediaFrameExtractor.placement(sourceSize: source, screenSize: screen, transform: .identity)

        XCTAssertEqual(half.width, full.width / 2, accuracy: 0.01)
        XCTAssertEqual(half.midX, full.midX, accuracy: 0.01, "scaling must not move the centre")
        XCTAssertEqual(half.midY, full.midY, accuracy: 0.01)
    }

    func testPlacementOffsetMovesRightAndDown() {
        let placed = MediaFrameExtractor.placement(
            sourceSize: CGSize(width: 400, height: 400),
            screenSize: CGSize(width: 1206, height: 2622),
            transform: MediaTransform(scale: 1, offset: CGPoint(x: 50, y: 80), fillsBackground: false)
        )
        let centred = MediaFrameExtractor.placement(
            sourceSize: CGSize(width: 400, height: 400),
            screenSize: CGSize(width: 1206, height: 2622),
            transform: .identity
        )
        XCTAssertEqual(placed.minX - centred.minX, 50, accuracy: 0.01)
        XCTAssertEqual(placed.minY - centred.minY, 80, accuracy: 0.01, "positive y is downward on screen")
    }

    /// The drag gesture and the baked frame must agree on direction, or the
    /// preview would move one way and the build the other.
    func testDraggingDownMatchesWhatIsBaked() async throws {
        let url = try writeGIF(named: "drag.gif", frames: [colour(1, 0, 0), colour(0, 1, 0)])
        let down = MediaTransform(scale: 0.3, offset: CGPoint(x: 0, y: 700), fillsBackground: false)

        let placed = MediaFrameExtractor.placement(
            sourceSize: CGSize(width: 40, height: 40),
            screenSize: DeviceGeometry.screenPixelSize,
            transform: down
        )
        XCTAssertGreaterThan(placed.midY, DeviceGeometry.screenPixelSize.height / 2, "placement says lower")

        let frame = try await MediaFrameExtractor(url: url, transform: down)
            .composedFrames(startFrame: 0, count: 1)[0]
        let low = CGPoint(x: DeviceGeometry.screenPixelSize.width / 2, y: placed.midY)
        let high = CGPoint(x: DeviceGeometry.screenPixelSize.width / 2, y: 2 * placed.midY - placed.maxY - 100)
        XCTAssertGreaterThan(pixel(at: low, in: frame)[0], 100, "the source should be drawn low")
        XCTAssertEqual(pixel(at: high, in: frame)[0], 0, "and not above where it was moved from")
    }

    func testScaleIsClampedAwayFromZero() {
        // A zero or negative scale would collapse the source entirely.
        let placed = MediaFrameExtractor.placement(
            sourceSize: CGSize(width: 400, height: 400),
            screenSize: CGSize(width: 1206, height: 2622),
            transform: MediaTransform(scale: 0, offset: .zero, fillsBackground: false)
        )
        XCTAssertGreaterThan(placed.width, 0)
    }

    func testPlacementOfAnEmptySourceIsEmptyRatherThanNaN() {
        let placed = MediaFrameExtractor.placement(
            sourceSize: .zero,
            screenSize: CGSize(width: 1206, height: 2622),
            transform: .identity
        )
        XCTAssertEqual(placed, .zero)
    }

    func testIdentityTransformIsTheDefault() {
        let design = DesignDocument.new(name: "t", sourceVideoName: "source.gif")
        XCTAssertTrue(design.mediaTransform.isIdentity)
    }

    /// Designs written before placement existed must still open.
    func testDesignWithoutMediaTransformDecodes() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Old","createdAt":0,"updatedAt":0,
         "sourceVideoName":"source.mov","animationCrop":[[0,0],[100,100]]}
        """
        let design = try JSONDecoder().decode(DesignDocument.self, from: Data(json.utf8))
        XCTAssertTrue(design.mediaTransform.isIdentity)
        XCTAssertEqual(design.loopFrameCount, 32)
        XCTAssertEqual(design.smoothness, .standard)
    }

    // MARK: - Helpers

    private func centrePixel(_ image: CGImage) -> [UInt8] {
        pixel(at: CGPoint(x: image.width / 2, y: image.height / 2), in: image)
    }

    private func pixel(at point: CGPoint, in image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 4)
        data.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.translateBy(x: -point.x, y: -(CGFloat(image.height) - point.y - 1))
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return [data[0], data[1], data[2]]
    }
}
