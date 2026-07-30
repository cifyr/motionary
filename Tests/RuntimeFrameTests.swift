import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest

/// The route that lets the phone build a design on its own: frames written into
/// the app group instead of fonts compiled into a bundle.
///
/// Covered end to end against a real animated GIF, because every step here has
/// broken in a way a stub would have hidden - a sheet too tall to draw, a crop
/// measured against a differently placed clip, a source sampled past its own end.
final class RuntimeFrameTests: XCTestCase {
    private var directory: URL!

    /// Only for the sampling tests, which never touch the widget rect. The
    /// build tests run at the calibrated device geometry on purpose: the crop is
    /// clamped to the real widget frame, so a made-up screen produces a crop
    /// that falls outside every composed frame and the build fails for a reason
    /// that has nothing to do with what is being tested.
    private let samplingScreen = CGSize(width: 120, height: 262)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("motionary-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    @discardableResult
    private func writeGIF(
        named name: String,
        frames: [CGColor],
        delay: Double = 0.25,
        size: CGSize = CGSize(width: 60, height: 130)
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

    /// Four frames a quarter of a second apart: a one-second loop, which the
    /// cycle fits by playing it twice.
    private func movingClip(named name: String = "moving.gif") throws -> URL {
        try writeGIF(named: name, frames: [
            CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            CGColor(red: 0, green: 1, blue: 0, alpha: 1),
            CGColor(red: 0, green: 0, blue: 1, alpha: 1),
            CGColor(red: 1, green: 1, blue: 0, alpha: 1),
        ])
    }

    private func store() throws -> DesignStore {
        try DesignStore(containerURL: directory.appendingPathComponent("group", isDirectory: true))
    }

    private func options(
        rate: Int = 2,
        layout: RuntimeFrameSequence.Layout = .separate
    ) -> RuntimeDesignImporter.Options {
        RuntimeDesignImporter.Options(framesPerSecond: rate, layout: layout, quality: 0.8)
    }

    // MARK: - Sheet limits

    /// The finding that settles sprite sheet versus separate files at full
    /// resolution: a strip of widget-sized frames runs past the largest picture
    /// that can be drawn after about ten of them, so a 64-frame full-resolution
    /// design has no sheet form at all.
    func testAFullResolutionSheetIsRefusedRatherThanDrawnBlank() {
        let widgetFrame = DeviceGeometry.model.widgetPixelSize
        XCTAssertFalse(
            RuntimeFrameSequence.sheetIsDrawable(frameCount: 64, frameSize: widgetFrame),
            "a 64-frame sheet of \(widgetFrame) frames should not be considered drawable"
        )
        let refusal = try? XCTUnwrap(
            RuntimeFrameSequence.sheetRefusal(frameCount: 64, frameSize: widgetFrame)
        )
        XCTAssertTrue(refusal?.contains("16384") == true, "the refusal should name the limit: \(refusal ?? "nil")")
    }

    func testASmallSheetIsAllowed() {
        XCTAssertTrue(
            RuntimeFrameSequence.sheetIsDrawable(
                frameCount: 64,
                frameSize: CGSize(width: 128, height: 195)
            )
        )
        XCTAssertNil(
            RuntimeFrameSequence.sheetRefusal(
                frameCount: 64,
                frameSize: CGSize(width: 128, height: 195)
            )
        )
    }

    func testASheetIsRefusedOnTotalPixelsEvenWhenBothSidesFit() {
        // 4000 by 7500 is inside the side limit in both directions and 30
        // megapixels - 120MB decoded, three times what the extension is allowed.
        XCTAssertFalse(
            RuntimeFrameSequence.sheetIsDrawable(
                frameCount: 50,
                frameSize: CGSize(width: 4_000, height: 150)
            )
        )
    }

    // MARK: - Sampling past the end of a short source

    /// Without wrapping, filling a two-second cycle from a one-second clip runs
    /// off the end of the source and the import fails a frame short. This is the
    /// property that makes the whole fit possible.
    func testSamplingWrapsBackToTheStartOfAShortSource() async throws {
        let url = try movingClip()
        let extractor = MediaFrameExtractor(url: url, screenSize: samplingScreen, sourceLoop: 1)
        var seen: [Int] = []
        try await extractor.forEachComposedFrame(
            startFrame: 0,
            count: 8,
            frameRate: 4,
            speed: 1
        ) { index, _ in seen.append(index) }
        XCTAssertEqual(seen, Array(0 ..< 8))
    }

    /// The streaming and array forms have to agree, or the phone's build and the
    /// Mac's would produce different pictures from one clip.
    func testStreamingAndArrayFormsProduceTheSameFrames() async throws {
        let url = try movingClip()
        let extractor = MediaFrameExtractor(url: url, screenSize: samplingScreen)
        let array = try await extractor.composedFrames(startFrame: 0, count: 4, frameRate: 4)

        var streamed: [CGImage] = []
        try await extractor.forEachComposedFrame(startFrame: 0, count: 4, frameRate: 4) { _, frame in
            streamed.append(frame)
        }

        XCTAssertEqual(streamed.count, array.count)
        for (index, pair) in zip(streamed, array).enumerated() {
            XCTAssertEqual(meanColour(pair.0), meanColour(pair.1), accuracy: 1, "frame \(index)")
        }
    }

    /// The streaming form must not swallow the handler's own errors. It used to:
    /// a failed write looked exactly like a clip that ended early, and surfaced
    /// as a frame count one short instead of the write error.
    func testAHandlerErrorSurfacesAsItself() async throws {
        struct Marker: Error {}
        let url = try movingClip()
        let extractor = MediaFrameExtractor(url: url, screenSize: samplingScreen)
        do {
            try await extractor.forEachComposedFrame(startFrame: 0, count: 4, frameRate: 4) { index, _ in
                if index == 2 { throw Marker() }
            }
            XCTFail("the handler's error was swallowed")
        } catch is Marker {
            // Expected.
        } catch {
            XCTFail("expected the handler's own error, got \(error)")
        }
    }

    // MARK: - Building

    func testBuildingWritesOneFilePerSlotAndAManifestThatMatches() async throws {
        let store = try store()
        let importer = RuntimeDesignImporter(store: store)
        let built = try await importer.run(
            sourceData: try Data(contentsOf: try movingClip()),
            name: "moving",
            options: options(rate: 3)
        )

        let sequence = try XCTUnwrap(built.manifest.frameSequence)
        XCTAssertEqual(built.manifest.resolvedAnimationSource, .runtimeImages)
        XCTAssertEqual(sequence.framesPerSecond, 3)
        XCTAssertEqual(sequence.frameCount, 6)
        XCTAssertEqual(store.frameFileCount(for: built.design.id), 6)
        for index in 0 ..< sequence.frameCount {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: store.frameURL(for: built.design.id, index: index).path),
                "frame \(index) is missing"
            )
        }
        XCTAssertGreaterThan(sequence.totalFrameBytes, 0)
        XCTAssertEqual(sequence.frameSize, sequence.rect.size)
    }

    /// The animation is composed of pictures that differ. A build that writes
    /// the same frame N times is indistinguishable from a working one on disk
    /// and a still picture on screen.
    func testTheWrittenFramesAreNotAllTheSamePicture() async throws {
        let store = try store()
        let built = try await RuntimeDesignImporter(store: store).run(
            sourceData: try Data(contentsOf: try movingClip()),
            name: "moving",
            options: options(rate: 4)
        )
        let sequence = try XCTUnwrap(built.manifest.frameSequence)

        var means: Set<Int> = []
        for index in 0 ..< sequence.frameCount {
            let image = try XCTUnwrap(ImageLoader.load(
                at: store.frameURL(for: built.design.id, index: index),
                maxPixelSize: 64
            ))
            means.insert(Int(meanColour(image) / 4))
        }
        XCTAssertGreaterThanOrEqual(means.count, 4, "the frames do not differ: \(means)")
    }

    /// The one-second clip is played twice inside the cycle. It happens to need
    /// no speed change - two whole seconds is two whole loops - and the point is
    /// that the build records the fit it used rather than assuming one, because
    /// the lengths this was built for do need a change.
    func testTheBuildRecordsTheFitItUsed() async throws {
        let store = try store()
        let built = try await RuntimeDesignImporter(store: store).run(
            sourceData: try Data(contentsOf: try movingClip()),
            name: "moving",
            options: options(rate: 2)
        )
        let sequence = try XCTUnwrap(built.manifest.frameSequence)
        XCTAssertEqual(sequence.sourceRepeats, 2)
        XCTAssertEqual(sequence.speed, 1, accuracy: 0.001)
        XCTAssertEqual(built.design.playbackSpeed, sequence.speed, accuracy: 0.001)
        XCTAssertEqual(sequence.loopDuration, 1, accuracy: 0.001)
    }

    func testTheStillsAreWrittenForTheWidgetToDrawBehindTheAnimation() async throws {
        let store = try store()
        let built = try await RuntimeDesignImporter(store: store).run(
            sourceData: try Data(contentsOf: try movingClip()),
            name: "moving",
            options: options(rate: 2)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.wallpaperURL(for: built.design.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.widgetBackdropURL(for: built.design.id).path))
        XCTAssertNotNil(built.manifest.backdropRect)
    }

    func testASheetBuildWritesOneFileHoldingEveryFrameInOrder() async throws {
        let store = try store()
        let built = try await RuntimeDesignImporter(store: store).run(
            sourceData: try Data(contentsOf: try movingClip()),
            name: "moving",
            options: options(rate: 2, layout: .sheet)
        )
        let sequence = try XCTUnwrap(built.manifest.frameSequence)
        XCTAssertEqual(sequence.layout, .sheet)

        let sheet = try XCTUnwrap(ImageLoader.load(
            at: store.frameSheetURL(for: built.design.id),
            maxPixelSize: RuntimeFrameSequence.maximumSheetSide
        ))
        XCTAssertEqual(sheet.width, Int(sequence.frameSize.width))
        XCTAssertEqual(sheet.height, Int(sequence.frameSize.height) * sequence.frameCount)

        // Slot 0 has to be the top strip, or every window shows the wrong frame
        // and the loop plays backwards through the sheet.
        let firstSeparate = try await separateFirstFrameMean(rate: 2)
        let top = try XCTUnwrap(sheet.cropping(to: CGRect(
            x: 0, y: 0, width: sequence.frameSize.width, height: sequence.frameSize.height
        )))
        XCTAssertEqual(meanColour(top), firstSeparate, accuracy: 12)
    }

    private func separateFirstFrameMean(rate: Int) async throws -> Double {
        let store = try store()
        let built = try await RuntimeDesignImporter(store: store).run(
            sourceData: try Data(contentsOf: try movingClip(named: "again.gif")),
            name: "again",
            options: options(rate: rate)
        )
        let image = try XCTUnwrap(ImageLoader.load(
            at: store.frameURL(for: built.design.id, index: 0),
            maxPixelSize: 256
        ))
        return meanColour(image)
    }

    /// A sheet the extension could not draw is refused at build time with the
    /// reason, rather than written and discovered as a blank widget.
    func testASheetTooLargeToDrawIsRefusedAtBuildTime() async throws {
        let store = try store()
        var design = DesignDocument.new(name: "big", sourceVideoName: "source.gif")
        design.animationSource = .runtimeImages
        design.runtimeLayout = .sheet
        design.runtimeFramesPerSecond = 32
        try store.createFolder(for: design.id)
        try Data(contentsOf: try movingClip(named: "big.gif"))
            .write(to: store.sourceVideoURL(for: design))

        // Full device geometry, which is where the limit actually bites.
        do {
            _ = try await RuntimeFrameBuilder(store: store).build(design: design)
            XCTFail("a 64-frame full-resolution sheet was accepted")
        } catch let error as RuntimeBuildError {
            XCTAssertTrue(
                error.description.contains("16384"),
                "the refusal should name the limit: \(error.description)"
            )
        }
    }

    /// A failed build must not leave a design in the library. It decodes fine
    /// and has no frames, so the widget picks it and draws a still - which is
    /// the exact failure this project keeps mistaking for a broken renderer.
    func testAFailedImportLeavesNothingBehind() async throws {
        let store = try store()
        let importer = RuntimeDesignImporter(store: store)
        // A single-frame GIF is a still image, which the extractor refuses.
        let still = try writeGIF(named: "still.gif", frames: [CGColor(red: 1, green: 0, blue: 0, alpha: 1)])
        do {
            _ = try await importer.run(
                sourceData: try Data(contentsOf: still),
                name: "still",
                options: options()
            )
            XCTFail("a still image was accepted as a design")
        } catch {
            XCTAssertTrue(store.loadAll().isEmpty, "a failed import left \(store.loadAll().count) designs")
        }
    }

    // MARK: - What the widget reads back

    func testTheWidgetFindsEveryFrameTheManifestPromised() async throws {
        let store = try store()
        let built = try await RuntimeDesignImporter(store: store).run(
            sourceData: try Data(contentsOf: try movingClip()),
            name: "moving",
            options: options(rate: 4)
        )
        let sequence = try XCTUnwrap(built.manifest.frameSequence)
        let loaded = RuntimeFrameLoader.load(
            sequence: sequence,
            designID: built.design.id,
            in: store
        )
        XCTAssertTrue(loaded.missing.isEmpty, "missing \(loaded.missing)")
        XCTAssertEqual(loaded.payload.loadedCount, sequence.frameCount)
        XCTAssertTrue(loaded.payload.isDrawable)
    }

    /// A gap in the folder is filled from a neighbour rather than left empty,
    /// and named either way.
    ///
    /// An empty slot draws nothing for its share of the cycle, so a folder caught
    /// mid-write - which the app archiving an old design while a render lands
    /// really does produce - strobed several times a second. A repeated frame is
    /// a stutter instead.
    func testAMissingFrameIsFilledFromANeighbourAndStillReported() async throws {
        let store = try store()
        let built = try await RuntimeDesignImporter(store: store).run(
            sourceData: try Data(contentsOf: try movingClip()),
            name: "moving",
            options: options(rate: 2)
        )
        let sequence = try XCTUnwrap(built.manifest.frameSequence)
        try FileManager.default.removeItem(at: store.frameURL(for: built.design.id, index: 1))

        let loaded = RuntimeFrameLoader.load(sequence: sequence, designID: built.design.id, in: store)
        XCTAssertEqual(loaded.missing, [1])
        XCTAssertTrue(loaded.note.contains("FILLED"), loaded.note)
        XCTAssertEqual(loaded.payload.foundCount, sequence.frameCount - 1)
        // Every slot still has a picture, so nothing strobes.
        XCTAssertEqual(loaded.payload.frames.count, sequence.frameCount)
        XCTAssertTrue(loaded.payload.isDrawable)
    }

    /// Enough of the folder gone and there is nothing to fill from, at which
    /// point the still picture is the honest answer rather than one frame held
    /// for two seconds.
    func testAnEmptyFrameFolderIsNotDrawnAsAnAnimation() async throws {
        let store = try store()
        let built = try await RuntimeDesignImporter(store: store).run(
            sourceData: try Data(contentsOf: try movingClip()),
            name: "moving",
            options: options(rate: 2)
        )
        let sequence = try XCTUnwrap(built.manifest.frameSequence)
        try FileManager.default.removeItem(at: store.framesFolder(for: built.design.id))

        let loaded = RuntimeFrameLoader.load(sequence: sequence, designID: built.design.id, in: store)
        XCTAssertFalse(loaded.payload.isDrawable)
        XCTAssertTrue(loaded.note.contains("NOT DRAWABLE"), loaded.note)
    }

    func testGapsAtEitherEndAreFilledFromTheOnlyDirectionAvailable() {
        // A hole at index 0 has nothing before it and has to look forward.
        let sequence = RuntimeFrameSequence(
            framesPerSecond: 2,
            layout: .separate,
            frameSize: CGSize(width: 4, height: 4),
            rect: CGRect(x: 0, y: 0, width: 4, height: 4),
            sourceRepeats: 1,
            speed: 1,
            totalFrameBytes: 0
        )
        let real = Image(systemName: "circle")
        XCTAssertEqual(RuntimeFrameLoader.filled([nil, real, nil, nil]).count, 4)
        XCTAssertEqual(RuntimeFrameLoader.filled([real, nil, nil, nil]).count, 4)
        XCTAssertEqual(RuntimeFrameLoader.filled([nil, nil, nil, nil]).count, 0)
        XCTAssertEqual(sequence.frameCount, 4)
    }

    func testTheStoreOnlyOffersRuntimeDesignsThatWereBuilt() async throws {
        let store = try store()
        let built = try await RuntimeDesignImporter(store: store).run(
            sourceData: try Data(contentsOf: try movingClip()),
            name: "moving",
            options: options(rate: 2)
        )
        // A design saved but never built has no manifest and must not appear.
        var unbuilt = DesignDocument.new(name: "unbuilt", sourceVideoName: "source.gif")
        unbuilt.animationSource = .runtimeImages
        try store.save(unbuilt)

        let offered = RuntimeDesignImporter.builtDesigns(in: store)
        XCTAssertEqual(offered.map(\.design.id), [built.design.id])
    }

    /// The importer selects what it built. An import that leaves the widget
    /// showing the previous design looks like an import that did nothing.
    func testTheImportSelectsWhatItBuilt() async throws {
        let store = try store()
        let built = try await RuntimeDesignImporter(store: store).run(
            sourceData: try Data(contentsOf: try movingClip()),
            name: "moving",
            options: options(rate: 2)
        )
        XCTAssertEqual(ActiveDesign.identifier, built.design.id)
    }

    // MARK: - The design and manifest carry the choice

    /// The route is a property of the design, not a global switch, so a library
    /// can hold both kinds and the widget picks per design.
    func testADesignRemembersWhichAnimationItIsFor() throws {
        var design = DesignDocument.new(name: "t", sourceVideoName: "source.gif")
        design.animationSource = .runtimeImages
        design.runtimeFramesPerSecond = 24
        design.runtimeLayout = .sheet

        let data = try JSONEncoder().encode(design)
        let restored = try JSONDecoder().decode(DesignDocument.self, from: data)
        XCTAssertEqual(restored.animationSource, .runtimeImages)
        XCTAssertEqual(restored.runtimeFramesPerSecond, 24)
        XCTAssertEqual(restored.runtimeLayout, .sheet)
        XCTAssertEqual(restored.runtimeFrameCount, 48)
    }

    /// Every design written before this route existed is a lane-font design, so
    /// the absent key is not a guess.
    func testADesignWrittenBeforeThisRouteIsALaneFontDesign() throws {
        let json = """
        {"name":"old","createdAt":0,"updatedAt":0,
         "sourceVideoName":"source.gif","animationCrop":[[0,0],[100,100]]}
        """
        let design = try JSONDecoder().decode(DesignDocument.self, from: Data(json.utf8))
        XCTAssertEqual(design.animationSource, .laneFonts)
    }

    func testAManifestWrittenBeforeThisRouteIsALaneFontManifest() throws {
        let json = """
        {"designID":"9D1A703F-DBD6-45E2-A0F1-93F752B1C9E9","buildGeneration":1,
         "fontFamilyBase":"MFontabcL","laneCount":64,"framesPerSecond":32,
         "loopFrameCount":40,"animationCrop":[[0,0],[100,100]],
         "widgetRect":[[0,0],[100,100]],"screenSize":[100,200],
         "wallpaperName":"wallpaper.png","totalFontBytes":10,"builtAt":0}
        """
        let manifest = try JSONDecoder().decode(BuildManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.resolvedAnimationSource, .laneFonts)
        XCTAssertNil(manifest.frameSequence)
    }

    // MARK: - Driving an import from the command line

    func testNoImportIsRequestedWhenNothingMentionsOne() {
        XCTAssertNil(RuntimeImportRequest.parse(["Motionary"]))
        XCTAssertNil(RuntimeImportRequest.parse(["Motionary", "-MotionaryImportFPS", "32"]))
    }

    func testTheWholeConfigurationTravelsInTheArguments() throws {
        let request = try XCTUnwrap(RuntimeImportRequest.parse([
            "-MotionaryImportPath", "/tmp/clip.gif",
            "-MotionaryImportFPS", "24",
            "-MotionaryImportLayout", "sheet",
            "-MotionaryImportQuality", "0.7",
            "-MotionaryImportReplace",
        ]))
        XCTAssertEqual(request.path, "/tmp/clip.gif")
        XCTAssertEqual(request.options.framesPerSecond, 24)
        XCTAssertEqual(request.options.layout, .sheet)
        XCTAssertEqual(request.options.quality, 0.7)
        XCTAssertTrue(request.replacesExisting)
        XCTAssertEqual(request.options.frameCount, 48)
    }

    /// A flag whose value is missing used to take the following flag as its
    /// value, which imported a file called "-MotionaryImportFPS".
    func testAFlagWithNoValueDoesNotEatTheNextFlag() {
        XCTAssertNil(RuntimeImportRequest.parse(["-MotionaryImportPath", "-MotionaryImportFPS", "24"]))
    }

    func testAnImpossibleFrameRateInTheArgumentsIsClamped() throws {
        let request = try XCTUnwrap(RuntimeImportRequest.parse([
            "-MotionaryImportPath", "/tmp/clip.gif",
            "-MotionaryImportFPS", "9000",
        ]))
        XCTAssertEqual(request.options.framesPerSecond, BlinkCycle.maximumFramesPerSecond)
    }

    func testABundledClipIsResolvedFromTheBundle() throws {
        let request = try XCTUnwrap(RuntimeImportRequest.parse([
            "-MotionaryImportBundled", "Wizard.gif",
        ]))
        let bundle = Bundle(for: type(of: self))
        XCTAssertEqual(
            request.resolveSource(in: bundle)?.lastPathComponent,
            "Wizard.gif",
            "Wizard.gif should be in the test bundle's resources"
        )
    }

    // MARK: - Plumbing

    private func meanColour(_ image: CGImage) -> Double {
        let columns = 8
        let rows = 8
        var buffer = [UInt8](repeating: 0, count: columns * rows)
        buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: columns, height: rows,
                bitsPerComponent: 8, bytesPerRow: columns,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        }
        return Double(buffer.reduce(0) { $0 + Int($1) }) / Double(buffer.count)
    }
}
