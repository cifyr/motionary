import XCTest

/// A design as one file, sent between machines.
///
/// The round trip used to be checkable only by running the studio, because the
/// packing shelled out to `ditto`. It is Swift on both sides now, so what a
/// phone will do with a file somebody sends it can be asserted here.
final class DesignArchiveTests: XCTestCase {
    private var scratch: URL!
    private var store: DesignStore!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("motionary-archive-\(UUID().uuidString)", isDirectory: true)
        store = try DesignStore(containerURL: scratch.appendingPathComponent("here", isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func elsewhere() throws -> DesignStore {
        try DesignStore(containerURL: scratch.appendingPathComponent("there-\(UUID().uuidString)", isDirectory: true))
    }

    private func archiveURL(_ name: String = "design.motionary") -> URL {
        scratch.appendingPathComponent(name)
    }

    /// A design with everything an archive is meant to carry: a clip, a
    /// background, a skinned tile and a variant.
    @discardableResult
    private func makeDesign(named name: String = "Board") throws -> DesignDocument {
        var design = DesignDocument.new(name: name, sourceVideoName: "clip.mov")
        design.backgroundName = "back.png"
        design.tiles = [
            PlacedTile(appID: "com.apple.mobilemail", center: CGPoint(x: 100, y: 100), size: 120, skin: "mail.png"),
            PlacedTile(appID: "com.apple.Music", center: CGPoint(x: 300, y: 100), size: 120),
        ]
        design.variants = [ClipVariant(name: "Night", sourceVideoName: "night.mov")]

        try store.createFolder(for: design.id)
        try Data("a clip".utf8).write(to: store.sourceVideoURL(for: design))
        try Data("a night clip".utf8).write(to: store.variantClipURL(for: design.id, name: "night.mov"))
        try Data("a background".utf8).write(to: store.backgroundURL(for: design.id, name: "back.png"))

        let skins = store.skinsFolder(for: design.id)
        try FileManager.default.createDirectory(at: skins, withIntermediateDirectories: true)
        try Data("mail artwork".utf8).write(to: skins.appendingPathComponent("mail.png"))
        try Data("unused artwork".utf8).write(to: skins.appendingPathComponent("spare.png"))

        try store.save(design)
        return design
    }

    /// Packs a folder built by hand, for the shapes an export never produces.
    private func archive(building: (URL) throws -> Void) throws -> URL {
        let stage = scratch.appendingPathComponent("stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try building(stage)
        let archive = archiveURL("hand-\(UUID().uuidString).motionary")
        try ZipArchive.write(directory: stage, to: archive)
        return archive
    }

    // MARK: - Round trip

    func testADesignArrivesWithItsClipBackgroundAndSkin() throws {
        let design = try makeDesign()
        let archive = archiveURL()
        try DesignArchive.export(design, store: store, to: archive)

        let destination = try elsewhere()
        let restored = try DesignArchive.restore(from: archive, into: destination)

        XCTAssertEqual(restored.id, design.id, "a design sent to a fresh phone should keep its identity")
        XCTAssertEqual(restored.name, "Board")
        XCTAssertEqual(restored.tiles.count, 2)
        XCTAssertEqual(
            try Data(contentsOf: destination.sourceVideoURL(for: restored)),
            Data("a clip".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.backgroundURL(for: restored.id, name: "back.png")),
            Data("a background".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.skinsFolder(for: restored.id).appendingPathComponent("mail.png")),
            Data("mail artwork".utf8),
            "the tile's artwork did not travel, so it would import as a layout with its icons missing"
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.variantClipURL(for: restored.id, name: "night.mov")),
            Data("a night clip".utf8)
        )
        XCTAssertEqual(restored.variants.map(\.name), ["Night"])
    }

    /// The design is what the store lists, so it has to be saved rather than
    /// only unpacked - an import nobody can find afterwards is not one.
    func testTheImportedDesignIsInTheStore() throws {
        let design = try makeDesign()
        let archive = archiveURL()
        try DesignArchive.export(design, store: store, to: archive)

        let destination = try elsewhere()
        _ = try DesignArchive.restore(from: archive, into: destination)
        XCTAssertEqual(destination.loadAll().map(\.name), ["Board"])
    }

    /// Only the artwork the tiles ask for. A design's library accumulates
    /// everything ever imported for it, and sending all of it makes the file
    /// several times the size of the design.
    func testOnlyTheSkinsTheTilesUseTravel() throws {
        let design = try makeDesign()
        let archive = archiveURL()
        try DesignArchive.export(design, store: store, to: archive)

        let destination = try elsewhere()
        let restored = try DesignArchive.restore(from: archive, into: destination)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: destination.skinsFolder(for: restored.id).path),
            ["mail.png"]
        )
    }

    /// Importing a file must never be how somebody loses the version they had.
    func testADesignAlreadyHereIsBroughtInAsACopy() throws {
        let design = try makeDesign()
        let archive = archiveURL()
        try DesignArchive.export(design, store: store, to: archive)

        let restored = try DesignArchive.restore(from: archive, into: store)
        XCTAssertNotEqual(restored.id, design.id)
        XCTAssertEqual(restored.name, "Board copy")
        XCTAssertEqual(try store.load(id: design.id).name, "Board", "the design already here was written over")
        XCTAssertEqual(
            try Data(contentsOf: store.sourceVideoURL(for: restored)),
            Data("a clip".utf8),
            "the copy has no clip of its own, so it cannot be built"
        )
    }

    /// A variant is a row that has to build. One whose clip stayed behind can
    /// only be an entry that fails later, with nothing to say why.
    func testAVariantWhoseClipDidNotTravelIsDropped() throws {
        var design = try makeDesign()
        design.variants.append(ClipVariant(name: "Dawn", sourceVideoName: "dawn.mov"))
        try store.save(design)

        let archive = archiveURL()
        try DesignArchive.export(design, store: store, to: archive)

        let destination = try elsewhere()
        let restored = try DesignArchive.restore(from: archive, into: destination)
        XCTAssertEqual(restored.variants.map(\.name), ["Night"])
    }

    /// Same reasoning for the background: a design pointing at a picture that is
    /// not there draws nothing and blames nothing.
    func testABackgroundThatDidNotTravelFallsBack() throws {
        let design = try makeDesign()
        try FileManager.default.removeItem(at: store.backgroundURL(for: design.id, name: "back.png"))

        let archive = archiveURL()
        try DesignArchive.export(design, store: store, to: archive)

        let destination = try elsewhere()
        let restored = try DesignArchive.restore(from: archive, into: destination)
        XCTAssertNil(restored.backgroundName)
    }

    // MARK: - What arrives malformed

    func testAZipWithNoDesignInsideIsNamed() throws {
        let archive = try archive { stage in
            try Data("holiday".utf8).write(to: stage.appendingPathComponent("photo.jpg"))
        }
        XCTAssertThrowsError(try DesignArchive.restore(from: archive, into: store)) { error in
            guard case DesignArchiveError.noDesignInside(let path)? = error as? DesignArchiveError else {
                return XCTFail("expected noDesignInside, got \(error)")
            }
            XCTAssertEqual(path, archive.lastPathComponent, "the message has to name the file somebody sent")
        }
    }

    /// Some archivers wrap the contents in a folder and some do not, and the
    /// phone has no say in which one made the file it was handed.
    func testADesignNestedInAFolderIsStillFound() throws {
        let design = try makeDesign()
        let archive = try archive { stage in
            let nested = stage.appendingPathComponent("Board", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            try encoder.encode(design).write(to: nested.appendingPathComponent("design.json"))
            try Data("a clip".utf8).write(to: nested.appendingPathComponent("clip.mov"))
        }

        let destination = try elsewhere()
        let restored = try DesignArchive.restore(from: archive, into: destination)
        XCTAssertEqual(restored.id, design.id)
        XCTAssertEqual(
            try Data(contentsOf: destination.sourceVideoURL(for: restored)),
            Data("a clip".utf8)
        )
    }

    /// A file from a newer Motionary is refused by name rather than imported as
    /// whatever this version happens to understand of it.
    func testAPackageFromANewerMotionaryIsRefused() throws {
        let design = try makeDesign()
        let archive = try archive { stage in
            try JSONEncoder().encode(design).write(to: stage.appendingPathComponent("design.json"))
            let package: [String: Any] = [
                "version": DesignArchive.formatVersion + 1,
                "designID": design.id.uuidString,
                "skins": [],
            ]
            try JSONSerialization.data(withJSONObject: package)
                .write(to: stage.appendingPathComponent("package.json"))
        }
        XCTAssertThrowsError(try DesignArchive.restore(from: archive, into: try elsewhere())) { error in
            guard case DesignArchiveError.unsupportedVersion(let version)? = error as? DesignArchiveError else {
                return XCTFail("expected unsupportedVersion, got \(error)")
            }
            XCTAssertEqual(version, DesignArchive.formatVersion + 1)
        }
    }

    // MARK: - What the phone says about it

    func testTheImporterNamesTheDesignItTookIn() throws {
        let design = try makeDesign(named: "Kitchen")
        let archive = archiveURL()
        try DesignArchive.export(design, store: store, to: archive)

        let outcome = DesignImporter.take(archive, into: try elsewhere())
        XCTAssertEqual(outcome, DesignImportOutcome.imported(name: "Kitchen"))
        XCTAssertTrue(outcome.message.contains("Kitchen"))
        XCTAssertTrue(
            outcome.message.contains("built"),
            "the phone cannot draw a design it was sent, and saying nothing about that reads as a broken import"
        )
    }

    /// The one account anybody gets of why nothing appeared, so it has to name
    /// the file and carry the underlying reason rather than say it went wrong.
    func testTheImporterNamesTheFileItCouldNotRead() throws {
        let notADesign = scratch.appendingPathComponent("holiday.motionary")
        try Data("holiday".utf8).write(to: notADesign)

        let outcome = DesignImporter.take(notADesign, into: store)
        guard case .failed(let reason) = outcome else {
            return XCTFail("a file that is not a design imported anyway: \(outcome)")
        }
        XCTAssertTrue(reason.contains("holiday.motionary"), "\(reason) does not name the file")
        XCTAssertTrue(reason.contains("zip"), "\(reason) does not say what was actually wrong with it")
    }
}
