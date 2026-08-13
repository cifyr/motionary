import Foundation

enum DeliveryWireError: Error, CustomStringConvertible {
    case notOurStream
    case payloadTooLarge(declared: Int, limit: Int)

    var description: String {
        switch self {
        case .notOurStream:
            "wire: the other end did not open with the Motionary marker"
        case .payloadTooLarge(let declared, let limit):
            "wire: the sender declared \(declared / 1_048_576)MB and the limit is \(limit / 1_048_576)MB"
        }
    }
}

/// How a design package crosses a network connection.
///
/// The package format has a marker and a header, but nothing in it says how
/// long the whole file is - the reader is expected to have the file already.
/// A socket has no end until the sender hangs up, and hanging up is also what a
/// dropped connection looks like, so a half-received package would be
/// indistinguishable from a complete one. Hence a length in front.
///
///     MOTNWIRE  <UInt64 payload length>  <package bytes>
///
/// Kept apart from the `Network` framework on purpose: the framing is the part
/// that can be got wrong in a way no test on a real socket would catch
/// reliably, and this way it is tested without one.
enum DeliveryWire {
    static let magic = Data("MOTNWIRE".utf8)
    static let headerLength = magic.count + 8

    /// The Bonjour service the phone advertises and the Mac looks for.
    static let serviceType = "_motionary._tcp"

    /// Well past a real design - the largest packed here was 6.4MB - and far
    /// short of anything that would exhaust a phone. A length prefix is
    /// attacker-controlled input even on a home network, and allocating on a
    /// declared size without a ceiling is how that becomes a crash.
    static let maximumPayloadBytes = 512 * 1_048_576

    static func frame(_ payload: Data) -> Data {
        var out = Data(capacity: headerLength + payload.count)
        out.append(magic)
        withUnsafeBytes(of: UInt64(payload.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    /// The payload when the buffer holds a whole frame, nil while it still
    /// needs more bytes, and a throw when the stream is not ours at all.
    ///
    /// Three outcomes rather than two: a receiver that cannot tell "not yet"
    /// from "never" either gives up on a slow network or waits forever on a
    /// wrong connection.
    static func payload(in buffer: Data) throws -> Data? {
        guard buffer.count >= magic.count else {
            // Not enough to judge yet, but what is there has to match: a stream
            // that opens with something else is refused on its first bytes
            // rather than after a megabyte of it.
            guard buffer.elementsEqual(magic.prefix(buffer.count)) else {
                throw DeliveryWireError.notOurStream
            }
            return nil
        }
        guard buffer.prefix(magic.count) == magic else { throw DeliveryWireError.notOurStream }
        guard buffer.count >= headerLength else { return nil }

        let lengthBytes = buffer.subdata(in: magic.count ..< headerLength)
        let declared = Int(lengthBytes.withUnsafeBytes {
            UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))
        })
        guard declared <= maximumPayloadBytes else {
            throw DeliveryWireError.payloadTooLarge(declared: declared, limit: maximumPayloadBytes)
        }
        guard buffer.count >= headerLength + declared else { return nil }
        return buffer.subdata(in: headerLength ..< (headerLength + declared))
    }

    /// What the phone says back, so the Mac reports what happened on the phone
    /// rather than only that the bytes left the building.
    struct Receipt: Codable, Equatable, Sendable {
        var ok: Bool
        var message: String

        var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data() }

        static func decode(_ data: Data) -> Receipt {
            (try? JSONDecoder().decode(Receipt.self, from: data))
                ?? Receipt(ok: false, message: "the phone answered with \(data.count) bytes that were not a receipt")
        }
    }
}
