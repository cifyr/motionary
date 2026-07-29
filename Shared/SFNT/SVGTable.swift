import Foundation

enum SVGTableError: Error, CustomStringConvertible {
    case unsupportedVersion(UInt16)
    case documentOutOfBounds(index: Int, offset: Int, length: Int, tableSize: Int)
    case noDocuments
    case documentCountMismatch(expected: Int, provided: Int)

    var description: String {
        switch self {
        case .unsupportedVersion(let version):
            "SVG table: version \(version) is not the version 0 layout this reader understands"
        case .documentOutOfBounds(let index, let offset, let length, let size):
            "SVG table: document \(index) claims bytes \(offset)..<\(offset + length) of a \(size)-byte table"
        case .noDocuments:
            "SVG table: template contains no SVG documents to learn glyph IDs from"
        case .documentCountMismatch(let expected, let provided):
            "SVG table: template has \(expected) animation glyphs but \(provided) documents were supplied"
        }
    }
}

/// One glyph's SVG payload. Motionary always writes one glyph per document,
/// which is what the reference fonts do.
struct SVGGlyphDocument {
    let glyphID: UInt16
    /// gzip-encoded SVG source, ready to write.
    let compressed: Data
}

enum SVGTable {
    private static let documentListOffset = 10
    private static let entrySize = 12

    /// Glyph IDs the template assigns to animation frames, in ascending order.
    static func glyphIDs(in table: Data) throws -> [UInt16] {
        let reader = ByteReader(table)
        let version = try reader.readUInt16(context: "SVG table version")
        guard version == 0 else { throw SVGTableError.unsupportedVersion(version) }
        let listOffset = Int(try reader.readUInt32(context: "offsetToSVGDocumentList"))
        _ = try reader.readUInt32(context: "SVG table reserved field")

        reader.seek(to: listOffset)
        let count = Int(try reader.readUInt16(context: "SVG document count"))
        guard count > 0 else { throw SVGTableError.noDocuments }

        var ids: [UInt16] = []
        for index in 0 ..< count {
            let start = try reader.readUInt16(context: "startGlyphID of document \(index)")
            let end = try reader.readUInt16(context: "endGlyphID of document \(index)")
            let offset = Int(try reader.readUInt32(context: "svgDocOffset of document \(index)"))
            let length = Int(try reader.readUInt32(context: "svgDocLength of document \(index)"))
            guard listOffset + offset + length <= table.count else {
                throw SVGTableError.documentOutOfBounds(
                    index: index,
                    offset: listOffset + offset,
                    length: length,
                    tableSize: table.count
                )
            }
            ids.append(contentsOf: start ... end)
        }
        return ids.sorted()
    }

    /// Read one document back out, decompressed. Used by tests and by the
    /// verifier to prove a generated font holds the frames it should.
    static func document(at index: Int, in table: Data) throws -> Data {
        let reader = ByteReader(table)
        _ = try reader.readUInt16(context: "SVG table version")
        let listOffset = Int(try reader.readUInt32(context: "offsetToSVGDocumentList"))
        _ = try reader.readUInt32(context: "SVG table reserved field")

        reader.seek(to: listOffset + 2 + index * entrySize + 4)
        let offset = Int(try reader.readUInt32(context: "svgDocOffset of document \(index)"))
        let length = Int(try reader.readUInt32(context: "svgDocLength of document \(index)"))
        let start = table.startIndex + listOffset + offset
        guard start + length <= table.endIndex else {
            throw SVGTableError.documentOutOfBounds(
                index: index,
                offset: listOffset + offset,
                length: length,
                tableSize: table.count
            )
        }
        return try Gzip.decompress(table.subdata(in: start ..< (start + length)))
    }

    static func build(documents: [SVGGlyphDocument]) -> Data {
        let sorted = documents.sorted { $0.glyphID < $1.glyphID }
        let indexSize = 2 + sorted.count * entrySize

        var payload = Data()
        var entries = Data()
        entries.appendUInt16(UInt16(sorted.count))
        for document in sorted {
            entries.appendUInt16(document.glyphID)
            entries.appendUInt16(document.glyphID)
            entries.appendUInt32(UInt32(indexSize + payload.count))
            entries.appendUInt32(UInt32(document.compressed.count))
            payload.append(document.compressed)
        }

        var table = Data()
        table.appendUInt16(0)
        table.appendUInt32(UInt32(documentListOffset))
        table.appendUInt32(0)
        table.append(entries)
        table.append(payload)
        return table
    }
}
