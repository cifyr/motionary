import XCTest

/// The widget swaps font family and backdrop on the strength of this
/// resolution, so a wrong answer is a black animation layer - the failure this
/// project can least afford to reintroduce.
final class VariantChoiceTests: XCTestCase {
    private func manifest(variants: [BuildManifest.VariantBuild]) -> BuildManifest {
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
        return manifest
    }

    func testNoChoiceIsThePrimaryClip() {
        let built = BuildManifest.VariantBuild(
            id: UUID(), name: "Sunset", fontFamilyBase: "MFontabcvdefL", totalFontBytes: 2
        )
        XCTAssertNil(VariantChoice.resolved(in: manifest(variants: [built]), stored: String?.none))
    }

    func testAStoredChoiceFindsItsBuild() throws {
        let built = BuildManifest.VariantBuild(
            id: UUID(), name: "Sunset", fontFamilyBase: "MFontabcvdefL", totalFontBytes: 2
        )
        let resolved = try XCTUnwrap(
            VariantChoice.resolved(in: manifest(variants: [built]), stored: built.id)
        )
        XCTAssertEqual(resolved.fontFamilyBase, "MFontabcvdefL")
    }

    /// A rebuild can drop the chosen variant; the primary clip is the one
    /// guaranteed to have fonts in the bundle.
    func testAChoiceThisBuildDoesNotCarryFallsBackToThePrimary() {
        let built = BuildManifest.VariantBuild(
            id: UUID(), name: "Sunset", fontFamilyBase: "MFontabcvdefL", totalFontBytes: 2
        )
        XCTAssertNil(VariantChoice.resolved(in: manifest(variants: [built]), stored: UUID()))
    }

    func testAChoiceAgainstAVariantlessBuildIsThePrimary() {
        XCTAssertNil(VariantChoice.resolved(in: manifest(variants: []), stored: UUID()))
    }

    // MARK: - The clip a design leads with

    private func built(_ name: String) -> BuildManifest.VariantBuild {
        BuildManifest.VariantBuild(
            id: UUID(), name: name, fontFamilyBase: "MFontabcv\(name.lowercased())L", totalFontBytes: 2
        )
    }

    private func manifest(
        variants: [BuildManifest.VariantBuild],
        default id: UUID?,
        primaryNamed name: String? = nil
    ) -> BuildManifest {
        var subject = manifest(variants: variants)
        subject.defaultVariantID = id
        subject.primaryClipName = name
        return subject
    }

    /// A phone that has never chosen shows whatever the studio put the star
    /// on, which is the whole point of a default.
    func testAPhoneThatHasNotChosenTakesTheDesignsDefault() throws {
        let sunset = built("Sunset")
        let resolved = try XCTUnwrap(
            VariantChoice.resolved(
                in: manifest(variants: [sunset], default: sunset.id),
                stored: String?.none
            )
        )
        XCTAssertEqual(resolved.id, sunset.id)
    }

    /// And choosing the design's own clip has to stick. Storing "nothing
    /// chosen" for it would resolve straight back to the default, so the
    /// primary would be the one clip that cannot be picked.
    func testChoosingThePrimaryOverridesTheDefault() {
        let sunset = built("Sunset")
        XCTAssertNil(
            VariantChoice.resolved(
                in: manifest(variants: [sunset], default: sunset.id),
                stored: VariantChoice.primaryValue
            )
        )
    }

    func testAChosenClipWinsOverTheDefault() throws {
        let sunset = built("Sunset")
        let storm = built("Storm")
        let resolved = try XCTUnwrap(
            VariantChoice.resolved(
                in: manifest(variants: [sunset, storm], default: sunset.id),
                stored: storm.id.uuidString
            )
        )
        XCTAssertEqual(resolved.id, storm.id)
    }

    /// A rebuild can drop the chosen clip. Landing on what the design now
    /// leads with beats landing on whatever happens to be first.
    func testAChoiceThisBuildDroppedFallsBackToTheDefault() throws {
        let sunset = built("Sunset")
        let resolved = try XCTUnwrap(
            VariantChoice.resolved(
                in: manifest(variants: [sunset], default: sunset.id),
                stored: UUID().uuidString
            )
        )
        XCTAssertEqual(resolved.id, sunset.id)
    }

    /// A default naming a clip whose fonts are not in the bundle is a black
    /// widget, so a stale one must resolve to the primary rather than to it.
    func testADefaultThisBuildDoesNotCarryIsIgnored() {
        XCTAssertNil(
            VariantChoice.resolved(
                in: manifest(variants: [built("Sunset")], default: UUID()),
                stored: String?.none
            )
        )
    }

    // MARK: - What a clip is called

    func testAnUnnamedPrimaryIsStandard() {
        XCTAssertEqual(manifest(variants: []).primaryClipTitle, "Standard")
    }

    func testANamedPrimaryKeepsItsName() {
        let subject = manifest(variants: [], default: nil, primaryNamed: "Rainy day")
        XCTAssertEqual(subject.primaryClipTitle, "Rainy day")
        XCTAssertEqual(VariantChoice.title(of: nil, in: subject), "Rainy day")
    }

    func testAVariantIsCalledWhatItWasNamed() {
        let sunset = built("Sunset")
        XCTAssertEqual(VariantChoice.title(of: sunset, in: manifest(variants: [sunset])), "Sunset")
    }
}
