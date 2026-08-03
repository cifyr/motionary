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

    /// A source that is transparent everywhere but a small centred block — the
    /// shape a cut-out clip has, and the one the dimmed blow-up gets wrong.
    private func writeTransparentGIF(
        named name: String,
        frames: [CGColor],
        size: CGSize = CGSize(width: 40, height: 40)
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frames.count, nil
        ))
        for colour in frames {
            let context = try XCTUnwrap(CGContext(
                data: nil, width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.clear(CGRect(origin: .zero, size: size))
            context.setFillColor(colour)
            context.fill(CGRect(x: size.width / 4, y: size.height / 4, width: size.width / 2, height: size.height / 2))
            let image = try XCTUnwrap(context.makeImage())
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1],
            ] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    // MARK: - Transparent sources

    /// An alpha channel is not the same as a transparent pixel: a GIF decodes
    /// to an alpha format whatever it contains, so only the samples can decide.
    func testOnlyActualTransparencyCountsAsACutOut() throws {
        func image(_ alpha: CGImageAlphaInfo, clear: Bool) throws -> CGImage {
            let context = try XCTUnwrap(CGContext(
                data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: alpha.rawValue
            ))
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: clear ? 32 : 64))
            return try XCTUnwrap(context.makeImage())
        }
        XCTAssertTrue(MediaFrameExtractor.isCutOut(try image(.premultipliedLast, clear: true)))
        XCTAssertFalse(
            MediaFrameExtractor.isCutOut(try image(.premultipliedLast, clear: false)),
            "an opaque frame in an alpha format is not a cut-out"
        )
        XCTAssertFalse(MediaFrameExtractor.isCutOut(try image(.noneSkipLast, clear: true)))
    }

    /// The blow-up exists to hide behind an opaque clip and only show past its
    /// edges. A cut-out clip lets all of it through, which put a second, fainter
    /// copy of the subject on screen somewhere else entirely.
    func testTransparentSourceGetsNoDimmedBlowUpBehindIt() async throws {
        let url = try writeTransparentGIF(named: "cutout.gif", frames: [colour(1, 0, 0), colour(0, 1, 0)])
        let frame = try await MediaFrameExtractor(
            url: url,
            transform: MediaTransform(scale: 0.4, offset: .zero, fillsBackground: true)
        ).composedFrames(startFrame: 0, count: 1, frameRate: 16)[0]

        // Where the aspect-filled blow-up would have painted the block, but the
        // shrunken clip does not reach.
        let screen = DeviceGeometry.screenPixelSize
        let ghost = CGPoint(x: screen.width / 2, y: screen.height * 0.3)
        XCTAssertEqual(pixel(at: ghost, in: frame), [0, 0, 0], "a cut-out clip must not be echoed behind itself")
    }

    func testOpaqueSourceKeepsTheDimmedBlowUp() async throws {
        let url = try writeGIF(named: "opaque.gif", frames: [colour(1, 0, 0), colour(0, 1, 0)])
        let frame = try await MediaFrameExtractor(
            url: url,
            transform: MediaTransform(scale: 0.4, offset: .zero, fillsBackground: true)
        ).composedFrames(startFrame: 0, count: 1, frameRate: 16)[0]

        let corner = CGPoint(x: 20, y: 20)
        XCTAssertGreaterThan(pixel(at: corner, in: frame)[0], 40, "an opaque clip still fills the uncovered screen")
    }

    // MARK: - Loop length

    /// The cap used to be 96 frames, which is three seconds at 32fps: a ten
    /// second clip came out as its first third and the rest was never seen.
    func testTenSecondClipKeepsMoreThanItsFirstThreeSeconds() {
        var design = DesignDocument.new(name: "long", sourceVideoName: "long.mov")
        design.smoothness = MotionSmoothness.standard
        design.sourceDuration = 10.6
        design.retuneLoop()

        XCTAssertGreaterThan(design.loopDuration, 9, "a ten second clip must not be cut to three")
        XCTAssertTrue(
            design.spec.divides(loopFrameCount: design.loopFrameCount),
            "the loop still has to tile the 30s cycle"
        )
    }

    /// The cap bounds peak build memory, so every smoothness has to respect it
    /// while still landing on a length that tiles its own cycle.
    func testEverySmoothnessStaysWithinTheLoopCap() {
        for smoothness in MotionSmoothness.allCases {
            var design = DesignDocument.new(name: "long", sourceVideoName: "long.mov")
            design.smoothness = smoothness
            design.sourceDuration = 60
            design.retuneLoop()

            XCTAssertLessThanOrEqual(
                design.loopFrameCount, TimerFontSpec.maximumLoopFrames, "\(smoothness)"
            )
            XCTAssertTrue(design.spec.divides(loopFrameCount: design.loopFrameCount), "\(smoothness)")
        }
    }

    // MARK: - Centring

    func testCentringMovesTheClipOntoTheWidgetWithoutResizing() {
        let screen = CGSize(width: 1206, height: 2622)
        let widget = CGRect(x: 66, y: 270, width: 1074, height: 1632)
        let start = MediaTransform(scale: 0.5, offset: CGPoint(x: 400, y: -900), fillsBackground: true)
        let centred = start.centred(inside: widget, screenSize: screen)

        XCTAssertEqual(centred.scale, start.scale, "centring must not resize")
        XCTAssertTrue(centred.fillsBackground)

        let placed = MediaFrameExtractor.placement(
            sourceSize: CGSize(width: 400, height: 400),
            screenSize: screen,
            transform: centred
        )
        XCTAssertEqual(placed.midX, widget.midX, accuracy: 0.01)
        XCTAssertEqual(placed.midY, widget.midY, accuracy: 0.01)
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
        design.smoothness = MotionSmoothness.standard
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

/// The memory ceiling is a correctness constraint, not a preference: a widget
/// extension that exceeds it has its render dropped and shows black.
final class QualityPlanTests: XCTestCase {
    /// A smooth gradient, because that is roughly how compressible real footage
    /// is. Pure noise is not: it refuses to fit at any setting, which makes the
    /// planner look broken when it is being correct.
    private func gradient(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        for y in 0 ..< height {
            context.setFillColor(
                red: Double(y) / Double(height), green: 0.4,
                blue: 1 - Double(y) / Double(height), alpha: 1
            )
            context.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        return context.makeImage()!
    }

    private func noise(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        for x in stride(from: 0, to: width, by: 2) {
            for y in stride(from: 0, to: height, by: 2) {
                context.setFillColor(
                    red: Double((x * 7 + y * 13) % 255) / 255,
                    green: Double((x * 3 + y * 5) % 255) / 255,
                    blue: Double((x + y) % 255) / 255, alpha: 1
                )
                context.fill(CGRect(x: x, y: y, width: 2, height: 2))
            }
        }
        return context.makeImage()!
    }

    /// The one guarantee the planner must never break.
    func testAnyPlanItReturnsFitsTheBudget() throws {
        for side in [200, 600, 1074] {
            let height = side * 3 / 2
            for image in [gradient(width: side, height: height), noise(width: side, height: height)] {
                let crop = CGRect(x: 0, y: 0, width: side, height: height)
                if let plan = PayloadBudget.bestPlan(samples: [image], crop: crop) {
                    XCTAssertLessThanOrEqual(
                        plan.estimatedBytes, PayloadBudget.recommendedMaximumBytes,
                        "\(side)x\(height) produced an over-budget plan"
                    )
                    XCTAssertGreaterThanOrEqual(plan.quality, 0.3)
                }
            }
        }
    }

    func testATinyCropGetsTheSmoothestSetting() throws {
        let image = gradient(width: 200, height: 200)
        let plan = try XCTUnwrap(
            PayloadBudget.bestPlan(samples: [image], crop: CGRect(x: 0, y: 0, width: 200, height: 200))
        )
        XCTAssertEqual(plan.smoothness, .standard, "a small crop has room to spare")
    }

    /// Typical footage at the full widget frame should still be buildable.
    func testAFullFrameCropOfOrdinaryFootageFits() throws {
        let image = gradient(width: 1074, height: 1632)
        let plan = try XCTUnwrap(
            PayloadBudget.bestPlan(samples: [image], crop: CGRect(x: 0, y: 0, width: 1074, height: 1632))
        )
        XCTAssertLessThanOrEqual(plan.estimatedBytes, PayloadBudget.recommendedMaximumBytes)
    }

    /// Refusing is correct when nothing fits. Returning an over-budget plan
    /// would build a widget that renders black.
    func testAnImpossibleCropRefusesRatherThanOverspending() {
        let image = noise(width: 1206, height: 2622)
        let crop = CGRect(x: 0, y: 0, width: 1206, height: 2622)
        if let plan = PayloadBudget.bestPlan(samples: [image], crop: crop) {
            XCTAssertLessThanOrEqual(plan.estimatedBytes, PayloadBudget.recommendedMaximumBytes)
        }
    }
}

/// A preview renders the same composition against a smaller screen. The clip
/// has to land in the same place proportionally, or what plays on the canvas
/// stands somewhere the built one will not - which is exactly what a preview
/// exists to rule out.
final class ScaledTransformTests: XCTestCase {
    private let source = CGSize(width: 1080, height: 1916)
    private let screen = CGSize(width: 1290, height: 2796)
    /// The design this came out of: shifted a long way up the screen.
    private let transform = MediaTransform(
        scale: 1.147911931818182,
        offset: CGPoint(x: -1.0015828530907810, y: -165.35448267745141)
    )

    private func reduced(_ factor: Double) -> CGSize {
        CGSize(width: (screen.width * factor).rounded(), height: (screen.height * factor).rounded())
    }

    /// The multiplier is on the aspect-fill baseline, which means the same
    /// thing at any size, so it must not move.
    func testTheScaleIsUntouched() {
        XCTAssertEqual(transform.scaled(by: 0.2).scale, transform.scale)
        XCTAssertEqual(transform.scaled(by: 5).scale, transform.scale)
    }

    func testTheOffsetFollowsTheScreen() {
        let scaled = transform.scaled(by: 0.2)
        XCTAssertEqual(scaled.offset.x, transform.offset.x * 0.2, accuracy: 1e-9)
        XCTAssertEqual(scaled.offset.y, transform.offset.y * 0.2, accuracy: 1e-9)
    }

    func testFullSizeIsUnchanged() {
        XCTAssertEqual(transform.scaled(by: 1), transform)
    }

    /// The point of the whole thing: the clip lands on the same fraction of
    /// the picture whatever size the picture is rendered at.
    func testAReducedRenderPlacesTheClipInTheSameFraction() {
        let factor = 560.0 / max(screen.width, screen.height)
        let full = MediaFrameExtractor.placement(
            sourceSize: source, screenSize: screen, transform: transform
        )
        let small = MediaFrameExtractor.placement(
            sourceSize: source, screenSize: reduced(factor), transform: transform.scaled(by: factor)
        )

        // Loose by a fraction of a percent because the reduced screen rounds
        // its two dimensions independently, so its aspect - and the aspect-fill
        // baseline with it - is a hair off the real screen's.
        XCTAssertEqual(small.minX / reduced(factor).width, full.minX / screen.width, accuracy: 0.005)
        XCTAssertEqual(small.minY / reduced(factor).height, full.minY / screen.height, accuracy: 0.005)
        XCTAssertEqual(small.width / reduced(factor).width, full.width / screen.width, accuracy: 0.005)
    }

    /// And what it was before: the offset left alone pushes the clip five
    /// times too far up, which is the picture jumping when you press play.
    func testAnUnscaledOffsetLandsInTheWrongPlace() {
        let factor = 560.0 / max(screen.width, screen.height)
        let full = MediaFrameExtractor.placement(
            sourceSize: source, screenSize: screen, transform: transform
        )
        let wrong = MediaFrameExtractor.placement(
            sourceSize: source, screenSize: reduced(factor), transform: transform
        )
        XCTAssertGreaterThan(
            abs(full.minY / screen.height - wrong.minY / reduced(factor).height),
            0.2,
            "the bug this guards against would have to be reintroduced to fail here"
        )
    }
}
