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
        var values = ReadoutStore.current
        values.battery = batteryText()
        values.gatheredAt = Date()
        // Steps, weather and calendar are left as whatever was last written -
        // nil until their gatherers exist - so enabling one later fills its
        // field without disturbing the others.
        ReadoutStore.write(values)
        WidgetCenterBridge.reloadAll()
        logger.info("gathered readouts: battery=\(values.battery ?? "nil", privacy: .public)")
    }

    /// The charge as a percentage, or nil when iOS will not report it (the
    /// simulator often returns -1, which must not reach the widget as "-100%").
    private static func batteryText() -> String? {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else { return nil }
        return "\(Int((level * 100).rounded()))%"
    }

    // Steps: needs the HealthKit capability on the target and an
    // NSHealthShareUsageDescription in Info.plist, then an HKHealthStore query
    // for HKQuantityTypeIdentifier.stepCount over today. Left out until the
    // entitlement is added, because a HealthKit call without it traps.
    //
    // Weather: needs the WeatherKit capability, which is enabled on the App ID
    // in the Apple Developer account, plus a CoreLocation permission. Then
    // WeatherKit's `Weather(for:)` gives current temperature and condition.
    //
    // Calendar: needs an NSCalendarsUsageDescription and EventKit authorisation,
    // then the next EKEvent after now. The lightest of the three - no account
    // change, only the usage string and a prompt.
}
