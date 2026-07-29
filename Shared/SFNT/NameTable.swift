import Foundation

enum NameTableError: Error, CustomStringConvertible {
    case unsupportedFormat(UInt16)
    case stringOutOfBounds(nameID: UInt16, offset: Int, length: Int, tableSize: Int)
    case undecodableString(nameID: UInt16, platformID: UInt16, encodingID: UInt16)
    case unencodableReplacement(nameID: UInt16, value: String)

    var description: String {
        switch self {
        case .unsupportedFormat(let format):
            "name table: format \(format) is not the format 0 layout this rewriter understands"
        case .stringOutOfBounds(let nameID, let offset, let length, let size):
            "name table: nameID \(nameID) string spans \(offset)..<\(offset + length) of a \(size)-byte table"
        case .undecodableString(let nameID, let platformID, let encodingID):
            "name table: cannot decode nameID \(nameID) for platform \(platformID)/\(encodingID)"
        case .unencodableReplacement(let nameID, let value):
            "name table: cannot re-encode nameID \(nameID) as \"\(value)\" in its original encoding"
        }
    }
}

/// Rewrites the family token inside a `name` table.
///
/// Every lane font is registered into the same process, so each one needs a
/// unique PostScript name or CoreText hands back whichever was registered first.
enum NameTable {
    private struct Record {
        let platformID: UInt16
        let encodingID: UInt16
        let languageID: UInt16
        let nameID: UInt16
        var value: String
    }

    static func replacingFamily(in table: Data, from oldFamily: String, to newFamily: String) throws -> Data {
        var records = try decode(table)
        for index in records.indices {
            records[index].value = records[index].value.replacingOccurrences(of: oldFamily, with: newFamily)
        }
        return try encode(records)
    }

    static func value(forNameID nameID: UInt16, in table: Data) throws -> String? {
        try decode(table).first { $0.nameID == nameID }?.value
    }

    private static func decode(_ table: Data) throws -> [Record] {
        let reader = ByteReader(table)
        let format = try reader.readUInt16(context: "name table format")
        guard format == 0 || format == 1 else { throw NameTableError.unsupportedFormat(format) }
        let count = Int(try reader.readUInt16(context: "name record count"))
        let stringOffset = Int(try reader.readUInt16(context: "name string storage offset"))

        var records: [Record] = []
        for index in 0 ..< count {
            let platformID = try reader.readUInt16(context: "platformID of record \(index)")
            let encodingID = try reader.readUInt16(context: "encodingID of record \(index)")
            let languageID = try reader.readUInt16(context: "languageID of record \(index)")
            let nameID = try reader.readUInt16(context: "nameID of record \(index)")
            let length = Int(try reader.readUInt16(context: "length of record \(index)"))
            let offset = Int(try reader.readUInt16(context: "offset of record \(index)"))

            let start = table.startIndex + stringOffset + offset
            guard start + length <= table.endIndex else {
                throw NameTableError.stringOutOfBounds(
                    nameID: nameID,
                    offset: stringOffset + offset,
                    length: length,
                    tableSize: table.count
                )
            }
            let raw = table.subdata(in: start ..< (start + length))
            guard let value = String(data: raw, encoding: encoding(platformID: platformID, encodingID: encodingID)) else {
                throw NameTableError.undecodableString(
                    nameID: nameID,
                    platformID: platformID,
                    encodingID: encodingID
                )
            }
            records.append(Record(
                platformID: platformID,
                encodingID: encodingID,
                languageID: languageID,
                nameID: nameID,
                value: value
            ))
        }
        return records
    }

    private static func encode(_ records: [Record]) throws -> Data {
        // Records must be sorted by platform, encoding, language, then name ID.
        let sorted = records.sorted {
            ($0.platformID, $0.encodingID, $0.languageID, $0.nameID)
                < ($1.platformID, $1.encodingID, $1.languageID, $1.nameID)
        }
        let stringOffset = 6 + sorted.count * 12

        var header = Data()
        header.appendUInt16(0)
        header.appendUInt16(UInt16(sorted.count))
        header.appendUInt16(UInt16(stringOffset))

        var storage = Data()
        for record in sorted {
            let encoding = encoding(platformID: record.platformID, encodingID: record.encodingID)
            guard let bytes = record.value.data(using: encoding) else {
                throw NameTableError.unencodableReplacement(nameID: record.nameID, value: record.value)
            }
            header.appendUInt16(record.platformID)
            header.appendUInt16(record.encodingID)
            header.appendUInt16(record.languageID)
            header.appendUInt16(record.nameID)
            header.appendUInt16(UInt16(bytes.count))
            header.appendUInt16(UInt16(storage.count))
            storage.append(bytes)
        }

        header.append(storage)
        return header
    }

    private static func encoding(platformID: UInt16, encodingID: UInt16) -> String.Encoding {
        // Platform 1 is Macintosh with single-byte scripts; everything else in
        // practice is UTF-16BE.
        platformID == 1 ? .macOSRoman : .utf16BigEndian
    }
}
