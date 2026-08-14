import XCTest

/// The editor autosaves over the document in place, so history is the only way
/// back once a window has been closed. These cover what decides a snapshot is
/// worth keeping, what survives pruning, and what a restore has to leave behind
/// when the files a version pointed at are gone.
final class DesignVersionsTests: XCTestCase {
    private var container: URL!
    private var store: DesignStore!
    private var versions: DesignVersions!

    override func setUpWithError() throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("motionary-tests-\(UUID().uuidString)", isDirectory: true)
        store = try DesignStore(containerURL: container)
        versions = DesignVersions(store: store, spacing: 300, limit: 5)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: container)
    }

    private func design(named name: String = "Board") -> DesignDocument {
        DesignDocument.new(name: name, sourceVideoName: "source.mov")
    }

    private func version(
        _ document: DesignDocument,
        _ reason: DesignVersion.Reason = .edited,
        at takenAt: Date
    ) -> DesignVersion {
        DesignVersion(takenAt: takenAt, reason: reason, document: document)
    }

    // MARK: - What is worth keeping

    func testTheFirstSnapshotIsAlwaysKept() {
        XCTAssertTrue(DesignVersions.shouldRecord(
            design(), reason: .edited, latest: nil, now: Date(), spacing: 300
        ))
    }

    func testAnUnchangedDesignIsNotKeptAgain() {
        var document = design()
        let latest = version(document, at: Date(timeIntervalSince1970: 0))
        // What the autosave does on every write, and the only difference
        // between two documents that say exactly the same thing.
        document.updatedAt = Date()

        XCTAssertFalse(DesignVersions.shouldRecord(
            document,
            reason: .closed,
            latest: latest,
            now: Date(timeIntervalSince1970: 10_000),
            spacing: 300
        ), "restamping is not a change")
    }

    func testEditingSnapshotsAreSpacedOut() {
        var document = design()
        let start = Date(timeIntervalSince1970: 0)
        let latest = version(document, at: start)
        document.name = "Board, moved"

        XCTAssertFalse(DesignVersions.shouldRecord(
            document, reason: .edited, latest: latest, now: start.addingTimeInterval(60), spacing: 300
        ), "a drag pauses every second; a history of that is not a history")

        XCTAssertTrue(DesignVersions.shouldRecord(
            document, reason: .edited, latest: latest, now: start.addingTimeInterval(300), spacing: 300
        ))
    }

    func testTheNamedMomentsIgnoreTheSpacing() {
        var document = design()
        let start = Date(timeIntervalSince1970: 0)
        let latest = version(document, at: start)
        document.name = "Board, moved"

        for reason: DesignVersion.Reason in [.opened, .built, .closed, .restored] {
            XCTAssertTrue(DesignVersions.shouldRecord(
                document, reason: reason, latest: latest, now: start.addingTimeInterval(1), spacing: 300
            ), "\(reason.rawValue) is a boundary, not a sample")
        }
    }

    // MARK: - Pruning

    func testAShortHistoryIsLeftAlone() {
        let start = Date(timeIntervalSince1970: 0)
        let history = (0 ..< 3).map { version(design(), at: start.addingTimeInterval(Double($0))) }
        XCTAssertEqual(DesignVersions.kept(history, limit: 5).count, 3)
    }

    func testPruningKeepsTheNewestAndTheOldest() {
        let start = Date(timeIntervalSince1970: 0)
        let history = (0 ..< 10).map { version(design(), at: start.addingTimeInterval(Double($0))) }
        let kept = DesignVersions.kept(history, limit: 5)

        XCTAssertEqual(kept.count, 5)
        XCTAssertEqual(
            kept.map { $0.takenAt.timeIntervalSince1970 },
            [9, 8, 7, 6, 0],
            "the four newest, plus the design before this whole stretch of work"
        )
    }

    // MARK: - Restoring over deleted files

    func testAVersionKeepsWhatIsStillOnDisk() {
        var document = design()
        document.assets = [PlacedAsset(fileName: "logo.png", center: .zero, size: CGSize(width: 10, height: 10))]
        document.variants = [ClipVariant(name: "Second", sourceVideoName: "second.mov")]

        let result = DesignVersions.reconciled(document, assetExists: { _ in true }, clipExists: { _ in true })

        XCTAssertTrue(result.isClean)
        XCTAssertNil(result.note)
        XCTAssertEqual(result.document.assets.count, 1)
        XCTAssertEqual(result.document.variants.count, 1)
    }

    func testAVersionDropsPicturesDeletedSince() {
        var document = design()
        document.assets = [
            PlacedAsset(fileName: "gone.png", center: .zero, size: CGSize(width: 10, height: 10)),
            PlacedAsset(fileName: "kept.png", center: .zero, size: CGSize(width: 10, height: 10))
        ]

        let result = DesignVersions.reconciled(
            document,
            assetExists: { $0 == "kept.png" },
            clipExists: { _ in true }
        )

        XCTAssertEqual(result.droppedAssets, ["gone.png"])
        XCTAssertEqual(result.document.assets.map(\.fileName), ["kept.png"])
        XCTAssertEqual(
            result.note,
            "1 picture in that version has been deleted since, so it is not back."
        )
    }

    func testADroppedClipStopsLeadingTheDesign() {
        var document = design()
        let gone = ClipVariant(name: "Gone", sourceVideoName: "gone.mov")
        document.variants = [gone, ClipVariant(name: "Kept", sourceVideoName: "kept.mov")]
        document.defaultVariantID = gone.id

        let result = DesignVersions.reconciled(
            document,
            assetExists: { _ in true },
            clipExists: { $0 == "kept.mov" }
        )

        XCTAssertEqual(result.droppedClips, ["Gone"])
        XCTAssertEqual(result.document.variants.map(\.name), ["Kept"])
        XCTAssertNil(result.document.defaultVariantID, "a design cannot open on a clip it no longer has")
    }

    // MARK: - On disk

    func testHistorySurvivesAndReadsNewestFirst() throws {
        var document = design()
        try store.save(document)

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertNotNil(try versions.record(document, reason: .opened, now: start))
        document.name = "Board, later"
        XCTAssertNotNil(try versions.record(document, reason: .closed, now: start.addingTimeInterval(60)))

        let history = versions.list(for: document.id)
        XCTAssertEqual(history.map(\.reason), [.closed, .opened])
        XCTAssertEqual(history.last?.document.name, "Board")
    }

    func testGoingBackIsItselfReversible() throws {
        var document = design()
        try store.save(document)
        let opened = try XCTUnwrap(try versions.record(document, reason: .opened))

        document.name = "Board, ruined"
        try store.save(document)

        let result = try versions.restore(opened, over: document)
        XCTAssertEqual(result.document.name, "Board")
        XCTAssertEqual(try store.load(id: document.id).name, "Board")
        XCTAssertTrue(
            versions.list(for: document.id).contains { $0.reason == .restored },
            "the ruined state is kept, so the restore can be undone"
        )
    }

    func testPruningRunsAsVersionsAreWritten() throws {
        var document = design()
        try store.save(document)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        for step in 0 ..< 10 {
            document.name = "Board \(step)"
            // A named reason each time, so the spacing does not decide this.
            try versions.record(document, reason: .closed, now: start.addingTimeInterval(Double(step) * 60))
        }

        let history = versions.list(for: document.id)
        XCTAssertEqual(history.count, 5, "limit is 5 in these tests")
        XCTAssertEqual(history.first?.document.name, "Board 9")
        XCTAssertEqual(history.last?.document.name, "Board 0")
    }
}
