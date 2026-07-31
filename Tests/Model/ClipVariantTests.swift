import XCTest

/// Variants ride the same rails as everything else that reaches the phone: the
/// design document into the studio, the manifest into the widget. A shape that
/// will not decode silently removes the design from the library, so decoding
/// tolerance is the first thing covered.
final class ClipVariantTests: XCTestCase {
    func testVariantsSurviveADesignRoundTrip() throws {
        var design = DesignDocument.new(name: "Test", sourceVideoName: "source.mp4")
        design.variants = [ClipVariant(name: "Sunset", sourceVideoName: "sunset.mp4")]
        let decoded = try JSONDecoder().decode(
            DesignDocument.self,
            from: try JSONEncoder().encode(design)
        )
        XCTAssertEqual(decoded.variants.count, 1)
        XCTAssertEqual(decoded.variants.first?.name, "Sunset")
        XCTAssertEqual(decoded.variants.first?.sourceVideoName, "sunset.mp4")
    }

    /// A design written before variants existed has no such key, and Swift does
    /// not apply property defaults to missing keys.
    func testADesignWithoutVariantsStillDecodes() throws {
        let design = DesignDocument.new(name: "Test", sourceVideoName: "source.mp4")
        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try JSONEncoder().encode(design)) as? [String: Any]
        )
        json.removeValue(forKey: "variants")
        let decoded = try JSONDecoder().decode(
            DesignDocument.self,
            from: try JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertTrue(decoded.variants.isEmpty)
    }

    /// Every variant's lane fonts live in one bundle beside the design's own
    /// and every other design's, so the families can never collide.
    func testVariantFontFamiliesAreDistinct() {
        let design = DesignDocument.new(name: "Test", sourceVideoName: "source.mp4")
        let first = ClipVariant(name: "A", sourceVideoName: "a.mp4")
        let second = ClipVariant(name: "B", sourceVideoName: "b.mp4")

        let families = [
            design.fontFamilyBase,
            design.fontFamilyBase(for: first),
            design.fontFamilyBase(for: second),
        ]
        XCTAssertEqual(Set(families).count, families.count)

        let other = DesignDocument.new(name: "Other", sourceVideoName: "source.mp4")
        XCTAssertNotEqual(design.fontFamilyBase(for: first), other.fontFamilyBase(for: first))
    }

    /// The lane number is parsed back out of the filename by looking for
    /// `L<digits>-`, so a variant family must keep that tail unambiguous.
    func testAVariantFamilyEndsInASingleLaneMarker() {
        let design = DesignDocument.new(name: "Test", sourceVideoName: "source.mp4")
        let family = design.fontFamilyBase(for: ClipVariant(name: "A", sourceVideoName: "a.mp4"))
        let name = LaneFontBuilder.postScriptName(family: family, lane: 7)

        let matches = name.ranges(of: /L\d+-/)
        XCTAssertEqual(matches.count, 1, "\(name) would parse the wrong lane back")
        XCTAssertTrue(name.hasSuffix("L7-Regular"))
    }

    func testManifestVariantsRoundTrip() throws {
        var manifest = BuildManifest(
            designID: UUID(),
            buildGeneration: 1,
            fontFamilyBase: "MFontabcL",
            laneCount: 32,
            framesPerSecond: 16,
            loopFrameCount: 20,
            animationCrop: CGRect(x: 66, y: 475, width: 1074, height: 1086),
            widgetRect: DeviceGeometry.widgetRect,
            screenSize: DeviceGeometry.screenPixelSize,
            wallpaperName: "wallpaper.png",
            totalFontBytes: 1,
            builtAt: Date()
        )
        manifest.clipVariants = [
            .init(id: UUID(), name: "Sunset", fontFamilyBase: "MFontabcvdefL", totalFontBytes: 2),
        ]

        let decoded = try JSONDecoder().decode(
            BuildManifest.self,
            from: try JSONEncoder().encode(manifest)
        )
        XCTAssertEqual(decoded.builtVariants.count, 1)
        XCTAssertEqual(decoded.builtVariants.first?.name, "Sunset")
        XCTAssertEqual(decoded.builtVariants.first?.fontFamilyBase, "MFontabcvdefL")
    }

    /// Variant lengths need not match: each loop is sized to its own clip,
    /// never past its natural length - video sampling does not wrap, so an
    /// overshoot would end the decode early and fail the build.
    func testVariantLoopFitsItsOwnClip() {
        let spec = TimerFontSpec(smoothness: .light)  // 16fps, cycle divides by 480

        // A 6.9s clip caps at the 96-frame ceiling.
        XCTAssertEqual(FontSetGenerator.variantLoopLength(duration: 6.9, spec: spec, playbackSpeed: 1), 96)
        // A 0.5s clip loops all 8 of its frames.
        XCTAssertEqual(FontSetGenerator.variantLoopLength(duration: 0.5, spec: spec, playbackSpeed: 1), 8)
        // 7 natural frames: 7 does not divide the cycle, and rounding UP to 8
        // would outrun the clip - so 6, the nearest length that fits.
        XCTAssertEqual(FontSetGenerator.variantLoopLength(duration: 0.4375, spec: spec, playbackSpeed: 1), 6)
        // Speed halves the source the loop can cover.
        XCTAssertEqual(FontSetGenerator.variantLoopLength(duration: 0.5, spec: spec, playbackSpeed: 2), 4)
        // Degenerate duration still yields a drawable loop.
        XCTAssertEqual(FontSetGenerator.variantLoopLength(duration: 0, spec: spec, playbackSpeed: 1), 1)
    }

    /// A manifest carrying no per-variant loop - written before lengths could
    /// differ - falls back to the design's own.
    func testAVariantWithoutItsOwnLoopStillDecodes() throws {
        var manifest = BuildManifest(
            designID: UUID(),
            buildGeneration: 1,
            fontFamilyBase: "MFontabcL",
            laneCount: 32,
            framesPerSecond: 16,
            loopFrameCount: 20,
            animationCrop: .zero,
            widgetRect: DeviceGeometry.widgetRect,
            screenSize: DeviceGeometry.screenPixelSize,
            wallpaperName: "wallpaper.png",
            totalFontBytes: 1,
            builtAt: Date()
        )
        manifest.clipVariants = [
            .init(id: UUID(), name: "Sunset", fontFamilyBase: "MFontabcvdefL", totalFontBytes: 2),
        ]
        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try JSONEncoder().encode(manifest)) as? [String: Any]
        )
        var variants = try XCTUnwrap(json["clipVariants"] as? [[String: Any]])
        variants[0].removeValue(forKey: "loopFrameCount")
        json["clipVariants"] = variants

        let decoded = try JSONDecoder().decode(
            BuildManifest.self,
            from: try JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertNil(decoded.builtVariants.first?.loopFrameCount)
    }

    /// A manifest written before variants existed has no such key.
    func testAManifestWithoutVariantsStillDecodes() throws {
        let manifest = BuildManifest(
            designID: UUID(),
            buildGeneration: 1,
            fontFamilyBase: "MFontabcL",
            laneCount: 32,
            framesPerSecond: 16,
            loopFrameCount: 20,
            animationCrop: .zero,
            widgetRect: DeviceGeometry.widgetRect,
            screenSize: DeviceGeometry.screenPixelSize,
            wallpaperName: "wallpaper.png",
            totalFontBytes: 1,
            builtAt: Date()
        )
        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try JSONEncoder().encode(manifest)) as? [String: Any]
        )
        json.removeValue(forKey: "clipVariants")
        let decoded = try JSONDecoder().decode(
            BuildManifest.self,
            from: try JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertTrue(decoded.builtVariants.isEmpty)
    }
}
