import XCTest

/// The container a shared design travels in.
///
/// It used to be `/usr/bin/ditto`, which the phone has no way to run, so this is
/// what stands between a design somebody sent and a file the app cannot open.
/// The archives it reads come off other machines, so a malformed one has to be
/// named rather than half-unpacked.
final class ZipArchiveTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("motionary-zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func folder(_ name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ data: Data, to relative: String, in folder: URL) throws {
        let url = folder.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    /// Text deflates and random bytes do not, so one archive covers both the
    /// compressed and the stored path.
    private func sampleFolder() throws -> URL {
        let source = try folder("source")
        try write(Data(String(repeating: "a design, laid out\n", count: 400).utf8), to: "design.json", in: source)
        try write(Data((0 ..< 4096).map { UInt8($0 % 251) }.shuffled()), to: "source.mov", in: source)
        try write(Data("skin".utf8), to: "Skins/one.png", in: source)
        return source
    }

    func testAFolderSurvivesBeingPackedAndUnpacked() throws {
        let source = try sampleFolder()
        let archive = scratch.appendingPathComponent("out.motionary")
        try ZipArchive.write(directory: source, to: archive)

        let unpacked = try folder("unpacked")
        try ZipArchive.extract(archive, into: unpacked)

        for relative in ["design.json", "source.mov", "Skins/one.png"] {
            XCTAssertEqual(
                try Data(contentsOf: unpacked.appendingPathComponent(relative)),
                try Data(contentsOf: source.appendingPathComponent(relative)),
                "\(relative) did not come back byte for byte"
            )
        }
    }

    /// Both entry kinds have to be exercised, or a bug in one of the two paths
    /// hides behind the other one working.
    func testBothStoredAndDeflatedEntriesAreWritten() throws {
        let source = try sampleFolder()
        let archive = scratch.appendingPathComponent("methods.motionary")
        try ZipArchive.write(directory: source, to: archive)

        let bytes = try Data(contentsOf: archive)
        // Compression method sits at offset 8 of every local file header.
        var methods: Set<UInt16> = []
        for index in 0 ..< (bytes.count - 10) where bytes[index] == 0x50 && bytes[index + 1] == 0x4B
            && bytes[index + 2] == 0x03 && bytes[index + 3] == 0x04 {
            methods.insert(UInt16(bytes[index + 8]) | UInt16(bytes[index + 9]) << 8)
        }
        XCTAssertTrue(methods.contains(8), "nothing was deflated, so the compressed path is untested")
        XCTAssertTrue(methods.contains(0), "nothing was stored, so already-compressed media is being re-deflated")
    }

    /// An empty design folder is not something to package, but an archive with
    /// no entries in it must still parse rather than read as corrupt.
    func testAnEmptyFolderMakesAReadableArchive() throws {
        let source = try folder("empty")
        let archive = scratch.appendingPathComponent("empty.motionary")
        try ZipArchive.write(directory: source, to: archive)

        let unpacked = try folder("empty-out")
        try ZipArchive.extract(archive, into: unpacked)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: unpacked.path), [])
    }

    func testSomethingThatIsNotAZipIsNamedAsSuch() throws {
        let notAZip = scratch.appendingPathComponent("notes.motionary")
        try Data(String(repeating: "not a zip at all", count: 40).utf8).write(to: notAZip)

        XCTAssertThrowsError(try ZipArchive.extract(notAZip, into: try folder("nope"))) { error in
            guard case ZipArchiveError.notAZip(let path, _)? = error as? ZipArchiveError else {
                return XCTFail("expected notAZip, got \(error)")
            }
            XCTAssertEqual(path, "notes.motionary", "the message has to name the file that failed")
        }
    }

    /// A truncated send is the ordinary failure - a design half-transferred over
    /// Mail - and it has to stop rather than write a partial clip out.
    func testATruncatedArchiveIsRefused() throws {
        let source = try sampleFolder()
        let archive = scratch.appendingPathComponent("cut.motionary")
        try ZipArchive.write(directory: source, to: archive)

        let whole = try Data(contentsOf: archive)
        let cut = scratch.appendingPathComponent("cut-short.motionary")
        try whole.prefix(whole.count / 2).write(to: cut)

        XCTAssertThrowsError(try ZipArchive.extract(cut, into: try folder("cut-out")))
    }

    /// A zip may name `../../somewhere`, and a reader that simply appends the
    /// name writes it there. Built by hand because nothing here would emit one.
    func testAnEntryReachingOutsideTheDestinationIsRefused() throws {
        let archive = scratch.appendingPathComponent("escape.motionary")
        try Self.zip(entries: [("../escaped.json", Data("{}".utf8))]).write(to: archive)

        let destination = try folder("escape-out")
        XCTAssertThrowsError(try ZipArchive.extract(archive, into: destination)) { error in
            guard case ZipArchiveError.entryEscapesDestination(let entry)? = error as? ZipArchiveError else {
                return XCTFail("expected entryEscapesDestination, got \(error)")
            }
            XCTAssertEqual(entry, "../escaped.json")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: scratch.appendingPathComponent("escaped.json").path),
            "the entry was written outside the folder it was unpacked into"
        )
    }

    /// A design whose clip arrived corrupt must fail loudly: imported quietly it
    /// is a layout that builds to nothing, with no account of where it went.
    func testAPayloadThatDoesNotMatchItsChecksumIsRefused() throws {
        let archive = scratch.appendingPathComponent("bent.motionary")
        try Self.zip(entries: [("design.json", Data("{}".utf8))], corruptCRC: true).write(to: archive)

        XCTAssertThrowsError(try ZipArchive.extract(archive, into: try folder("bent-out"))) { error in
            guard case ZipArchiveError.checksumMismatch(let entry, _, _)? = error as? ZipArchiveError else {
                return XCTFail("expected checksumMismatch, got \(error)")
            }
            XCTAssertEqual(entry, "design.json")
        }
    }

    /// Finder's resource-fork sidecars ride along in anything `ditto` wrote, and
    /// unpacking them would leave a `__MACOSX` folder inside the design.
    func testFinderSidecarsAreLeftBehind() throws {
        let archive = scratch.appendingPathComponent("forked.motionary")
        try Self.zip(entries: [
            ("__MACOSX/._design.json", Data([0, 5, 22, 7])),
            ("design.json", Data("{}".utf8)),
        ]).write(to: archive)

        let unpacked = try folder("forked-out")
        try ZipArchive.extract(archive, into: unpacked)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: unpacked.path), ["design.json"])
    }

    // MARK: - Archives built by hand

    /// A stored-only zip assembled from the spec, so the reader is checked
    /// against the format rather than against this file's own writer.
    private static func zip(entries: [(String, Data)], corruptCRC: Bool = false) -> Data {
        var body = Data()
        var directory = Data()

        for (name, contents) in entries {
            let bytes = Data(name.utf8)
            let crc = corruptCRC ? CRC32.checksum(contents) &+ 1 : CRC32.checksum(contents)
            let offset = body.count

            body.append(little(0x0403_4b50, 4))
            body.append(little(20, 2))
            body.append(little(0, 2))
            body.append(little(0, 2))
            body.append(little(0, 2))
            body.append(little(0x0021, 2))
            body.append(little(UInt32(crc), 4))
            body.append(little(UInt32(contents.count), 4))
            body.append(little(UInt32(contents.count), 4))
            body.append(little(UInt32(bytes.count), 2))
            body.append(little(0, 2))
            body.append(bytes)
            body.append(contents)

            directory.append(little(0x0201_4b50, 4))
            directory.append(little(20, 2))
            directory.append(little(20, 2))
            directory.append(little(0, 2))
            directory.append(little(0, 2))
            directory.append(little(0, 2))
            directory.append(little(0x0021, 2))
            directory.append(little(UInt32(crc), 4))
            directory.append(little(UInt32(contents.count), 4))
            directory.append(little(UInt32(contents.count), 4))
            directory.append(little(UInt32(bytes.count), 2))
            directory.append(little(0, 2))
            directory.append(little(0, 2))
            directory.append(little(0, 2))
            directory.append(little(0, 2))
            directory.append(little(0, 4))
            directory.append(little(UInt32(offset), 4))
            directory.append(bytes)
        }

        var archive = body
        archive.append(directory)
        archive.append(little(0x0605_4b50, 4))
        archive.append(little(0, 2))
        archive.append(little(0, 2))
        archive.append(little(UInt32(entries.count), 2))
        archive.append(little(UInt32(entries.count), 2))
        archive.append(little(UInt32(directory.count), 4))
        archive.append(little(UInt32(body.count), 4))
        archive.append(little(0, 2))
        return archive
    }

    private static func little(_ value: UInt32, _ width: Int) -> Data {
        Data((0 ..< width).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
    }
}
