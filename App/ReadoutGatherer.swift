import EventKit
import UIKit
import os

/// Reads the live values a widget cannot, and leaves them where it can.
///
/// A widget extension gets milliseconds and no permission prompts, so battery,
/// steps, weather and the calendar are read here in the app - on launch and on
/// return to the foreground - and written to the shared store the widget reads.
///
/// Battery works today. The three permission-gated sources are stubbed with the
/// exact capability each needs, because turning them on touches the Apple
/// Developer account and the app's entitlements, not only this file - so they
/// are wired to a clear boundary rather than half-built behind a flag.
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
        if selectedDesignUsesCalendar {
            values.calendar = await calendarText()
        }
        values.gatheredAt = Date()
        // Steps and weather are left as whatever was last written - nil until
        // their capabilities are enabled - so turning one on later fills its
        // field without disturbing the others.
        ReadoutStore.write(values)
        WidgetCenterBridge.reloadAll()
        logger.info("gathered readouts: battery=\(values.battery ?? "nil", privacy: .public)")
    }

    /// Whether the design on screen shows a calendar readout, so permission is
    /// only ever asked for when it would actually be used.
    private static var selectedDesignUsesCalendar: Bool {
        PrebuiltDesign.selected()?.manifest?.placedReadouts
            .contains { $0.source == .calendar } ?? false
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

    // Steps: needs the HealthKit capability on the target and an
    // NSHealthShareUsageDescription in Info.plist, then an HKHealthStore query
    // for HKQuantityTypeIdentifier.stepCount over today. Left out until the
    // entitlement is added, because a HealthKit call without it traps.
    //
    // Weather: needs the WeatherKit capability, which is enabled on the App ID
    // in the Apple Developer account, plus a CoreLocation permission. Then
    // WeatherKit's `Weather(for:)` gives current temperature and condition.
}
