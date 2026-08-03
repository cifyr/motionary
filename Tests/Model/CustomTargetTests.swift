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

/// A slot's swap list has to exclude the app the slot already shows: it is not
/// an alternative to itself, and it resolves to the same baked icon filename,
/// which stopped a build partway through writing the Resources folder.
final class OfferedAlternatesTests: XCTestCase {
    private func tile(appID: String, alternates: [TileAlternate]) -> PlacedTile {
        PlacedTile(appID: appID, center: .zero, size: 100, alternates: alternates)
    }

    func testTheTilesOwnAppIsNotOffered() {
        let subject = tile(appID: "spotify", alternates: [
            .init(appID: "spotify", skin: "a.png"),
            .init(appID: "mail", skin: "b.png"),
        ])
        XCTAssertEqual(subject.offeredAlternates.map(\.appID), ["mail"])
    }

    /// Which is what happens after changing a tile's app to one already in its
    /// list, rather than something anyone sets up deliberately.
    func testTheSameAppIsNotOfferedTwice() {
        let subject = tile(appID: "calendar", alternates: [
            .init(appID: "mail", skin: "a.png"),
            .init(appID: "mail", skin: "b.png"),
        ])
        XCTAssertEqual(subject.offeredAlternates.count, 1)
    }

    func testAnHonestListIsUntouched() {
        let subject = tile(appID: "calendar", alternates: [
            .init(appID: "mail"), .init(appID: "spotify"),
        ])
        XCTAssertEqual(subject.offeredAlternates.map(\.appID), ["mail", "spotify"])
    }

    /// The icon filenames a build writes have to be distinct, which is the
    /// thing the collision actually broke.
    func testEveryOfferedAlternateHasItsOwnIconName() {
        let subject = tile(appID: "spotify", alternates: [
            .init(appID: "spotify"), .init(appID: "mail"), .init(appID: "maps"),
        ])
        var names = [PrebuiltDesign.iconResource(tileID: subject.id)]
        names += subject.offeredAlternates.map {
            PrebuiltDesign.iconResource(tileID: subject.id, appID: $0.appID, authoredAppID: subject.appID)
        }
        XCTAssertEqual(Set(names).count, names.count, "two icons would be written to one filename")
    }
}

/// Running a Shortcut is the last route before the web address: it is the only
/// one that can reach an app publishing no working scheme at all, which is the
/// gap a list of schemes cannot close however long the list gets.
final class ShortcutTargetTests: XCTestCase {
    func testTheShortcutComesAfterTheSchemeAndBeforeTheWeb() {
        let target = CustomTarget(
            name: "Bear",
            scheme: "bear://",
            webFallback: "https://bear.app/",
            shortcutName: "Open Bear"
        )
        XCTAssertEqual(
            target.launchCandidates.map(\.absoluteString),
            ["bear://", "shortcuts://run-shortcut?name=Open%20Bear", "https://bear.app/"]
        )
    }

    /// A Shortcut's title is whatever somebody called it. Pasted into a URL
    /// raw, the space ends the URL and Shortcuts opens its own list instead of
    /// running anything.
    func testASpacedNameSurvivesAsAQuery() {
        let url = CustomTarget.shortcutURL(named: "Log a coffee")
        XCTAssertEqual(url?.absoluteString, "shortcuts://run-shortcut?name=Log%20a%20coffee")
    }

    func testPunctuationInTheNameSurvives() {
        let url = CustomTarget.shortcutURL(named: "Coffee & Notes")
        XCTAssertEqual(
            URLComponents(url: url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "name" })?.value,
            "Coffee & Notes"
        )
    }

    func testAnEmptyNameIsNoRoute() {
        XCTAssertNil(CustomTarget.shortcutURL(named: "   "))
        let target = CustomTarget(name: "Bear", scheme: "bear://", shortcutName: "  ")
        XCTAssertEqual(target.launchCandidates.map(\.absoluteString), ["bear://"])
    }

    /// Absent from an older document rather than empty, which is the case that
    /// silently rewrites every design if it decodes wrong.
    func testADocumentWithoutTheKeyStillDecodes() throws {
        let json = #"{"name":"Bear","scheme":"bear://"}"#
        let target = try JSONDecoder().decode(CustomTarget.self, from: Data(json.utf8))
        XCTAssertNil(target.shortcutName)
        XCTAssertEqual(target.launchCandidates.map(\.absoluteString), ["bear://"])
    }
}
