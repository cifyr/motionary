import Foundation

enum SFNTError: Error, CustomStringConvertible {
    case truncated(needed: Int, available: Int, whileReading: String)
    case unsupportedVersion(UInt32)
    case tableOutOfBounds(tag: String, offset: Int, length: Int, fileSize: Int)
    case missingTable(tag: String)
    case headTooShort(length: Int)

    var description: String {
        switch self {
        case .truncated(let needed, let available, let context):
            "sfnt: needed \(needed) bytes for \(context) but only \(available) remain"
        case .unsupportedVersion(let version):
            "sfnt: unsupported version 0x\(String(version, radix: 16)); expected 0x10000 or OTTO"
        case .tableOutOfBounds(let tag, let offset, let length, let size):
            "sfnt: table '\(tag)' claims bytes \(offset)..<\(offset + length) of a \(size)-byte file"
        case .missingTable(let tag):
            "sfnt: font has no '\(tag)' table"
        case .headTooShort(let length):
            "sfnt: 'head' table is \(length) bytes, too short to hold checkSumAdjustment"
        }
    }
}

/// A parsed sfnt container that can be modified table-by-table and written back.
///
/// Motionary never compiles a font from scratch. It loads one shaping template
/// and replaces the `SVG ` and `name` tables, so this only needs to be faithful
/// about the table directory, padding, and checksums.
struct SFNTFile {
    private(set) var version: UInt32
    /// Preserved in directory order so untouched fonts round-trip byte-exactly.
    private(set) var tags: [String]
    private var tables: [String: Data]

    init(data: Data) throws {
        let reader = ByteReader(data)
        version = try reader.readUInt32(context: "sfnt version")
        guard version == 0x0001_0000 || version == 0x4F54_544F else {
            throw SFNTError.unsupportedVersion(version)
        }
        let numTables = Int(try reader.readUInt16(context: "numTables"))
        _ = try reader.readUInt16(context: "searchRange")
        _ = try reader.readUInt16(context: "entrySelector")
        _ = try reader.readUInt16(context: "rangeShift")

        var tags: [String] = []
        var tables: [String: Data] = [:]
        for index in 0 ..< numTables {
            let tag = try reader.readTag(context: "table record \(index)")
            _ = try reader.readUInt32(context: "checksum of '\(tag)'")
            let offset = Int(try reader.readUInt32(context: "offset of '\(tag)'"))
            let length = Int(try reader.readUInt32(context: "length of '\(tag)'"))
            guard offset >= 0, length >= 0, offset + length <= data.count else {
                throw SFNTError.tableOutOfBounds(tag: tag, offset: offset, length: length, fileSize: data.count)
            }
            tags.append(tag)
            tables[tag] = data.subdata(in: (data.startIndex + offset) ..< (data.startIndex + offset + length))
        }
        self.tags = tags
        self.tables = tables
    }

    func table(_ tag: String) throws -> Data {
        guard let table = tables[tag] else { throw SFNTError.missingTable(tag: tag) }
        return table
    }

    mutating func setTable(_ tag: String, to data: Data) {
        if tables[tag] == nil { tags.append(tag) }
        tables[tag] = data
    }

    func serialized() throws -> Data {
        // Table records must be sorted by tag; the table bodies themselves may
        // follow in any order, so keeping the template's order minimises diffs.
        let sortedTags = tags.sorted()
        let directorySize = 12 + sortedTags.count * 16

        var offsets: [String: Int] = [:]
        var lengths: [String: Int] = [:]
        var body = Data()
        for tag in tags {
            let table = tables[tag]!
            offsets[tag] = directorySize + body.count
            lengths[tag] = table.count
            body.append(table)
            let padding = (4 - table.count % 4) % 4
            if padding > 0 { body.append(Data(repeating: 0, count: padding)) }
        }

        var output = Data()
        output.appendUInt32(version)
        output.appendUInt16(UInt16(sortedTags.count))
        let entrySelector = UInt16(max(0, Int(log2(Double(max(sortedTags.count, 1))))))
        let searchRange = UInt16(16 * (1 << entrySelector))
        output.appendUInt16(searchRange)
        output.appendUInt16(entrySelector)
        output.appendUInt16(UInt16(truncatingIfNeeded: sortedTags.count * 16 - Int(searchRange)))

        for tag in sortedTags {
            output.appendTag(tag)
            output.appendUInt32(Self.checksum(tables[tag]!))
            output.appendUInt32(UInt32(offsets[tag]!))
            output.appendUInt32(UInt32(lengths[tag]!))
        }
        output.append(body)

        try Self.applyCheckSumAdjustment(to: &output, headOffset: offsets["head"], headLength: lengths["head"])
        return output
    }

    /// The whole-file checksum lives inside `head`, so it can only be written
    /// once every table offset is final.
    private static func applyCheckSumAdjustment(to file: inout Data, headOffset: Int?, headLength: Int?) throws {
        guard let headOffset else { throw SFNTError.missingTable(tag: "head") }
        guard let headLength, headLength >= 12 else { throw SFNTError.headTooShort(length: headLength ?? 0) }

        let adjustmentRange = (file.startIndex + headOffset + 8) ..< (file.startIndex + headOffset + 12)
        file.replaceSubrange(adjustmentRange, with: [0, 0, 0, 0])
        let adjustment = 0xB1B0_AFBA &- checksum(file)
        file.replaceSubrange(adjustmentRange, with: [
            UInt8(truncatingIfNeeded: adjustment >> 24), UInt8(truncatingIfNeeded: adjustment >> 16),
            UInt8(truncatingIfNeeded: adjustment >> 8), UInt8(truncatingIfNeeded: adjustment),
        ])
    }

    /// Sum of big-endian UInt32s over the table, zero-padded to a 4-byte bound.
    ///
    /// Offsets are plain integers rather than `Data.index(_:offsetBy:)`, which
    /// traps once the final 4-byte stride overshoots `endIndex` — and tables
    /// such as `head` are deliberately not a multiple of four bytes long.
    static func checksum(_ data: Data) -> UInt32 {
        var sum: UInt32 = 0
        let count = data.count
        let base = data.startIndex
        var position = 0
        while position < count {
            var word: UInt32 = 0
            for byteIndex in 0 ..< 4 {
                let index = position + byteIndex
                let byte: UInt8 = index < count ? data[base + index] : 0
                word = word << 8 | UInt32(byte)
            }
            sum = sum &+ word
            position += 4
        }
        return sum
    }
}

/// Bounds-checked sequential reader. Every failure names what it was reading so
/// a malformed template says which field it died on.
final class ByteReader {
    private let data: Data
    private var cursor: Int

    init(_ data: Data) {
        self.data = data
        cursor = 0
    }

    var offset: Int { cursor }

    func seek(to position: Int) { cursor = position }

    func readUInt16(context: String) throws -> UInt16 {
        let bytes = try read(2, context: context)
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    func readUInt32(context: String) throws -> UInt32 {
        let bytes = try read(4, context: context)
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }

    func readTag(context: String) throws -> String {
        let bytes = try read(4, context: context)
        return String(decoding: bytes, as: UTF8.self)
    }

    func read(_ count: Int, context: String) throws -> [UInt8] {
        guard cursor + count <= data.count else {
            throw SFNTError.truncated(needed: count, available: data.count - cursor, whileReading: context)
        }
        let start = data.index(data.startIndex, offsetBy: cursor)
        let slice = data[start ..< data.index(start, offsetBy: count)]
        cursor += count
        return [UInt8](slice)
    }
}

extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(contentsOf: [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(contentsOf: [
            UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value),
        ])
    }

    mutating func appendTag(_ tag: String) {
        var bytes = Array(tag.utf8.prefix(4))
        while bytes.count < 4 { bytes.append(0x20) }
        append(contentsOf: bytes)
    }
}
