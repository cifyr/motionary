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

/// The order a phone steps through the clips: alphabetical so a dozen can be
/// found in, rotated to start on the one the scene leads with so the first
/// swipe moves away from what is on screen rather than jumping to it.
final class ClipSequenceTests: XCTestCase {
    private func built(_ name: String) -> BuildManifest.VariantBuild {
        BuildManifest.VariantBuild(
            id: UUID(), name: name, fontFamilyBase: "MFont\(name)L", totalFontBytes: 1
        )
    }

    private func manifest(
        _ variants: [BuildManifest.VariantBuild],
        primary: String? = nil,
        default id: UUID? = nil
    ) -> BuildManifest {
        var subject = BuildManifest(
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
        subject.clipVariants = variants.isEmpty ? nil : variants
        subject.primaryClipName = primary
        subject.defaultVariantID = id
        return subject
    }

    func testASceneWithOneClipIsJustThatClip() {
        XCTAssertEqual(manifest([]).clipSequence.map(\.name), ["Standard"])
    }

    /// The design's own clip sorts among the rest rather than always leading:
    /// it is one of the choices, not a category of its own. Named so it sorts
    /// first here, which is the one case where sorted and rotated agree.
    func testTheClipsAreAlphabeticalWithTheScenesOwnAmongThem() {
        let subject = manifest(
            [built("Zebra"), built("Mario"), built("Pacman")],
            primary: "Atari"
        )
        XCTAssertEqual(subject.clipSequence.map(\.name), ["Atari", "Mario", "Pacman", "Zebra"])
    }

    /// And with the scene leading elsewhere the same four wrap around it.
    func testTheAlphabetWrapsAroundTheClipItLeadsWith() {
        let subject = manifest(
            [built("Zebra"), built("Atari"), built("Pacman")],
            primary: "Mario"
        )
        XCTAssertEqual(subject.clipSequence.map(\.name), ["Mario", "Pacman", "Zebra", "Atari"])
    }

    /// Sorted alone, the first swipe would jump to whatever sorts first
    /// instead of moving on from what is showing.
    func testTheSequenceStartsOnTheClipTheSceneLeadsWith() {
        let pacman = built("Pacman")
        let subject = manifest(
            [built("Zebra"), built("Atari"), pacman], primary: "Mario", default: pacman.id
        )
        XCTAssertEqual(subject.clipSequence.map(\.name), ["Pacman", "Zebra", "Atari", "Mario"])
    }

    func testLeadingWithTheScenesOwnClipStartsThere() {
        let subject = manifest([built("Zebra"), built("Atari")], primary: "Mario")
        XCTAssertEqual(subject.clipSequence.map(\.name), ["Mario", "Zebra", "Atari"])
    }

    /// A name with a number in it sorts the way a person reads it.
    func testNumbersSortNaturally() {
        let subject = manifest(
            [built("Clip 10"), built("Clip 2")], primary: "Clip 1"
        )
        XCTAssertEqual(subject.clipSequence.map(\.name), ["Clip 1", "Clip 2", "Clip 10"])
    }

    /// The build guards against it, but a manifest naming a clip it does not
    /// carry must still produce a usable list rather than an empty one.
    func testADefaultThisBuildDoesNotCarryStillLists() {
        let subject = manifest([built("Atari")], primary: "Mario", default: UUID())
        XCTAssertEqual(subject.clipSequence.map(\.name), ["Atari", "Mario"])
    }

    /// Every entry has to be addressable, since the id is what gets stored.
    func testTheScenesOwnClipCarriesNoVariantID() throws {
        let subject = manifest([built("Atari")], primary: "Mario")
        let own = try XCTUnwrap(subject.clipSequence.first { $0.name == "Mario" })
        XCTAssertNil(own.variantID)
        XCTAssertNotNil(try XCTUnwrap(subject.clipSequence.first { $0.name == "Atari" }).variantID)
    }
}
