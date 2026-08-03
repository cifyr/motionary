import CoreLocation
import EventKit
import HealthKit
import UIKit
import WeatherKit
import os

/// Reads the live values a widget cannot, and leaves them where it can.
///
/// A widget extension gets milliseconds and no permission prompts, so battery,
/// steps, weather and the calendar are read here in the app - on launch and on
/// return to the foreground - and written to the shared store the widget reads.
///
/// Each gated source is asked for only when a design on screen actually shows
/// it, so a person who never places one is never prompted. WeatherKit also
/// needs its service enabled on the App ID in the Apple Developer account - the
/// one step that is not in this repository; without it the call returns nil and
/// the widget shows its placeholder rather than crashing.
@MainActor
enum ReadoutGatherer {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "Readouts")

    /// Reads everything available and writes it, then reloads the widget so a
    /// fresh value is on screen rather than waiting for the next scheduled draw.
    static func gatherAndPublish() {
        Task { await gatherAndPublishAsync() }
    }

    private static func gatherAndPublishAsync() async {
        var values = ReadoutStore.current
        values.battery = batteryText()
        // The calendar is asked for only when a design actually shows it, so a
        // person who never places one is never prompted. The prompt itself is
        // the app's job - a widget cannot show one.
        if shows(.calendar) {
            values.calendar = await calendarText()
        }
        if shows(.steps) {
            values.steps = await stepsText()
        }
        if shows(.weather) {
            values.weather = await weatherText()
        }
        values.gatheredAt = Date()
        ReadoutStore.write(values)
        WidgetCenterBridge.reloadAll()
        logger.info("""
        gathered readouts: battery=\(values.battery ?? "nil", privacy: .public) \
        steps=\(values.steps ?? "nil", privacy: .public) \
        weather=\(values.weather ?? "nil", privacy: .public)
        """)
    }

    /// Whether the design on screen shows this source, so its permission is only
    /// ever asked for when it would actually be used.
    private static func shows(_ source: PlacedReadout.Source) -> Bool {
        PrebuiltDesign.selected()?.manifest?.placedReadouts
            .contains { $0.source == source } ?? false
    }

    /// The charge as a percentage, or nil when iOS will not report it (the
    /// simulator often returns -1, which must not reach the widget as "-100%").
    private static func batteryText() -> String? {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else { return nil }
        return "\(Int((level * 100).rounded()))%"
    }

    /// The next event's time and title, or nil when access is refused or there
    /// is nothing coming up.
    ///
    /// Read-only access, and only the events in the next day: a widget wants
    /// "what is next", and searching further is both slower and more than the
    /// question asks. The title is trimmed hard because a readout is one line.
    private static func calendarText() async -> String? {
        let store = EKEventStore()
        let granted: Bool
        do {
            granted = try await store.requestFullAccessToEvents()
        } catch {
            logger.error("calendar access failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard granted else { return nil }

        let now = Date()
        let end = now.addingTimeInterval(60 * 60 * 24)
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let next = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate >= now }
            .sorted { $0.startDate < $1.startDate }
            .first
        guard let next else { return nil }

        let time = next.startDate.formatted(date: .omitted, time: .shortened)
        let title = (next.title ?? "").prefix(24)
        return title.isEmpty ? time : "\(time)  \(title)"
    }

    /// Today's step count, grouped with thousands separators, or nil when
    /// Health is unavailable or access is refused.
    ///
    /// Read-only, one type, since midnight: a widget wants "steps today", not a
    /// history. HealthKit traps if the entitlement is missing, so the store is
    /// only touched behind `isHealthDataAvailable` and the design actually
    /// showing steps.
    private static func stepsText() async -> String? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        let store = HKHealthStore()
        let stepType = HKQuantityType(.stepCount)
        do {
            try await store.requestAuthorization(toShare: [], read: [stepType])
        } catch {
            logger.error("health access failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let startOfDay = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: Date())
        let total: Double? = await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: stepType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, statistics, error in
                if let error {
                    logger.error("step query failed: \(error.localizedDescription, privacy: .public)")
                }
                continuation.resume(returning: statistics?.sumQuantity()?.doubleValue(for: .count()))
            }
            store.execute(query)
        }
        guard let total else { return nil }
        return Self.grouped.string(from: NSNumber(value: Int(total)))
    }

    private static let grouped: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    /// The current temperature and a short condition for where the phone is, or
    /// nil when location is refused or WeatherKit is not enabled on the App ID.
    ///
    /// One location fix, not a stream: this runs on foreground, gathers once,
    /// and writes. A CLLocationManager wrapped in a continuation gives a single
    /// coordinate without a delegate object outliving the call.
    private static func weatherText() async -> String? {
        guard let location = await LocationOnce.request() else { return nil }
        do {
            let weather = try await WeatherService.shared.weather(for: location)
            let temperature = weather.currentWeather.temperature
            let degrees = Int(temperature.converted(to: .fahrenheit).value.rounded())
            let condition = weather.currentWeather.condition.description
            return "\(degrees) \(condition)"
        } catch {
            // WeatherKit not enabled on the App ID surfaces here as an error,
            // not a crash, so the widget shows its placeholder until it is.
            logger.error("weather failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// One location fix, then done.
///
/// WeatherKit needs a coordinate and nothing else here does, so this asks once
/// and resumes - rather than a manager held for a stream of updates nobody
/// reads. The delegate keeps itself alive until it answers by capturing `self`
/// in the continuation, which is the one time a retain cycle is the goal.
private final class LocationOnce: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    static func request() async -> CLLocation? {
        let once = LocationOnce()
        return await withCheckedContinuation { continuation in
            once.continuation = continuation
            once.manager.delegate = once
            once.manager.requestWhenInUseAuthorization()
            once.manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        continuation?.resume(returning: locations.first)
        continuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        continuation?.resume(returning: nil)
        continuation = nil
    }
}
