import XCTest

/// "Ships with Studio" and "goes on the phone" used to be the same bit, and the
/// library drew both from it: starring your own design filed it under Starters
/// and made it undeletable, while unstarring a real starter made it disposable.
/// These hold the two apart.
final class StarterFlagTests: XCTestCase {
    private func design(name: String = "clip") -> DesignDocument {
        DesignDocument.new(name: name, sourceVideoName: "clip.mov")
    }

    func testADesignIsNeitherStarterNorStarredToBeginWith() {
        let made = design()
        XCTAssertFalse(made.isStarter)
        XCTAssertFalse(made.isStarred)
    }

    func testStarringDoesNotMakeADesignAStarter() {
        var made = design()
        made.isStarred = true
        XCTAssertFalse(made.isStarter)
    }

    func testAStarterCanBeLeftOutOfTheBuild() {
        var made = design()
        made.isStarter = true
        XCTAssertFalse(made.isStarred)
        XCTAssertTrue(made.isStarter)
    }

    func testTheFlagSurvivesCoding() throws {
        var made = design()
        made.isStarter = true
        made.isStarred = true
        let decoded = try JSONDecoder().decode(
            DesignDocument.self,
            from: try JSONEncoder().encode(made)
        )
        XCTAssertTrue(decoded.isStarter)
        XCTAssertTrue(decoded.isStarred)
    }

    /// Every design written before the flag existed decodes as not-a-starter
    /// rather than failing to decode at all.
    func testADesignSavedBeforeTheFlagStillOpens() throws {
        var made = design()
        made.isStarter = true
        var fields = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(made)) as? [String: Any]
        )
        fields.removeValue(forKey: "isStarter")

        let decoded = try JSONDecoder().decode(
            DesignDocument.self,
            from: try JSONSerialization.data(withJSONObject: fields)
        )
        XCTAssertFalse(decoded.isStarter)
        XCTAssertEqual(decoded.name, made.name)
    }
}
