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
        XCTAssertNil(VariantChoice.resolved(in: manifest(variants: [built]), stored: nil))
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
}
