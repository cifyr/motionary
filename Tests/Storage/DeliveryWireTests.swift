import XCTest

/// Framing is where a network transfer goes wrong quietly. A socket ends when
/// the sender hangs up, and a dropped connection hangs up too - so without a
/// length in front, half a design looks exactly like all of one.
final class DeliveryWireTests: XCTestCase {
    private let body = Data((0 ..< 5000).map { UInt8($0 % 251) })

    func testAWholeFrameGivesBackExactlyWhatWentIn() throws {
        let framed = DeliveryWire.frame(body)
        XCTAssertEqual(framed.count, DeliveryWire.headerLength + body.count)
        XCTAssertEqual(try DeliveryWire.payload(in: framed), body)
    }

    /// The case that matters: bytes arrive in whatever chunks the network
    /// feels like, and every prefix short of the whole frame has to read as
    /// "not yet" rather than as a short package.
    func testEveryPartialPrefixAsksForMoreRatherThanReturningAShortPackage() throws {
        let framed = DeliveryWire.frame(body)
        for cut in stride(from: 0, to: framed.count, by: 97) {
            XCTAssertNil(
                try DeliveryWire.payload(in: framed.prefix(cut)),
                "a \(cut)-byte prefix should not have been taken as complete"
            )
        }
        XCTAssertNotNil(try DeliveryWire.payload(in: framed))
    }

    /// Trailing bytes are not this layer's business, but they must not corrupt
    /// the payload it hands back.
    func testExtraBytesAfterTheFrameDoNotLeakIntoThePayload() throws {
        var framed = DeliveryWire.frame(body)
        framed.append(Data(repeating: 0xFF, count: 64))
        XCTAssertEqual(try DeliveryWire.payload(in: framed), body)
    }

    /// A wrong connection has to be refused on its first bytes, not after a
    /// megabyte of them.
    func testSomethingElseOnTheSocketIsRefusedImmediately() {
        XCTAssertThrowsError(try DeliveryWire.payload(in: Data("GET / HTTP/1.1".utf8)))
        XCTAssertThrowsError(try DeliveryWire.payload(in: Data("MOTN?".utf8)))
    }

    /// An empty buffer is silence, which is not yet an error.
    func testSilenceIsNotAnError() throws {
        XCTAssertNil(try DeliveryWire.payload(in: Data()))
    }

    /// The length is attacker-controlled input even on a home network, and
    /// allocating on it without a ceiling is how that becomes a crash.
    func testAnAbsurdDeclaredLengthIsRefusedRatherThanAllocated() {
        var hostile = DeliveryWire.magic
        withUnsafeBytes(of: UInt64(UInt64(DeliveryWire.maximumPayloadBytes) + 1).littleEndian) {
            hostile.append(contentsOf: $0)
        }
        XCTAssertThrowsError(try DeliveryWire.payload(in: hostile)) { error in
            XCTAssertTrue("\(error)".contains("limit is"), "\(error)")
        }
    }

    func testAnEmptyPayloadStillFramesAndUnframes() throws {
        XCTAssertEqual(try DeliveryWire.payload(in: DeliveryWire.frame(Data())), Data())
    }

    /// The receipt is what the Mac reports, so an unreadable one has to become
    /// a failure with something to read rather than a silent success.
    func testAnUnreadableReceiptReadsAsFailure() {
        let good = DeliveryWire.Receipt(ok: true, message: "Delivered Spidey Swing")
        XCTAssertEqual(DeliveryWire.Receipt.decode(good.encoded), good)

        let bad = DeliveryWire.Receipt.decode(Data("not json".utf8))
        XCTAssertFalse(bad.ok)
        XCTAssertTrue(bad.message.contains("not a receipt"), bad.message)
    }
}
