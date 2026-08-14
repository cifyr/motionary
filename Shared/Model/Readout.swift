import CoreGraphics
import Foundation

/// A piece of live text placed on a design: the step count, the battery, the
/// weather, a countdown.
///
/// The animation underneath is frozen at build time and is a pure function of
/// wall-clock time, which is what lets the widget draw it without ever asking
/// for a timeline reload. A readout is the opposite: it says something about
/// right now. So each source carries its own refresh cadence rather than one
/// policy covering all of them - a countdown never needs a reload at all, and
/// asking for one on its behalf would spend a budget that the weather needs.
struct PlacedReadout: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var source: Source
    var center: CGPoint
    /// Type size in screen pixels, scaled with everything else at draw time.
    var pointSize: CGFloat = 64
    /// `#rrggbb`, matching the tile tint field.
    var colorHex: String = "#FFFFFF"
    var isBold: Bool = true
    var rotation: Double = 0
    var zIndex: Int = 0
    /// Shown before the value, e.g. "steps: ". Empty for none.
    var prefix: String = ""
    var suffix: String = ""
    /// What a countdown counts to. Ignored by every other source.
    var targetDate: Date?
    /// What a countdown is called, since the date alone does not say.
    var label: String = ""

    /// Where the text comes from.
    ///
    /// Raw values are stored in the document, so they are spelled out rather
    /// than derived - renaming a case must not silently orphan every design
    /// that used it.
    enum Source: String, Codable, CaseIterable, Identifiable, Sendable {
        case time
        case date
        case countdown
        case battery
        case steps
        case weather
        case calendar

        var id: String { rawValue }

        /// The sources a design can actually be given, which is not all of them.
        ///
        /// `steps` and `weather` are gone from the list and kept in the enum.
        /// HealthKit needs an entitlement this app does not carry and WeatherKit
        /// needs one that also has to be enabled on the App ID, so both calls
        /// failed at runtime and both readouts showed nothing at all - a placed
        /// one was decoration that looked like a feature.
        ///
        /// Removing the cases instead would have been the tidier diff and the
        /// worse idea: the raw values are stored in every document that placed
        /// one, and a document that will not decode is dropped from the library
        /// rather than reported.
        static let offered: [Source] = [.time, .date, .countdown, .battery, .calendar]

        var title: String {
            switch self {
            case .time: "Time"
            case .date: "Date"
            case .countdown: "Countdown"
            case .battery: "Battery"
            case .steps: "Steps today"
            case .weather: "Weather"
            case .calendar: "Next event"
            }
        }

        /// How often the widget must be rebuilt for this to stay true.
        ///
        /// `.wallClock` is the one that costs nothing: SwiftUI's own date
        /// styles re-render themselves from the clock, the same mechanism the
        /// lane fonts use, so those readouts stay correct in a widget that is
        /// never reloaded.
        var refresh: Refresh {
            switch self {
            case .time, .date, .countdown: .wallClock
            case .battery: .onUnlock
            case .steps, .calendar: .interval(60 * 60)
            case .weather: .interval(30 * 60)
            }
        }

        /// Whether reading it requires the person's permission first.
        var needsPermission: Bool {
            switch self {
            case .steps, .weather, .calendar: true
            case .time, .date, .countdown, .battery: false
            }
        }
    }

    enum Refresh: Equatable, Sendable {
        /// Redraws itself from the clock; needs no reload ever.
        case wallClock
        /// Cheap enough to take whenever the widget is rebuilt anyway.
        case onUnlock
        /// Wants a reload roughly this often, in seconds.
        case interval(TimeInterval)

        var seconds: TimeInterval? {
            if case .interval(let seconds) = self { return seconds }
            return nil
        }
    }

    var rect: CGRect {
        // Width is not authored: the text is as wide as it comes out, and a
        // box would either clip a long value or leave a gap after a short one.
        // The centre is the anchor, so it grows both ways.
        CGRect(
            x: center.x - pointSize * 4,
            y: center.y - pointSize / 2,
            width: pointSize * 8,
            height: pointSize
        )
    }

    init(
        id: UUID = UUID(),
        source: Source,
        center: CGPoint,
        pointSize: CGFloat = 64,
        colorHex: String = "#FFFFFF",
        isBold: Bool = true,
        rotation: Double = 0,
        zIndex: Int = 0,
        prefix: String = "",
        suffix: String = "",
        targetDate: Date? = nil,
        label: String = ""
    ) {
        self.id = id
        self.source = source
        self.center = center
        self.pointSize = pointSize
        self.colorHex = colorHex
        self.isBold = isBold
        self.rotation = rotation
        self.zIndex = zIndex
        self.prefix = prefix
        self.suffix = suffix
        self.targetDate = targetDate
        self.label = label
    }
}

extension Collection where Element == PlacedReadout {
    /// The soonest cadence anything here asks for, or nil when nothing does.
    ///
    /// This is what the timeline provider schedules on. A design of nothing but
    /// countdowns returns nil and keeps the widget's never-reload behaviour,
    /// which is the point of asking per element rather than per design.
    var soonestRefresh: TimeInterval? {
        compactMap { $0.source.refresh.seconds }.min()
    }

    /// Whether anything here needs asking the person first, which the app has
    /// to do - a widget extension cannot show a permission prompt.
    var permissionSources: [PlacedReadout.Source] {
        Set(filter { $0.source.needsPermission }.map(\.source))
            .sorted { $0.rawValue < $1.rawValue }
    }
}
