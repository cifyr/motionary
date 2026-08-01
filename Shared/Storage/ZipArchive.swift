import Foundation

enum ZipArchiveError: Error, CustomStringConvertible {
    case notAZip(path: String, byteCount: Int)
    case truncated(path: String, wanted: Int, available: Int)
    case zip64Unsupported(path: String)
    case encrypted(path: String, entry: String)
    case unsupportedMethod(entry: String, method: UInt16)
    case entryEscapesDestination(entry: String)
    case checksumMismatch(entry: String, expected: UInt32, actual: UInt32)
    case readFailed(path: String, underlying: Error)
    case writeFailed(entry: String, destination: String, underlying: Error)

    var description: String {
        switch self {
        case .notAZip(let path, let count):
            "zip: \(path) is \(count) bytes with no end-of-directory record in it; it is not a zip"
        case .truncated(let path, let wanted, let available):
            "zip: \(path) points at byte \(wanted) but is only \(available) bytes long"
        case .zip64Unsupported(let path):
            "zip: \(path) is a zip64 archive, which this reader does not parse"
        case .encrypted(let path, let entry):
            "zip: \(entry) in \(path) is encrypted"
        case .unsupportedMethod(let entry, let method):
            "zip: \(entry) uses compression method \(method); only stored (0) and deflate (8) are read"
        case .entryEscapesDestination(let entry):
            "zip: \(entry) names a path outside the folder it is being unpacked into"
        case .checksumMismatch(let entry, let expected, let actual):
            "zip: \(entry) unpacked to CRC32 \(actual) but the directory says \(expected)"
        case .readFailed(let path, let underlying):
            "zip: could not read \(path): \(underlying)"
        case .writeFailed(let entry, let destination, let underlying):
            "zip: could not write \(entry) to \(destination): \(underlying)"
        }
    }
}

/// PKZip, read and written in Foundation and Compression alone.
///
/// This was `/usr/bin/ditto` through `Process`, which does not exist on iOS - so
/// a design mailed or AirDropped to the phone could not be opened there at all.
/// The container is handled here instead of adding a second unarchiver beside
/// the first, because two implementations of one format is two things to be
/// wrong: what the Mac writes is now exactly what the phone reads.
///
/// Only what this app's own archives use is covered: stored and deflated
/// entries, no zip64, no encryption. Anything else is named and thrown rather
/// than skipped, because a design that silently loses its clip imports as a
/// layout with nothing in it.
enum ZipArchive {
    private static let localHeaderSignature: UInt32 = 0x0403_4b50
    private static let centralHeaderSignature: UInt32 = 0x0201_4b50
    private static let endOfDirectorySignature: UInt32 = 0x0605_4b50
    private static let localHeaderSize = 30
    private static let centralHeaderSize = 46
    private static let endOfDirectorySize = 22

    private static let stored: UInt16 = 0
    private static let deflated: UInt16 = 8

    /// A fixed 1980-01-01, the earliest a DOS stamp can express. Zero is not a
    /// legal date - day and month both start at 1 - and the real modification
    /// time would make an unchanged design export to a different file every go.
    private static let dosTime: UInt16 = 0
    private static let dosDate: UInt16 = 0x0021

    // MARK: - Reading

    /// One entry as the central directory describes it.
    private struct Entry {
        let name: String
        let method: UInt16
        let crc: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        let isEncrypted: Bool
    }

    /// Unpacks an archive into a folder, creating it if needed.
    static func extract(_ archive: URL, into destination: URL) throws {
        let manager = FileManager.default
        let data: Data
        do {
            data = try Data(contentsOf: archive, options: .mappedIfSafe)
        } catch {
            throw ZipArchiveError.readFailed(path: archive.path, underlying: error)
        }
        let path = archive.lastPathComponent
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)

        for entry in try entries(in: data, path: path) {
            // Finder's own resource-fork sidecars, which `ditto --sequesterRsrc`
            // adds and nothing here wants back.
            guard !entry.name.hasPrefix("__MACOSX/") else { continue }
            guard entry.isEncrypted == false else {
                throw ZipArchiveError.encrypted(path: path, entry: entry.name)
            }
            guard let relative = safeRelativePath(entry.name) else {
                throw ZipArchiveError.entryEscapesDestination(entry: entry.name)
            }
            let target = destination.appendingPathComponent(relative)

            if entry.name.hasSuffix("/") {
                try manager.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try manager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let payload = try body(of: entry, in: data, path: path)
            let contents: Data
            switch entry.method {
            case stored:
                contents = payload
            case deflated:
                contents = try Gzip.inflate(payload)
            default:
                throw ZipArchiveError.unsupportedMethod(entry: entry.name, method: entry.method)
            }

            let actual = CRC32.checksum(contents)
            guard actual == entry.crc else {
                throw ZipArchiveError.checksumMismatch(entry: entry.name, expected: entry.crc, actual: actual)
            }
            do {
                try contents.write(to: target, options: .atomic)
            } catch {
                throw ZipArchiveError.writeFailed(
                    entry: entry.name, destination: target.path, underlying: error
                )
            }
        }
    }

    private static func entries(in data: Data, path: String) throws -> [Entry] {
        let end = try endOfDirectoryOffset(in: data, path: path)
        let count = Int(u16(data, end + 10))
        let directoryOffset = Int(u32(data, end + 16))
        // The two sentinels that mean the real values live in a zip64 record.
        guard count != 0xFFFF, directoryOffset != 0xFFFF_FFFF else {
            throw ZipArchiveError.zip64Unsupported(path: path)
        }

        var offset = directoryOffset
        var found: [Entry] = []
        for _ in 0 ..< count {
            guard offset + centralHeaderSize <= data.count else {
                throw ZipArchiveError.truncated(
                    path: path, wanted: offset + centralHeaderSize, available: data.count
                )
            }
            guard u32(data, offset) == centralHeaderSignature else {
                throw ZipArchiveError.notAZip(path: path, byteCount: data.count)
            }
            let nameLength = Int(u16(data, offset + 28))
            let extraLength = Int(u16(data, offset + 30))
            let commentLength = Int(u16(data, offset + 32))
            let nameEnd = offset + centralHeaderSize + nameLength
            guard nameEnd <= data.count else {
                throw ZipArchiveError.truncated(path: path, wanted: nameEnd, available: data.count)
            }
            found.append(Entry(
                name: string(data, from: offset + centralHeaderSize, to: nameEnd),
                method: u16(data, offset + 10),
                crc: u32(data, offset + 16),
                compressedSize: Int(u32(data, offset + 20)),
                uncompressedSize: Int(u32(data, offset + 24)),
                localHeaderOffset: Int(u32(data, offset + 42)),
                isEncrypted: u16(data, offset + 8) & 1 == 1
            ))
            offset = nameEnd + extraLength + commentLength
        }
        return found
    }

    /// The entry's bytes as stored, located through its own local header.
    ///
    /// The sizes come from the central directory rather than the local header,
    /// because an archive written as a stream leaves zeros in the local one and
    /// puts the real numbers in a descriptor after the data.
    private static func body(of entry: Entry, in data: Data, path: String) throws -> Data {
        let header = entry.localHeaderOffset
        guard header + localHeaderSize <= data.count else {
            throw ZipArchiveError.truncated(
                path: path, wanted: header + localHeaderSize, available: data.count
            )
        }
        guard u32(data, header) == localHeaderSignature else {
            throw ZipArchiveError.notAZip(path: path, byteCount: data.count)
        }
        let nameLength = Int(u16(data, header + 26))
        let extraLength = Int(u16(data, header + 28))
        let start = header + localHeaderSize + nameLength + extraLength
        let finish = start + entry.compressedSize
        guard finish <= data.count else {
            throw ZipArchiveError.truncated(path: path, wanted: finish, available: data.count)
        }
        return data.subdata(in: (data.startIndex + start) ..< (data.startIndex + finish))
    }

    /// The end-of-directory record, searched for from the back because a zip
    /// may carry up to 64KB of trailing comment after it.
    private static func endOfDirectoryOffset(in data: Data, path: String) throws -> Int {
        guard data.count >= endOfDirectorySize else {
            throw ZipArchiveError.notAZip(path: path, byteCount: data.count)
        }
        let earliest = max(0, data.count - endOfDirectorySize - 0xFFFF)
        var offset = data.count - endOfDirectorySize
        while offset >= earliest {
            if u32(data, offset) == endOfDirectorySignature { return offset }
            offset -= 1
        }
        throw ZipArchiveError.notAZip(path: path, byteCount: data.count)
    }

    /// An entry's path reduced to something that cannot land outside the
    /// destination. A zip may name `../../etc/passwd` and a reader that simply
    /// appends will write it there.
    private static func safeRelativePath(_ name: String) -> String? {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\") else { return nil }
        let parts = name.split(separator: "/")
        guard !parts.isEmpty, parts.allSatisfy({ $0 != ".." && $0 != "." }) else { return nil }
        return parts.joined(separator: "/")
    }

    // MARK: - Writing

    /// Packs a folder's contents into an archive, paths relative to the folder.
    static func write(directory: URL, to destination: URL) throws {
        var body = Data()
        var directoryRecords = Data()
        var count = 0

        for relative in try contents(of: directory) {
            let source = directory.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
            let name = isDirectory.boolValue ? relative + "/" : relative

            let contents: Data
            if isDirectory.boolValue {
                contents = Data()
            } else {
                do {
                    contents = try Data(contentsOf: source, options: .mappedIfSafe)
                } catch {
                    throw ZipArchiveError.readFailed(path: source.path, underlying: error)
                }
            }

            // Stored when deflate does not earn its place: a design's clip is
            // already-compressed video, and re-deflating it spends time to make
            // the archive bigger.
            var method = stored
            var payload = contents
            if !contents.isEmpty {
                let squeezed = try Gzip.deflate(contents)
                if squeezed.count < contents.count {
                    payload = squeezed
                    method = deflated
                }
            }

            let crc = CRC32.checksum(contents)
            let offset = body.count
            body.append(localHeader(
                name: name, method: method, crc: crc,
                compressed: payload.count, uncompressed: contents.count
            ))
            body.append(payload)
            directoryRecords.append(centralHeader(
                name: name, method: method, crc: crc,
                compressed: payload.count, uncompressed: contents.count,
                isDirectory: isDirectory.boolValue, localHeaderOffset: offset
            ))
            count += 1
        }

        var archive = body
        archive.append(directoryRecords)
        archive.append(endOfDirectory(
            count: count, size: directoryRecords.count, offset: body.count
        ))
        do {
            try archive.write(to: destination, options: .atomic)
        } catch {
            throw ZipArchiveError.writeFailed(
                entry: directory.lastPathComponent, destination: destination.path, underlying: error
            )
        }
    }

    /// Every file and folder under `directory`, sorted so the same input packs
    /// to the same bytes twice running.
    private static func contents(of directory: URL) throws -> [String] {
        let manager = FileManager.default
        guard let walker = manager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ZipArchiveError.readFailed(
                path: directory.path,
                underlying: CocoaError(.fileReadNoSuchFile)
            )
        }
        let prefix = directory.standardizedFileURL.path + "/"
        return walker
            .compactMap { $0 as? URL }
            .map(\.standardizedFileURL.path)
            .compactMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil }
            .sorted()
    }

    private static func localHeader(
        name: String, method: UInt16, crc: UInt32, compressed: Int, uncompressed: Int
    ) -> Data {
        var header = Data()
        header.append(u32: localHeaderSignature)
        header.append(u16: 20)
        header.append(u16: 0)
        header.append(u16: method)
        header.append(u16: dosTime)
        header.append(u16: dosDate)
        header.append(u32: crc)
        header.append(u32: UInt32(compressed))
        header.append(u32: UInt32(uncompressed))
        let bytes = Data(name.utf8)
        header.append(u16: UInt16(bytes.count))
        header.append(u16: 0)
        header.append(bytes)
        return header
    }

    private static func centralHeader(
        name: String, method: UInt16, crc: UInt32, compressed: Int, uncompressed: Int,
        isDirectory: Bool, localHeaderOffset: Int
    ) -> Data {
        var header = Data()
        header.append(u32: centralHeaderSignature)
        header.append(u16: 20)
        header.append(u16: 20)
        header.append(u16: 0)
        header.append(u16: method)
        header.append(u16: dosTime)
        header.append(u16: dosDate)
        header.append(u32: crc)
        header.append(u32: UInt32(compressed))
        header.append(u32: UInt32(uncompressed))
        let bytes = Data(name.utf8)
        header.append(u16: UInt16(bytes.count))
        header.append(u16: 0)
        header.append(u16: 0)
        header.append(u16: 0)
        header.append(u16: 0)
        // The MS-DOS directory attribute, so a tool that unpacks by attribute
        // rather than by the trailing slash still makes a folder.
        header.append(u32: isDirectory ? 0x10 : 0)
        header.append(u32: UInt32(localHeaderOffset))
        header.append(bytes)
        return header
    }

    private static func endOfDirectory(count: Int, size: Int, offset: Int) -> Data {
        var record = Data()
        record.append(u32: endOfDirectorySignature)
        record.append(u16: 0)
        record.append(u16: 0)
        record.append(u16: UInt16(count))
        record.append(u16: UInt16(count))
        record.append(u32: UInt32(size))
        record.append(u32: UInt32(offset))
        record.append(u16: 0)
        return record
    }

    // MARK: - Bytes

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | UInt16(data[base + 1]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base])
            | UInt32(data[base + 1]) << 8
            | UInt32(data[base + 2]) << 16
            | UInt32(data[base + 3]) << 24
    }

    /// Entry names are UTF-8 in anything this reads; a name that is not decodes
    /// with replacement rather than failing the whole archive.
    private static func string(_ data: Data, from: Int, to: Int) -> String {
        String(decoding: data.subdata(in: (data.startIndex + from) ..< (data.startIndex + to)), as: UTF8.self)
    }
}

private extension Data {
    mutating func append(u16 value: UInt16) {
        append(contentsOf: [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)])
    }

    mutating func append(u32 value: UInt32) {
        append(contentsOf: [
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24),
        ])
    }
}
