import CoreGraphics
import CoreText
import XCTest

/// These cover the part of Motionary that has no safety net: if a generated
/// font is malformed, the widget silently renders nothing.
final class FontGenerationTests: XCTestCase {
    private var templateData: Data!

    override func setUpWithError() throws {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: FontSetGenerator.templateResourceName, withExtension: "ttf"),
            "shaping template missing from the test bundle"
        )
        templateData = try Data(contentsOf: url)
    }

    private func makeBuilder(
        smoothness: MotionSmoothness = .standard,
        crop: CGRect = CGRect(x: 312, y: 470, width: 583, height: 1470)
    ) throws -> LaneFontBuilder {
        try LaneFontBuilder(
            templateData: templateData,
            spec: TimerFontSpec(smoothness: smoothness),
            factory: SVGGlyphFactory(cropRect: crop, screenSize: DeviceGeometry.screenPixelSize)
        )
    }

    private func fakeFrames(_ count: Int) -> [String] {
        (0 ..< count).map { Data("frame-\($0)".utf8).base64EncodedString() }
    }

    // MARK: - sfnt container

    func testTemplateRoundTripsUnchangedTables() throws {
        let file = try SFNTFile(data: templateData)
        let reserialized = try file.serialized()
        let reparsed = try SFNTFile(data: reserialized)

        XCTAssertEqual(Set(file.tags), Set(reparsed.tags))
        for tag in file.tags {
            // `head` legitimately differs: serialising rewrites the whole-file
            // checkSumAdjustment, so compare it with that field masked out.
            let original = tag == "head" ? zeroingCheckSumAdjustment(try file.table(tag)) : try file.table(tag)
            let result = tag == "head" ? zeroingCheckSumAdjustment(try reparsed.table(tag)) : try reparsed.table(tag)
            XCTAssertEqual(original, result, "table '\(tag)' changed across a round trip")
        }
    }

    private func zeroingCheckSumAdjustment(_ head: Data) -> Data {
        var copy = head
        copy.replaceSubrange((copy.startIndex + 8) ..< (copy.startIndex + 12), with: [0, 0, 0, 0])
        return copy
    }

    func testChecksumAdjustmentMatchesTheSpec() throws {
        let generated = try makeBuilder().font(lane: 0, familyBase: "TestLane", encodedFrames: fakeFrames(4))
        let file = try SFNTFile(data: generated)
        let head = try file.table("head")
        let stored = head.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self).bigEndian
        }

        // Recompute independently: zero the field, sum the whole file, subtract.
        var zeroed = generated
        let headOffset = try XCTUnwrap(offsetOfTable("head", in: generated))
        zeroed.replaceSubrange((headOffset + 8) ..< (headOffset + 12), with: [0, 0, 0, 0])
        let expected = 0xB1B0_AFBA &- SFNTFile.checksum(zeroed)

        XCTAssertEqual(stored, expected)
    }

    /// Reads the table directory the way a font loader would, so the test does
    /// not depend on the parser it is checking.
    private func offsetOfTable(_ tag: String, in data: Data) -> Int? {
        let numTables = Int(data[4]) << 8 | Int(data[5])
        for index in 0 ..< numTables {
            let record = 12 + index * 16
            let recordTag = String(decoding: data[record ..< (record + 4)], as: UTF8.self)
            guard recordTag == tag else { continue }
            return (0 ..< 4).reduce(0) { $0 << 8 | Int(data[record + 8 + $1]) }
        }
        return nil
    }

    // MARK: - Lane semantics

    func testEveryLaneGetsAUniquePostScriptName() throws {
        let builder = try makeBuilder(smoothness: .light)
        let frames = fakeFrames(8)
        var names = Set<String>()

        for lane in 0 ..< TimerFontSpec(smoothness: .light).laneCount {
            let data = try builder.font(lane: lane, familyBase: "UniqueLane", encodedFrames: frames)
            let file = try SFNTFile(data: data)
            let name = try XCTUnwrap(NameTable.value(forNameID: 6, in: try file.table("name")))
            XCTAssertEqual(name, LaneFontBuilder.postScriptName(family: "UniqueLane", lane: lane))
            names.insert(name)
        }
        XCTAssertEqual(names.count, 32, "lane fonts must not share a PostScript name")
    }

    func testGlyphsCarryTheFrameTheLaneMathPredicts() throws {
        let spec = TimerFontSpec(smoothness: .standard)
        let builder = try makeBuilder()
        let frameCount = 8
        let frames = fakeFrames(frameCount)

        for lane in [0, 1, 31, 63] {
            let data = try builder.font(lane: lane, familyBase: "FrameLane", encodedFrames: frames)
            let table = try SFNTFile(data: data).table("SVG ")

            for sequence in 0 ..< spec.framesPerLane {
                let document = String(decoding: try SVGTable.document(at: sequence, in: table), as: UTF8.self)
                let global = spec.globalFrame(lane: lane, glyphSequence: sequence)
                let expected = frames[global % frameCount]
                XCTAssertTrue(
                    document.contains("base64,\(expected)"),
                    "lane \(lane) glyph \(sequence) should hold frame \(global % frameCount)"
                )
            }
        }
    }

    /// A template whose animation glyph count does not match the spec would
    /// produce a font that shapes to the wrong frames, so it must be refused
    /// rather than written.
    func testTemplateWithTheWrongGlyphCountIsRejected() throws {
        var mutated = try SFNTFile(data: templateData)
        let truncated = SVGTable.build(documents: try (0 ..< 3).map { index in
            SVGGlyphDocument(
                glyphID: UInt16(14 + index),
                compressed: try Gzip.compress(Data("<svg/>".utf8))
            )
        })
        mutated.setTable("SVG ", to: truncated)
        let mutatedData = try mutated.serialized()

        XCTAssertEqual(try SVGTable.glyphIDs(in: try SFNTFile(data: mutatedData).table("SVG ")).count, 3)
        XCTAssertThrowsError(
            try LaneFontBuilder(
                templateData: mutatedData,
                spec: TimerFontSpec(smoothness: .standard),
                factory: SVGGlyphFactory(cropRect: .zero, screenSize: DeviceGeometry.screenPixelSize)
            )
        ) { error in
            guard case LaneFontError.glyphCountMismatch(let found, let expected) = error else {
                return XCTFail("expected a glyph count mismatch, got \(error)")
            }
            XCTAssertEqual(found, 3)
            XCTAssertEqual(expected, 15)
        }
    }

    // MARK: - CoreText acceptance

    /// The decisive check: CoreText must accept the bytes and resolve the name.
    func testCoreTextRegistersAndResolvesAGeneratedFont() throws {
        let data = try makeBuilder(smoothness: .light).font(
            lane: 3,
            familyBase: "CTLane",
            encodedFrames: fakeFrames(4)
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CTLane3-Regular-\(UUID().uuidString).ttf")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        var error: Unmanaged<CFError>?
        XCTAssertTrue(
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error),
            "CoreText rejected a generated font: \(String(describing: error?.takeRetainedValue()))"
        )

        let font = CTFontCreateWithName("CTLane3-Regular" as CFString, 24, nil)
        XCTAssertEqual(CTFontCopyPostScriptName(font) as String, "CTLane3-Regular")

        // The animation glyphs must survive as real glyphs, not .notdef.
        XCTAssertGreaterThan(CTFontGetGlyphCount(font), 28)
        CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
    }

    // MARK: - Gzip

    func testGzipRoundTripsPayloadsLargerThanOneBuffer() throws {
        let payload = Data((0 ..< 300_000).map { UInt8($0 % 251) })
        XCTAssertEqual(try Gzip.decompress(try Gzip.compress(payload)), payload)
    }

    func testGzipRoundTripsEmptyData() throws {
        XCTAssertTrue(try Gzip.decompress(try Gzip.compress(Data())).isEmpty)
    }

    func testGzipRejectsNonGzipInput() {
        XCTAssertThrowsError(try Gzip.decompress(Data(repeating: 0x41, count: 64)))
    }

    func testCRC32MatchesKnownVector() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
    }
}
