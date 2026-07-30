import XCTest

/// The profile is data now, so the thing that used to be a compile error is a
/// runtime one. These cover the two failures that would otherwise be invisible:
/// a file that does not describe this device, and a file that decodes but says
/// "subtract nothing".
final class EdgeProfileTests: XCTestCase {
    private let deviceID = DeviceGeometry.model.id

    /// The shipped file has to be in the bundle and cover the device this build
    /// is cut for. Without this the pipeline silently falls back and every
    /// recalibration written to the file does nothing.
    func testTheBundledFileCoversThisDevice() throws {
        let loaded = try EdgeProfileStore.loadOrThrow(deviceID: deviceID)
        XCTAssertFalse(loaded.top.isEmpty)
        XCTAssertFalse(loaded.bottom.isEmpty)
    }

    /// The file and the compiled-in fallback must agree, or the build behaves one
    /// way with the resource present and another way without it - which is the
    /// hardest kind of difference to notice from a photograph.
    func testTheBundledFileMatchesTheShippedNumbers() throws {
        let loaded = try EdgeProfileStore.loadOrThrow(deviceID: deviceID)
        XCTAssertEqual(loaded, EdgeCompensation.shipped)
    }

    /// What the pipeline actually uses comes from the file.
    func testTheProfileInUseIsTheLoadedOne() {
        XCTAssertEqual(EdgeCompensation.profile.top.count, EdgeCompensation.topAdded.count)
        XCTAssertEqual(EdgeCompensation.profile.strength, EdgeCompensation.strength)
    }

    func testAnUnknownDeviceIsAnError() {
        XCTAssertThrowsError(try EdgeProfileStore.loadOrThrow(deviceID: "not-a-phone")) { error in
            guard case EdgeProfileError.deviceMissing = error else {
                return XCTFail("wanted deviceMissing, got \(error)")
            }
        }
    }

    /// An empty edge decodes cleanly and corrects nothing, which looks exactly
    /// like the artefact it is meant to remove.
    func testAnEmptyEdgeIsAnError() throws {
        let data = try json(top: "[]", bottom: "[[1, 1, 1]]")
        XCTAssertThrowsError(try EdgeProfileStore.loadOrThrow(deviceID: "test", data: data)) { error in
            guard case EdgeProfileError.edgeEmpty = error else {
                return XCTFail("wanted edgeEmpty, got \(error)")
            }
        }
    }

    func testAShortRowIsAnError() throws {
        let data = try json(top: "[[1, 2]]", bottom: "[[1, 1, 1]]")
        XCTAssertThrowsError(try EdgeProfileStore.loadOrThrow(deviceID: "test", data: data)) { error in
            guard case EdgeProfileError.malformedRow = error else {
                return XCTFail("wanted malformedRow, got \(error)")
            }
        }
    }

    /// The system adds light. A negative entry would brighten the edge instead of
    /// darkening it, so it is a sign error rather than an unusual calibration.
    func testANegativeRowIsAnError() throws {
        let data = try json(top: "[[1, -2, 3]]", bottom: "[[1, 1, 1]]")
        XCTAssertThrowsError(try EdgeProfileStore.loadOrThrow(deviceID: "test", data: data)) { error in
            guard case EdgeProfileError.negativeValue = error else {
                return XCTFail("wanted negativeValue, got \(error)")
            }
        }
    }

    func testStrengthOutsideZeroToOneIsAnError() throws {
        let data = try json(top: "[[1, 1, 1]]", bottom: "[[1, 1, 1]]", strength: "1.5")
        XCTAssertThrowsError(try EdgeProfileStore.loadOrThrow(deviceID: "test", data: data)) { error in
            guard case EdgeProfileError.strengthOutOfRange = error else {
                return XCTFail("wanted strengthOutOfRange, got \(error)")
            }
        }
    }

    /// A file written before `strength` existed still has to decode: a missing key
    /// throws rather than taking the property's default.
    func testAMissingStrengthDefaultsToFull() throws {
        let data = try json(top: "[[1, 1, 1]]", bottom: "[[1, 1, 1]]", strength: nil)
        let loaded = try EdgeProfileStore.loadOrThrow(deviceID: "test", data: data)
        XCTAssertEqual(loaded.strength, 1)
        XCTAssertNil(loaded.measuredAt)
    }

    /// A bad file falls back rather than throwing into the build, and the fallback
    /// is the numbers that were shipping.
    func testABadFileFallsBackToTheShippedNumbers() {
        let loaded = EdgeProfileStore.load(deviceID: "not-a-phone", fallback: EdgeCompensation.shipped)
        XCTAssertEqual(loaded, EdgeCompensation.shipped)
    }

    private func json(top: String, bottom: String, strength: String? = "1.0") throws -> Data {
        let strengthLine = strength.map { "\"strength\": \($0)," } ?? ""
        return Data("""
        {
          "version": 1,
          "devices": {
            "test": { \(strengthLine) "top": \(top), "bottom": \(bottom) }
          }
        }
        """.utf8)
    }
}
