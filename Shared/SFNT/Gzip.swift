import Compression
import Foundation

enum GzipError: Error, CustomStringConvertible {
    case compressionFailed(inputBytes: Int)
    case truncatedHeader(byteCount: Int)
    case badMagic(found: [UInt8])
    case unsupportedMethod(UInt8)
    case unsupportedFlags(UInt8)
    case decompressionFailed(inputBytes: Int)
    case checksumMismatch(expected: UInt32, actual: UInt32)
    case lengthMismatch(expected: UInt32, actual: Int)

    var description: String {
        switch self {
        case .compressionFailed(let bytes):
            "gzip: deflate produced no output for \(bytes) input bytes"
        case .truncatedHeader(let count):
            "gzip: stream is \(count) bytes, too short to hold a header and trailer"
        case .badMagic(let found):
            "gzip: expected magic 1f 8b, found \(found.map { String(format: "%02x", $0) }.joined(separator: " "))"
        case .unsupportedMethod(let method):
            "gzip: compression method \(method) is not deflate"
        case .unsupportedFlags(let flags):
            "gzip: header flags 0x\(String(flags, radix: 16)) include an extra field this reader does not parse"
        case .decompressionFailed(let bytes):
            "gzip: inflate produced no output for \(bytes) compressed bytes"
        case .checksumMismatch(let expected, let actual):
            "gzip: CRC32 mismatch, header says \(expected) but payload is \(actual)"
        case .lengthMismatch(let expected, let actual):
            "gzip: trailer says \(expected) bytes but inflate produced \(actual)"
        }
    }
}

/// Minimal gzip wrapper over the Compression framework's raw deflate.
///
/// The OpenType `SVG ` table accepts gzip-encoded documents, and the fonts this
/// app is modelled on ship compressed ones, so writing anything else would be
/// exercising an untested path in CoreText.
enum Gzip {
    private static let headerSize = 10
    private static let trailerSize = 8

    static func compress(_ input: Data) throws -> Data {
        guard !input.isEmpty else {
            // A zero-length member is still a legal stream: header, empty
            // stored block, trailer.
            var empty = header()
            empty.append(contentsOf: [0x03, 0x00])
            empty.append(trailer(crc: 0, size: 0))
            return empty
        }

        let deflated = try transform(input, operation: COMPRESSION_STREAM_ENCODE) {
            GzipError.compressionFailed(inputBytes: input.count)
        }
        guard !deflated.isEmpty else {
            throw GzipError.compressionFailed(inputBytes: input.count)
        }

        var output = header()
        output.append(deflated)
        output.append(trailer(crc: CRC32.checksum(input), size: UInt32(truncatingIfNeeded: input.count)))
        return output
    }

    static func decompress(_ input: Data) throws -> Data {
        guard input.count >= headerSize + trailerSize else {
            throw GzipError.truncatedHeader(byteCount: input.count)
        }
        let bytes = [UInt8](input)
        guard bytes[0] == 0x1f, bytes[1] == 0x8b else {
            throw GzipError.badMagic(found: Array(bytes.prefix(2)))
        }
        guard bytes[2] == 0x08 else {
            throw GzipError.unsupportedMethod(bytes[2])
        }
        // This reader only ever sees streams written by `compress`, which sets
        // no optional fields. Anything else is a caller bug worth surfacing.
        guard bytes[3] == 0x00 else {
            throw GzipError.unsupportedFlags(bytes[3])
        }

        let payload = input.subdata(in: (input.startIndex + headerSize) ..< (input.endIndex - trailerSize))
        let inflated = try transform(payload, operation: COMPRESSION_STREAM_DECODE) {
            GzipError.decompressionFailed(inputBytes: payload.count)
        }

        let trailer = [UInt8](input.suffix(trailerSize))
        let expectedCRC = UInt32(trailer[0]) | UInt32(trailer[1]) << 8 | UInt32(trailer[2]) << 16 | UInt32(trailer[3]) << 24
        let expectedSize = UInt32(trailer[4]) | UInt32(trailer[5]) << 8 | UInt32(trailer[6]) << 16 | UInt32(trailer[7]) << 24

        let actualCRC = CRC32.checksum(inflated)
        guard actualCRC == expectedCRC else {
            throw GzipError.checksumMismatch(expected: expectedCRC, actual: actualCRC)
        }
        guard UInt32(truncatingIfNeeded: inflated.count) == expectedSize else {
            throw GzipError.lengthMismatch(expected: expectedSize, actual: inflated.count)
        }
        return inflated
    }

    /// Raw DEFLATE, without the gzip header and trailer around it.
    ///
    /// Exactly what a zip entry stores, which is why one implementation serves
    /// both: Apple's `COMPRESSION_ZLIB` is RFC1951 with no zlib wrapper.
    static func deflate(_ input: Data) throws -> Data {
        guard !input.isEmpty else { return Data([0x03, 0x00]) }
        let output = try transform(input, operation: COMPRESSION_STREAM_ENCODE) {
            GzipError.compressionFailed(inputBytes: input.count)
        }
        guard !output.isEmpty else {
            throw GzipError.compressionFailed(inputBytes: input.count)
        }
        return output
    }

    static func inflate(_ input: Data) throws -> Data {
        try transform(input, operation: COMPRESSION_STREAM_DECODE) {
            GzipError.decompressionFailed(inputBytes: input.count)
        }
    }

    private static func header() -> Data {
        // No mtime, no extra fields: keeps generated fonts byte-reproducible so
        // an unchanged design regenerates to an identical file.
        Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff])
    }

    private static func trailer(crc: UInt32, size: UInt32) -> Data {
        Data([
            UInt8(truncatingIfNeeded: crc), UInt8(truncatingIfNeeded: crc >> 8),
            UInt8(truncatingIfNeeded: crc >> 16), UInt8(truncatingIfNeeded: crc >> 24),
            UInt8(truncatingIfNeeded: size), UInt8(truncatingIfNeeded: size >> 8),
            UInt8(truncatingIfNeeded: size >> 16), UInt8(truncatingIfNeeded: size >> 24),
        ])
    }

    private static func transform(
        _ input: Data,
        operation: compression_stream_operation,
        failure: () -> GzipError
    ) throws -> Data {
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: -1)!,
            dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: -1)!,
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw failure()
        }
        defer { compression_stream_destroy(&stream) }

        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var output = Data()
        let status: compression_status = input.withUnsafeBytes { raw -> compression_status in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            stream.src_ptr = base
            stream.src_size = input.count

            var result = COMPRESSION_STATUS_OK
            repeat {
                stream.dst_ptr = buffer
                stream.dst_size = bufferSize
                result = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard result != COMPRESSION_STATUS_ERROR else { return result }
                output.append(buffer, count: bufferSize - stream.dst_size)
            } while result == COMPRESSION_STATUS_OK
            return result
        }

        // An empty result is legitimate when inflating a zero-length member, so
        // only the stream status decides success here.
        guard status == COMPRESSION_STATUS_END else { throw failure() }
        return output
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0 ..< 256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0 ..< 8 {
            value = (value & 1) == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
