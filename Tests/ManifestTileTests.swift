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
