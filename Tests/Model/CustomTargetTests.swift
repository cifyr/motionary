import XCTest

/// A tile can open an app the catalogue never heard of. The widget hands the
/// tap to the app either way, so what changes is only what travels in the link.
final class CustomTargetTests: XCTestCase {
    private func tile(custom: CustomTarget?) -> PlacedTile {
        PlacedTile(
            appID: "spotify",
            center: CGPoint(x: 100, y: 100),
            size: 100,
            custom: custom
        )
    }

    /// People type "bear", not "bear://", and `open` refuses a bare word.
    func testABareSchemeBecomesAURL() {
        let target = CustomTarget(name: "Bear", scheme: "bear")
        XCTAssertEqual(target.launchCandidates.first?.absoluteString, "bear://")
    }

    func testAWrittenSchemeIsLeftAlone() {
        XCTAssertEqual(
            CustomTarget(name: "Things", scheme: "things:").launchCandidates.first?.absoluteString,
            "things:"
        )
        XCTAssertEqual(
            CustomTarget(name: "Site", scheme: "https://example.com").launchCandidates.first?.absoluteString,
            "https://example.com"
        )
    }

    func testTheWebFallbackComesSecond() {
        let target = CustomTarget(name: "Bear", scheme: "bear", webFallback: "https://bear.app")
        XCTAssertEqual(target.launchCandidates.count, 2)
        XCTAssertEqual(target.launchCandidates.last?.absoluteString, "https://bear.app")
    }

    func testAnEmptySchemeCannotLaunch() {
        XCTAssertTrue(CustomTarget(name: "Nothing", scheme: "  ").launchCandidates.isEmpty)
        XCTAssertFalse(tile(custom: CustomTarget(name: "Nothing", scheme: "")).canLaunch)
    }

    /// The custom name wins, because there is no catalogue entry to ask and a
    /// tile with no name at all is worse than a wrong one.
    func testTheCustomNameIsWhatTheTileIsCalled() {
        XCTAssertEqual(tile(custom: CustomTarget(name: "Bear", scheme: "bear")).displayName, "Bear")
        XCTAssertEqual(tile(custom: nil).displayName, "Spotify")
    }

    // MARK: - The link

    func testACatalogueTileTravelsAsItsID() throws {
        let url = LaunchLink.url(for: tile(custom: nil))
        XCTAssertEqual(LaunchLink.target(from: url), .app("spotify"))
        // The old accessor still answers, so anything reading it keeps working.
        XCTAssertEqual(LaunchLink.appID(from: url), "spotify")
    }

    func testACustomTileTravelsAsItsURL() throws {
        let url = LaunchLink.url(for: tile(custom: CustomTarget(name: "Bear", scheme: "bear")))
        let target = try XCTUnwrap(LaunchLink.target(from: url))
        XCTAssertEqual(target, .url(try XCTUnwrap(URL(string: "bear://"))))
        XCTAssertNil(LaunchLink.appID(from: url), "a custom target names no catalogue app")
    }

    /// A custom target with nothing usable in it falls back to the id, so a
    /// tap still reaches something nameable rather than nothing at all.
    func testAnEmptyCustomTargetFallsBackToTheAppID() {
        let url = LaunchLink.url(for: tile(custom: CustomTarget(name: "Bear", scheme: "")))
        XCTAssertEqual(LaunchLink.target(from: url), .app("spotify"))
    }

    func testAnUnrelatedURLIsNotATarget() throws {
        XCTAssertNil(LaunchLink.target(from: try XCTUnwrap(URL(string: "https://example.com/launch/spotify"))))
    }

    // MARK: - Storage

    func testACustomTargetSurvivesATileRoundTrip() throws {
        let original = tile(custom: CustomTarget(name: "Bear", scheme: "bear", webFallback: "https://bear.app"))
        let decoded = try JSONDecoder().decode(PlacedTile.self, from: try JSONEncoder().encode(original))
        XCTAssertEqual(decoded.custom, original.custom)
    }

    /// A tile written before custom targets existed has no such key, and Swift
    /// does not apply property defaults to missing keys.
    func testATileWithoutACustomTargetStillDecodes() throws {
        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try JSONEncoder().encode(tile(custom: nil))) as? [String: Any]
        )
        json.removeValue(forKey: "custom")
        let decoded = try JSONDecoder().decode(
            PlacedTile.self,
            from: try JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertNil(decoded.custom)
        XCTAssertEqual(decoded.appID, "spotify")
    }
}
