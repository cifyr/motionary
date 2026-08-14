import XCTest

/// Stepping the clip on every launch.
///
/// The order has to be the one the options sheet lists and a sideways swipe
/// walks, because all three set the same stored value - if rotating used a
/// different order, opening the app and then swiping would jump rather than
/// carry on.
final class ClipRotationTests: XCTestCase {
    private func variant(_ name: String) -> BuildManifest.VariantBuild {
        BuildManifest.VariantBuild(
            id: UUID(), name: name, fontFamilyBase: "MFont\(name)L", totalFontBytes: 1
        )
    }

    private func manifest(
        variants: [BuildManifest.VariantBuild],
        program: [ClipProgram.Segment]? = nil
    ) -> BuildManifest {
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
        manifest.clipVariants = variants.isEmpty ? nil : variants
        manifest.clipProgram = program
        return manifest
    }

    /// One step forward through the same list the sheet shows, and round the
    /// end rather than stopping on the last clip.
    func testItStepsThroughTheClipsAndWraps() throws {
        let a = variant("Clip A"), b = variant("Clip B")
        let built = manifest(variants: [a, b])
        let order = built.clipSequence
        XCTAssertEqual(order.count, 3, "the design's own clip counts as one")

        var seen: [String] = []
        var current = order[0].variantID
        for _ in order.indices {
            let next = try XCTUnwrap(ClipRotation.next(after: current, in: built))
            seen.append(next.name)
            current = next.variantID
        }
        XCTAssertEqual(seen, Array(order.dropFirst().map(\.name)) + [order[0].name])
        XCTAssertEqual(current, order[0].variantID, "a full cycle comes back to where it started")
    }

    /// A design with nothing to switch to must not be moved: writing a choice
    /// for it would reload the widget on every launch for no visible reason.
    func testADesignWithOneClipDoesNotMove() {
        XCTAssertNil(ClipRotation.next(after: nil, in: manifest(variants: [])))
    }

    /// A shuffled design's clips are already inside one stack and are not
    /// selectable, so there is no next one to step to.
    func testAShuffledDesignDoesNotMove() {
        let built = manifest(
            variants: [variant("Clip A")],
            program: [ClipProgram.Segment(clipID: nil, startFrame: 0, frameCount: 20)]
        )
        XCTAssertTrue(built.hasShuffledClipProgram)
        XCTAssertNil(ClipRotation.next(after: nil, in: built))
    }

    /// A stored clip this build no longer carries starts the walk from the
    /// front rather than refusing to move.
    func testAnUnknownClipStartsFromTheBeginning() throws {
        let built = manifest(variants: [variant("Clip A")])
        let next = try XCTUnwrap(ClipRotation.next(after: UUID(), in: built))
        XCTAssertEqual(next.name, built.clipSequence[1].name)
    }

    /// Off by default, so a phone that never asked for this keeps the clip it
    /// was left on.
    func testItDoesNothingUnlessItIsTurnedOn() {
        let built = manifest(variants: [variant("Clip A")])
        let wasEnabled = ClipRotation.isEnabled
        defer { ClipRotation.isEnabled = wasEnabled }

        ClipRotation.isEnabled = false
        XCTAssertNil(ClipRotation.advance(built))

        ClipRotation.isEnabled = true
        XCTAssertNotNil(ClipRotation.advance(built), "and it does move once asked")
    }
}
