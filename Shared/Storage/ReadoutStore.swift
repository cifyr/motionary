import Foundation
import os

/// The gathered readout values, written by the app and read by the widget.
///
/// The widget extension gets a few milliseconds and cannot show a permission
/// prompt, so anything behind HealthKit, WeatherKit or EventKit has to be read
/// by the app while it runs and left here. The widget only ever reads: a value
/// it cannot gather is not a value it should try to.
enum ReadoutStore {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "Readouts")
    private static let key = "readoutValues"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: DesignStore.appGroupIdentifier)
    }

    /// What the app last gathered, or empty when it never has. Empty rather
    /// than nil so the widget always has something to draw placeholders from.
    static var current: ReadoutValues {
        guard let data = defaults?.data(forKey: key) else { return .empty }
        do {
            return try JSONDecoder().decode(ReadoutValues.self, from: data)
        } catch {
            // A shape that will not decode is stale from an older build, not a
            // reason to lose the next write - logged and treated as empty.
            logger.error("could not read gathered values: \(error.localizedDescription, privacy: .public)")
            return .empty
        }
    }

    static func write(_ values: ReadoutValues) {
        do {
            let data = try JSONEncoder().encode(values)
            defaults?.set(data, forKey: key)
            logger.info("wrote gathered values")
        } catch {
            logger.error("could not write gathered values: \(error.localizedDescription, privacy: .public)")
        }
    }
}
