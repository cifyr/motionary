import SwiftUI

/// Draws one readout.
///
/// Split in two on purpose. The wall-clock sources hand SwiftUI a `Text` with a
/// date style and let it re-render itself, which is why they stay correct in a
/// widget that is never reloaded - the same trick the lane fonts run on. Every
/// other source is a string that was true when the widget was last built, and
/// it is only as fresh as the last reload.
struct ReadoutView: View {
    let readout: PlacedReadout
    /// Screen pixels to points, so type scales with the composition.
    let scale: CGFloat
    /// Values gathered when the widget was built. Wall-clock sources ignore it.
    let values: ReadoutValues

    var body: some View {
        content
            .font(.system(size: readout.pointSize * scale, weight: readout.isBold ? .bold : .regular))
            .foregroundStyle(Color(hex: readout.colorHex) ?? .white)
            .rotationEffect(.degrees(readout.rotation))
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var content: some View {
        switch readout.source {
        case .time:
            decorated(Text(Date(), style: .time))
        case .date:
            decorated(Text(Date(), style: .date))
        case .countdown:
            // A future date counts down and a past one counts up, which is what
            // `.relative` does on its own - so an expired countdown reads "3
            // days ago" rather than freezing at zero or going negative.
            if let target = readout.targetDate {
                decorated(Text(target, style: .relative))
            } else {
                decorated(Text("set a date"))
            }
        default:
            decorated(Text(values.text(for: readout.source) ?? placeholder))
        }
    }

    /// Shown when a source has no value yet: not blank, because a readout that
    /// draws nothing looks identical to one that was never placed.
    private var placeholder: String {
        readout.source.needsPermission ? "--" : "--"
    }

    private func decorated(_ text: Text) -> some View {
        // Concatenated rather than interpolated: interpolating a dated `Text`
        // into a string would freeze it at the moment it was built, and the
        // whole point of the wall-clock sources is that they do not.
        Text(readout.prefix) + text + Text(readout.suffix)
    }

    private var accessibilityText: String {
        let value = values.text(for: readout.source) ?? readout.source.title
        return "\(readout.prefix)\(value)\(readout.suffix)"
    }
}

/// What the readouts that cannot draw themselves were showing at build time.
///
/// Carried rather than fetched at draw time: a widget extension gets a few
/// milliseconds and no permission prompts, so anything needing HealthKit,
/// WeatherKit or EventKit has to have been read by the app already and left
/// where the extension can pick it up.
struct ReadoutValues: Codable, Equatable, Sendable {
    var battery: String?
    var steps: String?
    var weather: String?
    var calendar: String?
    /// When these were gathered, so a stale set can be shown as stale rather
    /// than as fact.
    var gatheredAt: Date?

    static let empty = ReadoutValues()

    func text(for source: PlacedReadout.Source) -> String? {
        switch source {
        case .battery: battery
        case .steps: steps
        case .weather: weather
        case .calendar: calendar
        case .time, .date, .countdown: nil
        }
    }

    /// Whether a gathered value is old enough to be worth doubting, by the
    /// slowest cadence any source asks for.
    func isStale(now: Date = Date(), tolerance: TimeInterval = 60 * 60 * 2) -> Bool {
        guard let gatheredAt else { return true }
        return now.timeIntervalSince(gatheredAt) > tolerance
    }
}
