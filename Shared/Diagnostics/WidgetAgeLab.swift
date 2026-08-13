import Foundation
import os

/// Pretends the archived widget has been sitting on the Home Screen for a
/// while, so what it looks like after an hour can be photographed now.
///
/// The provider returns one entry with `policy: .never`, so the view is
/// archived once and then plays from a reference date baked in at that moment.
/// Everything about the animation is a function of how far the timer has
/// counted since - and the timer's string gets *wider* as it counts, at ten
/// minutes ("9:59" to "10:00") and again at an hour. The glyph carrying the
/// frame is positioned by a fixed offset into that string, so a width change
/// moves it.
///
/// That failure cannot be found by rendering and looking, because a render is
/// always seconds old. This adds the elapsed time the waiting would have
/// produced. Multiples of the 30-second cycle only: anything else changes which
/// frame is due as well, and then a difference in the picture says nothing
/// about the format.
enum WidgetAgeLab {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "WidgetAgeLab")
    private static let key = "widgetAgeSeconds"

    static var seconds: TimeInterval {
        get { UserDefaults(suiteName: DesignStore.appGroupIdentifier)?.double(forKey: key) ?? 0 }
        set {
            UserDefaults(suiteName: DesignStore.appGroupIdentifier)?.set(newValue, forKey: key)
            logger.info("widget aged by \(newValue)s")
        }
    }

    /// `-MotionaryWidgetAge <seconds>`, rounded down to a whole cycle.
    static func launchOverride(in arguments: [String]) -> TimeInterval? {
        guard let flag = arguments.firstIndex(of: "-MotionaryWidgetAge"),
              arguments.index(after: flag) < arguments.endIndex,
              let asked = TimeInterval(arguments[arguments.index(after: flag)])
        else { return nil }
        return max(0, (asked / TimerFontSpec.cycleDuration).rounded(.down) * TimerFontSpec.cycleDuration)
    }
}
