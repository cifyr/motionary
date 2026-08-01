import XCTest

/// The channel between the app that can read HealthKit/WeatherKit/EventKit and
/// the widget that cannot. A value that will not decode must not lose the next
/// write, and battery must never reach the widget as a negative percentage.
final class ReadoutStoreTests: XCTestCase {
    func testValuesSurviveEncoding() throws {
        var values = ReadoutValues.empty
        values.battery = "87%"
        values.steps = "8,432"
        values.gatheredAt = Date(timeIntervalSince1970: 1_800_000_000)
        let data = try JSONEncoder().encode(values)
        XCTAssertEqual(try JSONDecoder().decode(ReadoutValues.self, from: data), values)
    }

    /// A shape from an older build should read as empty, not throw and not take
    /// the next write down with it.
    func testAnUndecodableShapeReadsAsEmpty() throws {
        let older = try JSONDecoder().decode(
            ReadoutValues.self,
            from: Data(#"{"battery":"87%"}"#.utf8)
        )
        XCTAssertEqual(older.battery, "87%")
        XCTAssertNil(older.steps)
    }
}
