import XCTest

/// The catalogue is the only thing standing between a published design and an
/// install that cannot be updated. Mis-parse it and every scene disappears;
/// mis-read the access field and the app offers something it cannot use.
final class SceneCatalogTests: XCTestCase {
    /// Exactly what `Tools/publish-scene.sh` writes, so a change to either side
    /// that the other does not follow fails here rather than on a phone.
    private let published = """
    {
      "version": 1,
      "scenes": [
        {
          "id": "58737EDB-8407-4F09-B3CB-BFF8CB51125E",
          "name": "Video Games",
          "bytes": 41234567,
          "published": "2026-09-15",
          "package": "https://example.public.blob.vercel-storage.com/scenes/58737EDB.motionary",
          "preview": "https://example.public.blob.vercel-storage.com/previews/58737EDB.jpg",
          "motion": "https://example.public.blob.vercel-storage.com/motion/58737EDB.mp4",
          "access": "free"
        }
      ]
    }
    """

    private func decode(_ json: String) throws -> SceneCatalog.Document {
        try JSONDecoder().decode(SceneCatalog.Document.self, from: Data(json.utf8))
    }

    func testTheShapeThePublishScriptWritesDecodes() throws {
        let document = try decode(published)
        XCTAssertEqual(document.version, 1)
        XCTAssertEqual(document.scenes.count, 1)

        let scene = try XCTUnwrap(document.scenes.first)
        XCTAssertEqual(scene.id, "58737EDB-8407-4F09-B3CB-BFF8CB51125E")
        XCTAssertEqual(scene.name, "Video Games")
        XCTAssertEqual(scene.bytes, 41_234_567)
        XCTAssertEqual(scene.published, "2026-09-15")
        XCTAssertEqual(scene.package.lastPathComponent, "58737EDB.motionary")
        XCTAssertEqual(scene.preview.lastPathComponent, "58737EDB.jpg")
        XCTAssertEqual(scene.motion?.lastPathComponent, "58737EDB.mp4")
        XCTAssertTrue(scene.isFree)
    }

    /// The whole point of carrying `access` on every scene: a gate can be added
    /// later, and an install built before it has to refuse rather than try.
    func testAnUnrecognisedAccessIsNotOffered() throws {
        let gated = published.replacingOccurrences(of: "\"free\"", with: "\"paid\"")
        let scene = try XCTUnwrap(decode(gated).scenes.first)
        XCTAssertFalse(scene.isFree)
    }

    /// A scene missing a field is a broken catalogue, and the fetch turns that
    /// into an error the screen can show. Quietly dropping it would leave a
    /// person staring at a list that is short for no stated reason.
    func testAMissingFieldIsAnError() {
        let truncated = published.replacingOccurrences(of: "\"bytes\": 41234567,", with: "")
        XCTAssertThrowsError(try decode(truncated))
    }

    /// A scene published before moving previews existed has to keep listing,
    /// with its still, rather than making the whole catalogue unreadable.
    func testASceneWithoutAMotionPreviewStillLists() throws {
        let still = published.replacingOccurrences(
            of: "\"motion\": \"https://example.public.blob.vercel-storage.com/motion/58737EDB.mp4\",",
            with: ""
        )
        // The key, quoted: the package filename ends in ".motionary" and would
        // match a bare "motion".
        XCTAssertFalse(still.contains("\"motion\""), "fixture edit did not remove the motion field")
        let scene = try XCTUnwrap(decode(still).scenes.first)
        XCTAssertNil(scene.motion)
        XCTAssertEqual(scene.name, "Video Games")
    }

    func testAnEmptyCatalogueIsValid() throws {
        let document = try decode("{\"version\":1,\"scenes\":[]}")
        XCTAssertTrue(document.scenes.isEmpty)
    }

    func testSizeIsShownInUnitsAPersonReads() throws {
        let scene = try XCTUnwrap(decode(published).scenes.first)
        XCTAssertTrue(scene.sizeText.contains("MB"), "got \(scene.sizeText)")
    }
}
