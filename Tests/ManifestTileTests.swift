import XCTest

/// Tiles reach the widget only through the manifest, and a manifest that will
/// not decode is dropped rather than reported - the widget just draws nothing
/// and says the design is missing.
final class ManifestTileTests: XCTestCase {
    private func manifest(tiles: [PlacedTile]?) -> BuildManifest {
        BuildManifest(
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
            builtAt: Date(),
            backdropRect: nil,
            tiles: tiles
        )
    }

    private func roundTrip(_ manifest: BuildManifest) throws -> BuildManifest {
        let data = try JSONEncoder().encode(manifest)
        return try JSONDecoder().decode(BuildManifest.self, from: data)
    }

    func testTilesSurviveTheManifest() throws {
        let tile = PlacedTile(appID: "spotify", center: CGPoint(x: 300, y: 900), size: 180)
        let decoded = try roundTrip(manifest(tiles: [tile]))

        XCTAssertEqual(decoded.placedTiles.count, 1)
        XCTAssertEqual(decoded.placedTiles.first?.appID, "spotify")
        XCTAssertEqual(decoded.placedTiles.first?.center, CGPoint(x: 300, y: 900))
        XCTAssertEqual(decoded.placedTiles.first?.id, tile.id, "a tile's identity is what finds its baked icon")
    }

    /// A design built before tiles existed has no `tiles` key at all. Swift's
    /// synthesised decoding does not apply property defaults to missing keys,
    /// so this would throw if the field were not optional.
    func testAManifestWithoutTilesStillDecodes() throws {
        var json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(manifest(tiles: nil))
        ) as! [String: Any]
        json.removeValue(forKey: "tiles")
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(BuildManifest.self, from: data)
        XCTAssertTrue(decoded.placedTiles.isEmpty)
    }

    /// The widget looks a baked icon up by the tile that owns it, so the two
    /// have to agree on the name.
    func testIconResourceNameFollowsTheTile() {
        let id = UUID()
        XCTAssertEqual(
            PrebuiltDesign.iconResource(tileID: id),
            "prebuilt-icon-\(id.uuidString.lowercased())"
        )
    }

    func testLaunchLinkRoundTripsAnAppID() throws {
        let url = LaunchLink.url(for: "spotify")
        XCTAssertEqual(LaunchLink.appID(from: url), "spotify")
    }
}

/// A chosen background replaces the derived fill, and the wallpaper and the
/// widget backdrop are both composed from it - so getting this wrong changes
/// the picture behind the animation everywhere at once.
final class BackgroundCompositionTests: XCTestCase {

    /// A background is aspect-filled across the whole screen, which is what
    /// stops a wallpaper having bars down the side of it.
    func testBackgroundCoversTheWholeScreen() throws {
        let screen = DeviceGeometry.screenPixelSize
        let placement = MediaFrameExtractor.backdropPlacement(
            sourceSize: CGSize(width: 1024, height: 1024),
            screenSize: screen
        )
        XCTAssertLessThanOrEqual(placement.minX, 0)
        XCTAssertLessThanOrEqual(placement.minY, 0)
        XCTAssertGreaterThanOrEqual(placement.maxX, screen.width)
        XCTAssertGreaterThanOrEqual(placement.maxY, screen.height)
    }

    /// A wide background on a tall screen must still cover it, rather than
    /// fitting inside and leaving the ends bare.
    func testWideBackgroundStillCoversATallScreen() throws {
        let screen = DeviceGeometry.screenPixelSize
        let placement = MediaFrameExtractor.backdropPlacement(
            sourceSize: CGSize(width: 4000, height: 1000),
            screenSize: screen
        )
        XCTAssertGreaterThanOrEqual(placement.height, screen.height)
        XCTAssertGreaterThanOrEqual(placement.width, screen.width)
    }

    func testBackgroundNameSurvivesADesignRoundTrip() throws {
        var design = DesignDocument.new(name: "Test", sourceVideoName: "source.gif")
        design.backgroundName = "background.png"
        let data = try JSONEncoder().encode(design)
        let decoded = try JSONDecoder().decode(DesignDocument.self, from: data)
        XCTAssertEqual(decoded.backgroundName, "background.png")
    }

    /// A design written before backgrounds existed has no such key, and Swift
    /// does not apply property defaults to missing keys.
    func testADesignWithoutABackgroundStillDecodes() throws {
        let design = DesignDocument.new(name: "Test", sourceVideoName: "source.gif")
        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try JSONEncoder().encode(design)) as? [String: Any]
        )
        json.removeValue(forKey: "backgroundName")
        let decoded = try JSONDecoder().decode(
            DesignDocument.self,
            from: try JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertNil(decoded.backgroundName)
    }
}

/// With a background chosen, the clip is confined to the widget frame: outside
/// it the wallpaper has to be the chosen picture, not the clip running past the
/// only region that ever animates.
final class ClipConfinementTests: XCTestCase {
    private func fill(_ color: CGColor, size: CGSize) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(color)
        context.fill(CGRect(origin: .zero, size: size))
        return try XCTUnwrap(context.makeImage())
    }

    /// Composes by hand the way the extractor does, so the clipping rule can be
    /// checked without decoding a video.
    private func composed(clipTo frame: CGRect?) throws -> (inside: UInt8, outside: UInt8) {
        let screen = CGSize(width: 400, height: 800)
        let clip = try fill(CGColor(red: 1, green: 0, blue: 0, alpha: 1), size: CGSize(width: 400, height: 800))
        let background = try fill(CGColor(red: 0, green: 0, blue: 1, alpha: 1), size: screen)

        var pixels = [UInt8](repeating: 0, count: Int(screen.width * screen.height) * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels,
            width: Int(screen.width),
            height: Int(screen.height),
            bitsPerComponent: 8,
            bytesPerRow: Int(screen.width) * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(background, in: CGRect(origin: .zero, size: screen))
        if let frame {
            context.saveGState()
            context.clip(to: frame)
            context.draw(clip, in: CGRect(origin: .zero, size: screen))
            context.restoreGState()
        } else {
            context.draw(clip, in: CGRect(origin: .zero, size: screen))
        }
        _ = context.makeImage()

        func red(_ x: Int, _ y: Int) -> UInt8 {
            pixels[(y * Int(screen.width) + x) * 4]
        }
        return (red(200, 400), red(10, 10))
    }

    /// Compared by which picture is present rather than by an exact value:
    /// drawing through a colour space moves a channel by a few units, so the
    /// blue background reads as red=4 rather than red=0.
    private static let present: UInt8 = 200
    private static let absent: UInt8 = 32

    func testAConfinedClipLeavesTheBackgroundOutsideTheFrame() throws {
        let frame = CGRect(x: 100, y: 200, width: 200, height: 400)
        let result = try composed(clipTo: frame)
        XCTAssertGreaterThan(result.inside, Self.present, "the clip should still fill the widget frame")
        XCTAssertLessThan(result.outside, Self.absent, "the background should survive outside the frame")
    }

    func testWithoutConfinementTheClipCoversEverything() throws {
        let result = try composed(clipTo: nil)
        XCTAssertGreaterThan(result.inside, Self.present)
        XCTAssertGreaterThan(result.outside, Self.present, "unconfined, the clip covers the background")
    }
}

/// The widget's corners are rounded, so a square confinement leaves the clip
/// showing in the corners of the wallpaper where the background should be.
final class CornerRadiusTests: XCTestCase {
    func testTheCornerIsRoundedAwayFromTheClip() throws {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 400)
        let radius: CGFloat = 40
        let path = CGPath(
            roundedRect: bounds,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        // Just inside the corner of the bounding box, which a square clip would
        // have included and a rounded one must not.
        XCTAssertFalse(path.contains(CGPoint(x: 2, y: 2)))
        XCTAssertFalse(path.contains(CGPoint(x: bounds.maxX - 2, y: bounds.maxY - 2)))
        XCTAssertTrue(path.contains(CGPoint(x: bounds.midX, y: bounds.midY)))
        XCTAssertTrue(path.contains(CGPoint(x: bounds.midX, y: 2)), "the straight edge must still be included")
    }

    /// A radius past half the short side would invert the shape.
    func testRadiusIsCappedAtHalfTheShortSide() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 400)
        let capped = min(CGFloat(500), min(bounds.width, bounds.height) / 2)
        XCTAssertEqual(capped, 50)
    }

    func testTheDesignFallsBackToTheModelRadius() {
        var design = DesignDocument.new(name: "Test", sourceVideoName: "source.gif")
        XCTAssertEqual(design.effectiveCornerRadius, DeviceGeometry.model.widgetCornerRadius)
        design.widgetCornerRadius = 40
        XCTAssertEqual(design.effectiveCornerRadius, 40)
    }
}

/// Several designs can ship at once, and the phone switches between them, so
/// the selection has to survive a design being removed from a later build.
final class BundledSelectionTests: XCTestCase {
    private func entry(_ name: String) -> PrebuiltDesign.Entry {
        PrebuiltDesign.Entry(id: UUID(), name: name)
    }

    func testSelectionFallsBackToTheFirstWhenTheChoiceIsGone() {
        let entries = [entry("A"), entry("B")]
        let missing = UUID()
        let chosen = entries.first { $0.id == missing } ?? entries.first
        XCTAssertEqual(chosen?.name, "A", "a design that is no longer bundled must not leave a blank screen")
    }

    /// Filenames are per design, or two designs would overwrite each other's
    /// manifest in the bundle.
    func testResourceNamesAreUniquePerDesign() {
        let a = entry("A")
        let b = entry("B")
        XCTAssertNotEqual(a.manifestName, b.manifestName)
        XCTAssertTrue(a.manifestName.contains(a.id.uuidString.lowercased()))
    }

    /// A build made before several designs could ship names its files without
    /// an id, and must keep working rather than showing nothing.
    func testALegacyEntryUsesTheUnprefixedNames() {
        let legacy = PrebuiltDesign.Entry(id: UUID(), name: "Design", isLegacy: true)
        XCTAssertEqual(legacy.manifestName, "prebuilt-manifest")
    }

    func testStarringSurvivesADesignRoundTrip() throws {
        var design = DesignDocument.new(name: "Test", sourceVideoName: "source.gif")
        design.isStarred = true
        let decoded = try JSONDecoder().decode(
            DesignDocument.self,
            from: try JSONEncoder().encode(design)
        )
        XCTAssertTrue(decoded.isStarred)
    }

    /// A design written before starring existed has no such key.
    func testADesignWithoutStarringDecodesAsUnstarred() throws {
        let design = DesignDocument.new(name: "Test", sourceVideoName: "source.gif")
        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try JSONEncoder().encode(design)) as? [String: Any]
        )
        json.removeValue(forKey: "isStarred")
        let decoded = try JSONDecoder().decode(
            DesignDocument.self,
            from: try JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertFalse(decoded.isStarred)
    }
}
