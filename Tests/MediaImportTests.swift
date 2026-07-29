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
        let frames = try await MediaFrameExtractor(url: url).composedFrames(startFrame: 0, count: 4, frameRate: 16)

        XCTAssertEqual(frames.count, 4)
        for frame in frames {
            XCTAssertEqual(CGFloat(frame.width), DeviceGeometry.screenPixelSize.width)
            XCTAssertEqual(CGFloat(frame.height), DeviceGeometry.screenPixelSize.height)
        }
    }

    /// Sampling has to advance through the source, not return frame 0 forever.
    ///
    /// Samples are spaced at the design's rate, so a source slower than that
    /// repeats a frame for several samples. Crossing a source frame boundary is
    /// what must change the picture.
    func testGIFResamplingAdvancesThroughTheSource() async throws {
        let url = try writeGIF(
            named: "alternating.gif",
            frames: [colour(1, 0, 0), colour(0, 0, 1)],
            delay: 0.5
        )
        // At 16fps a 0.5s source frame spans 8 samples, so 0 and 8 straddle it.
        let frames = try await MediaFrameExtractor(url: url)
            .composedFrames(startFrame: 0, count: 9, frameRate: 16)
        XCTAssertEqual(centrePixel(frames[0]), centrePixel(frames[7]), "still inside the first source frame")
        XCTAssertNotEqual(centrePixel(frames[0]), centrePixel(frames[8]), "crossing into the second must change")
    }

    /// The bug this guards: frames were sampled on the source's timeline and
    /// replayed on the design's, so a source whose rate differed from the
    /// design's played at the wrong speed. Sampling at the target rate means a
    /// given sample index always lands at the same wall-clock moment in the
    /// source, whatever the source's own rate is.
    func testSamplingIsRealTimeRegardlessOfSourceRate() async throws {
        // Two GIFs of the same total duration but different frame rates.
        let slow = try writeGIF(
            named: "slow.gif",
            frames: [colour(1, 0, 0), colour(0, 0, 1)],
            delay: 0.5
        )
        let fast = try writeGIF(
            named: "fast.gif",
            frames: [colour(1, 0, 0), colour(1, 0, 0), colour(0, 0, 1), colour(0, 0, 1)],
            delay: 0.25
        )

        for rate in [8, 16, 32] {
            let count = rate  // one second of samples
            let slowFrames = try await MediaFrameExtractor(url: slow)
                .composedFrames(startFrame: 0, count: count, frameRate: rate)
            let fastFrames = try await MediaFrameExtractor(url: fast)
                .composedFrames(startFrame: 0, count: count, frameRate: rate)

            // Both sources switch colour halfway through their one second, so
            // both must switch at the same sample index whatever the rate.
            let slowSwitch = slowFrames.firstIndex { centrePixel($0) != centrePixel(slowFrames[0]) }
            let fastSwitch = fastFrames.firstIndex { centrePixel($0) != centrePixel(fastFrames[0]) }
            XCTAssertEqual(slowSwitch, count / 2, "slow source at \(rate)fps")
            XCTAssertEqual(fastSwitch, count / 2, "fast source at \(rate)fps")
        }
    }

    func testGIFSamplingWrapsRatherThanRunningOut() async throws {
        let url = try writeGIF(named: "short.gif", frames: [colour(1, 0, 0), colour(0, 0, 1)])
        // Asking for more frames than the GIF holds must loop, not fail.
        let frames = try await MediaFrameExtractor(url: url).composedFrames(startFrame: 0, count: 8, frameRate: 16)
        XCTAssertEqual(frames.count, 8)
    }

    // MARK: - Placement

    func testScalingDownLeavesTheSourceSmallerOnScreen() async throws {
        let url = try writeGIF(named: "scale.gif", frames: [colour(1, 0, 0), colour(0, 1, 0)])

        let full = try await MediaFrameExtractor(url: url)
            .composedFrames(startFrame: 0, count: 1, frameRate: 16)[0]
        let shrunk = try await MediaFrameExtractor(
            url: url,
            transform: MediaTransform(scale: 0.4, offset: .zero, fillsBackground: false)
        ).composedFrames(startFrame: 0, count: 1, frameRate: 16)[0]

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
        ).composedFrames(startFrame: 0, count: 1, frameRate: 16)[0]
        let moved = try await MediaFrameExtractor(
            url: url,
            transform: MediaTransform(scale: 0.3, offset: CGPoint(x: 0, y: -700), fillsBackground: false)
        ).composedFrames(startFrame: 0, count: 1, frameRate: 16)[0]

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
            .composedFrames(startFrame: 0, count: 1, frameRate: 16)[0]
        let low = CGPoint(x: DeviceGeometry.screenPixelSize.width / 2, y: placed.midY)
        let high = CGPoint(x: DeviceGeometry.screenPixelSize.width / 2, y: 2 * placed.midY - placed.maxY - 100)
        XCTAssertGreaterThan(pixel(at: low, in: frame)[0], 100, "the source should be drawn low")
        XCTAssertEqual(pixel(at: high, in: frame)[0], 0, "and not above where it was moved from")
    }

    // MARK: - Anchored pinch

    private let screen = CGSize(width: 1206, height: 2622)
    private let square = CGSize(width: 400, height: 400)

    /// Where a screen point falls within the source, as a fraction of it. If
    /// pinching holds the anchor, this is what must not change.
    private func sourceFraction(of point: CGPoint, under transform: MediaTransform) -> CGPoint {
        let rect = MediaFrameExtractor.placement(
            sourceSize: square, screenSize: screen, transform: transform
        )
        return CGPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
    }

    func testPinchKeepsTheAnchorOverTheSameBitOfSource() {
        let start = MediaTransform.identity
        for anchor in [
            CGPoint(x: 200, y: 400),
            CGPoint(x: 1000, y: 2200),
            CGPoint(x: 603, y: 1311),
        ] {
            let before = sourceFraction(of: anchor, under: start)
            for scale in [0.3, 0.75, 1.6, 3.0] {
                let zoomed = MediaFrameExtractor.transform(
                    start, scaledTo: scale, anchoredAt: anchor,
                    sourceSize: square, screenSize: screen
                )
                let after = sourceFraction(of: anchor, under: zoomed)
                XCTAssertEqual(after.x, before.x, accuracy: 0.0001, "anchor \(anchor) at \(scale)x")
                XCTAssertEqual(after.y, before.y, accuracy: 0.0001, "anchor \(anchor) at \(scale)x")
            }
        }
    }

    /// Pinching at the centre should behave as it did before anchoring, so the
    /// change does not alter the common case.
    func testPinchAtTheCentreLeavesTheOffsetAlone() {
        let centre = CGPoint(x: screen.width / 2, y: screen.height / 2)
        let zoomed = MediaFrameExtractor.transform(
            .identity, scaledTo: 2, anchoredAt: centre,
            sourceSize: square, screenSize: screen
        )
        XCTAssertEqual(zoomed.offset.x, 0, accuracy: 0.001)
        XCTAssertEqual(zoomed.offset.y, 0, accuracy: 0.001)
    }

    /// Pinching off-centre has to move the source, or the anchor could not
    /// have been held.
    func testPinchOffCentreMovesTheSource() {
        let zoomed = MediaFrameExtractor.transform(
            .identity, scaledTo: 2, anchoredAt: CGPoint(x: 100, y: 200),
            sourceSize: square, screenSize: screen
        )
        XCTAssertNotEqual(zoomed.offset.x, 0, accuracy: 0.001)
        XCTAssertNotEqual(zoomed.offset.y, 0, accuracy: 0.001)
    }

    func testPinchComposesFromAnExistingPlacement() {
        // Anchoring must work from wherever the source already sits, not only
        // from the identity transform.
        let start = MediaTransform(scale: 0.6, offset: CGPoint(x: -120, y: 350), fillsBackground: true)
        let anchor = CGPoint(x: 800, y: 900)
        let before = sourceFraction(of: anchor, under: start)

        let zoomed = MediaFrameExtractor.transform(
            start, scaledTo: 1.8, anchoredAt: anchor,
            sourceSize: square, screenSize: screen
        )
        let after = sourceFraction(of: anchor, under: zoomed)
        XCTAssertEqual(after.x, before.x, accuracy: 0.0001)
        XCTAssertEqual(after.y, before.y, accuracy: 0.0001)
        XCTAssertTrue(zoomed.fillsBackground, "unrelated settings must survive")
    }

    func testPinchOnAnEmptySourceDoesNotProduceNaN() {
        let zoomed = MediaFrameExtractor.transform(
            .identity, scaledTo: 2, anchoredAt: CGPoint(x: 10, y: 10),
            sourceSize: .zero, screenSize: screen
        )
        XCTAssertEqual(zoomed.scale, 2, accuracy: 0.001)
        XCTAssertFalse(zoomed.offset.x.isNaN)
        XCTAssertFalse(zoomed.offset.y.isNaN)
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

    // MARK: - Playback speed

    /// At 2x each output frame steps twice as far through the source, so a
    /// boundary that took eight samples to reach takes four.
    func testDoubleSpeedReachesTheBoundaryInHalfTheSamples() async throws {
        let url = try writeGIF(
            named: "speed.gif",
            frames: [colour(1, 0, 0), colour(0, 0, 1)],
            delay: 0.5
        )
        func switchIndex(speed: Double) async throws -> Int? {
            let frames = try await MediaFrameExtractor(url: url)
                .composedFrames(startFrame: 0, count: 16, frameRate: 16, speed: speed)
            return frames.firstIndex { centrePixel($0) != centrePixel(frames[0]) }
        }
        let normal = try await switchIndex(speed: 1)
        let double = try await switchIndex(speed: 2)
        let half = try await switchIndex(speed: 0.5)

        XCTAssertEqual(normal, 8)
        XCTAssertEqual(double, 4, "twice as fast reaches it in half the samples")
        XCTAssertEqual(half, nil, "half speed has not reached it within 16 samples")
    }

    func testSpeedIsClampedAwayFromZero() async throws {
        let url = try writeGIF(named: "zero.gif", frames: [colour(1, 0, 0), colour(0, 0, 1)])
        // A zero speed would divide by zero and never advance.
        let frames = try await MediaFrameExtractor(url: url)
            .composedFrames(startFrame: 0, count: 2, frameRate: 16, speed: 0)
        XCTAssertEqual(frames.count, 2)
    }

    /// Speeding up shortens the source, so the loop must shrink with it or it
    /// would replay part of the source twice.
    func testLoopSizingFollowsSpeed() {
        var design = DesignDocument.new(name: "t", sourceVideoName: "source.gif")
        design.smoothness = .standard
        design.sourceDuration = 1.2

        design.playbackSpeed = 1
        XCTAssertEqual(design.naturalLoopFrames, 38)
        design.playbackSpeed = 2
        XCTAssertEqual(design.naturalLoopFrames, 19)
        design.playbackSpeed = 0.5
        XCTAssertEqual(design.naturalLoopFrames, 77)
    }

    func testNaturalLoopFallsBackWithoutAKnownDuration() {
        var design = DesignDocument.new(name: "t", sourceVideoName: "source.gif")
        design.loopFrameCount = 24
        XCTAssertEqual(design.naturalLoopFrames, 24, "no duration means nothing better to say")
    }

    func testDesignWithoutSpeedDecodesAtNormalSpeed() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Old","createdAt":0,"updatedAt":0,
         "sourceVideoName":"source.gif","animationCrop":[[0,0],[100,100]]}
        """
        let design = try JSONDecoder().decode(DesignDocument.self, from: Data(json.utf8))
        XCTAssertEqual(design.playbackSpeed, 1)
        XCTAssertEqual(design.sourceDuration, 0)
    }

    // MARK: - Import defaults

    /// A phone-shaped clip should still fill the screen.
    func testPhoneShapedSourceStillFills() {
        let suggested = MediaTransform.suggested(
            sourceSize: CGSize(width: 1080, height: 1920),
            screenSize: screen
        )
        XCTAssertTrue(suggested.isIdentity, "a 9:16 clip loses little and should fill")
    }

    /// The case that prompted this: a 240x320 GIF on a 1206x2622 screen is
    /// magnified 8x and loses 39% of its width, showing a strip of the middle
    /// rather than the picture.
    func testSquarishSourceFitsInsteadOfBeingCropped() {
        let source = CGSize(width: 240, height: 320)
        XCTAssertGreaterThan(
            MediaTransform.croppedFraction(sourceSize: source, screenSize: screen), 0.35,
            "filling this source throws away most of its width"
        )

        let suggested = MediaTransform.suggested(sourceSize: source, screenSize: screen)
        XCTAssertFalse(suggested.isIdentity)
        XCTAssertTrue(suggested.fillsBackground, "the uncovered screen needs something behind it")

        // At the suggested scale the whole source is on screen.
        let placed = MediaFrameExtractor.placement(
            sourceSize: source, screenSize: screen, transform: suggested
        )
        XCTAssertLessThanOrEqual(placed.width, screen.width + 0.5)
        XCTAssertLessThanOrEqual(placed.height, screen.height + 0.5)
        XCTAssertEqual(max(placed.width / screen.width, placed.height / screen.height), 1, accuracy: 0.01)
    }

    func testCroppedFractionIsZeroWhenAspectsMatch() {
        XCTAssertEqual(
            MediaTransform.croppedFraction(sourceSize: CGSize(width: 1206, height: 2622), screenSize: screen),
            0, accuracy: 0.0001
        )
    }

    /// Truncating to the largest divisor below the natural length cut the last
    /// sixth of this GIF and jumped at the wrap.
    func testLoopLengthLandsOnTheNearestSeamlessDivisor() {
        let spec = TimerFontSpec(smoothness: .standard)
        // 1.2s at 32fps is 38 frames; 40 divides 960 and is closer than 32.
        XCTAssertEqual(spec.seamlessLoopLength(nearest: 38, maximum: 96), 40)
        XCTAssertEqual(spec.seamlessLoopLength(nearest: 32, maximum: 96), 32)
        XCTAssertEqual(spec.seamlessLoopLength(nearest: 61, maximum: 96), 60)
    }

    func testNearestLoopLengthAlwaysDividesTheCycle() {
        for smoothness in MotionSmoothness.allCases {
            let spec = TimerFontSpec(smoothness: smoothness)
            for natural in 1 ... 120 {
                let chosen = spec.seamlessLoopLength(nearest: natural, maximum: 96)
                XCTAssertTrue(spec.divides(loopFrameCount: chosen), "\(smoothness) natural \(natural) -> \(chosen)")
            }
        }
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
