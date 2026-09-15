import XCTest

/// The whole download path against the real published catalogue: fetch, pick a
/// scene, stream the package, unpack it into a store. Unit tests prove the
/// catalogue parses; only this proves a published package installs.
///
/// Off by default because it needs the network and downloads megabytes. Run it
/// after publishing with:
///   TEST_RUNNER_MOTIONARY_LIVE_CATALOG=1 xcodebuild test ... \
///     -only-testing:MotionaryTests/SceneCatalogLiveTests
final class SceneCatalogLiveTests: XCTestCase {
    private var container: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MOTIONARY_LIVE_CATALOG"] == "1",
            "live catalogue test is opt-in; set TEST_RUNNER_MOTIONARY_LIVE_CATALOG=1"
        )
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("motionary-live-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let container { try? FileManager.default.removeItem(at: container) }
    }

    func testAPublishedSceneDownloadsAndUnpacks() async throws {
        let scenes = try await SceneCatalog.fetch()
        XCTAssertFalse(scenes.isEmpty, "the live catalogue lists nothing")

        // The smallest free scene, so the test downloads megabytes rather than
        // the largest package that happens to be published.
        let scene = try XCTUnwrap(scenes.filter(\.isFree).min { $0.bytes < $1.bytes })

        let file = try await SceneCatalog.download(scene) { _ in }
        defer { try? FileManager.default.removeItem(at: file) }

        let data = try Data(contentsOf: file)
        XCTAssertEqual(data.count, scene.bytes, "downloaded size differs from what the catalogue claims")

        let store = try DesignStore(containerURL: container)
        let design = try DesignPackage.read(data, into: store)
        XCTAssertEqual(design.id.uuidString, scene.id)
        XCTAssertEqual(design.name, scene.name)
        XCTAssertGreaterThan(store.frameCount(for: design.id), 0, "\(scene.name) unpacked with no frames")
    }
}
