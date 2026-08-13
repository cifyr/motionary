import Foundation
import os

enum DesignPackageError: Error, CustomStringConvertible {
    case notAPackage(path: String)
    case unsupportedVersion(Int)
    case truncated(expected: Int, got: Int)
    case entryMissing(name: String)
    case notFrameDriven(designID: UUID)

    var description: String {
        switch self {
        case .notAPackage(let path):
            "package: \(path) does not start with the Motionary marker"
        case .unsupportedVersion(let version):
            "package: version \(version) was written by a newer build than this one"
        case .truncated(let expected, let got):
            "package: needs \(expected) bytes of payload and the file has \(got)"
        case .entryMissing(let name):
            "package: the header lists \(name) but the payload does not contain it"
        case .notFrameDriven(let id):
            "package: design \(id.uuidString) was built as fonts, which cannot be delivered - build it as frames first"
        }
    }
}

/// One design, as a single file that can be carried to a phone.
///
/// A design built as pictures is a folder of JPEGs, a manifest and two stills,
/// and all of that has to arrive together or the widget draws a stack with
/// holes in it. A folder does not travel well through a share sheet, iCloud or
/// a file picker; one file does.
///
/// Hand-rolled rather than zipped because Foundation will write a zip
/// (`NSFileCoordinator` with `.forUploading`) and will not read one back, and a
/// container this app writes and reads at both ends does not need compression -
/// the payload is already JPEG and PNG.
///
///     MOTNPKG1  <UInt32 header length>  <JSON header>  <payloads, in order>
enum DesignPackage {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "Package")

    static let magic = Data("MOTNPKG1".utf8)
    static let version = 1
    static let fileExtension = "motionary"

    struct Entry: Codable, Equatable, Sendable {
        let name: String
        let length: Int
    }

    struct Header: Codable, Equatable, Sendable {
        var version: Int
        var design: DesignDocument
        var manifest: BuildManifest
        var entries: [Entry]
    }

    // MARK: - Writing

    /// Packs a design's delivered body: its frames, its manifest and the two
    /// stills the composition needs. The source clip is deliberately left out -
    /// it is the largest thing in the folder and the phone has no use for it.
    static func write(designID: UUID, store: DesignStore) throws -> Data {
        let design = try store.load(id: designID)
        let manifest = try store.loadManifest(id: designID)
        guard manifest.isFrameDriven, let frameCount = manifest.frameCount else {
            throw DesignPackageError.notFrameDriven(designID: designID)
        }

        var entries: [Entry] = []
        var payload = Data()

        func add(_ name: String, _ url: URL) throws {
            guard let data = try? Data(contentsOf: url) else { return }
            entries.append(Entry(name: name, length: data.count))
            payload.append(data)
        }

        for index in 0 ..< frameCount {
            let url = store.frameURL(for: designID, index: index)
            guard let data = try? Data(contentsOf: url) else {
                throw DesignPackageError.entryMissing(name: url.lastPathComponent)
            }
            entries.append(Entry(name: url.lastPathComponent, length: data.count))
            payload.append(data)
        }
        // The tiles travel in the manifest but their pictures do not, and a
        // launcher with no artwork falls back to a catalogue plate - which
        // looks like the design arriving wrong rather than like a missing file.
        let artFolder = store.artFolder(for: designID)
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: artFolder.path)) ?? []).sorted() {
            try add("art/\(name)", artFolder.appendingPathComponent(name))
        }
        if let backdrop = store.existingWidgetBackdropURL(for: designID) {
            try add(backdrop.lastPathComponent, backdrop)
        }
        try add(store.wallpaperURL(for: designID).lastPathComponent, store.wallpaperURL(for: designID))
        try add(
            store.plainWallpaperURL(for: designID).lastPathComponent,
            store.plainWallpaperURL(for: designID)
        )

        let header = Header(version: version, design: design, manifest: manifest, entries: entries)
        let headerData = try JSONEncoder().encode(header)

        var out = Data()
        out.append(magic)
        withUnsafeBytes(of: UInt32(headerData.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(headerData)
        out.append(payload)
        logger.info("packed \(designID.uuidString, privacy: .public): \(entries.count) files, \(out.count) bytes")
        return out
    }

    // MARK: - Reading

    static func header(of data: Data) throws -> Header {
        try parse(data).header
    }

    /// The header and where the payload starts.
    ///
    /// The offset comes from the declared header length rather than from
    /// re-encoding the header - JSON key order is not guaranteed to round-trip
    /// byte for byte - and never from the end of the file: a truncated download
    /// would then shift the start backwards by exactly as much as was missing,
    /// every frame would be written out of the next one's bytes, and the
    /// arithmetic would still add up.
    private static func parse(_ data: Data) throws -> (header: Header, payloadStart: Int) {
        guard data.count > magic.count + 4, data.prefix(magic.count) == magic else {
            throw DesignPackageError.notAPackage(path: "<\(data.count) bytes>")
        }
        let lengthRange = magic.count ..< (magic.count + 4)
        let headerLength = Int(data.subdata(in: lengthRange).withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        })
        let headerEnd = magic.count + 4 + headerLength
        guard data.count >= headerEnd else {
            throw DesignPackageError.truncated(expected: headerEnd, got: data.count)
        }
        let header = try JSONDecoder().decode(
            Header.self,
            from: data.subdata(in: (magic.count + 4) ..< headerEnd)
        )
        guard header.version <= version else {
            throw DesignPackageError.unsupportedVersion(header.version)
        }
        return (header, headerEnd)
    }

    /// Unpacks into the store, keeping the design's own identity so a second
    /// delivery of the same design replaces it rather than piling up beside it.
    @discardableResult
    static func read(_ data: Data, into store: DesignStore) throws -> DesignDocument {
        let (header, payloadStart) = try parse(data)
        let design = header.design
        let total = header.entries.reduce(0) { $0 + $1.length }
        var offset = payloadStart
        guard data.count - payloadStart == total else {
            throw DesignPackageError.truncated(
                expected: total,
                got: max(0, data.count - payloadStart)
            )
        }

        try store.createFolder(for: design.id)
        try store.clearFrames(for: design.id)

        for entry in header.entries {
            let end = offset + entry.length
            guard end <= data.count else {
                throw DesignPackageError.truncated(expected: end, got: data.count)
            }
            let bytes = data.subdata(in: offset ..< end)
            offset = end
            let url: URL
            if entry.name.hasPrefix("frame-") {
                url = store.framesFolder(for: design.id).appendingPathComponent(entry.name)
            } else if entry.name.hasPrefix("art/") {
                let folder = store.artFolder(for: design.id)
                try FileManager.default.createDirectory(
                    at: folder,
                    withIntermediateDirectories: true,
                    attributes: DesignStore.directoryAttributes
                )
                url = folder.appendingPathComponent(String(entry.name.dropFirst("art/".count)))
            } else {
                url = store.folder(for: design.id).appendingPathComponent(entry.name)
            }
            try bytes.write(to: url, options: DesignStore.writingOptions)
        }

        try store.save(design, touch: false)
        try store.save(header.manifest)
        logger.info("""
        unpacked \(design.id.uuidString, privacy: .public): \
        \(header.entries.count) files, \(header.manifest.frameCount ?? 0) frames
        """)
        return design
    }
}
