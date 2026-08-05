import Foundation

/// When a design should pick another clip from its bundled set.
///
/// The choice itself is derived from wall-clock time rather than saved at the
/// moment it changes. That keeps the app and its widget in agreement even
/// though WidgetKit can suspend either one between frames.
enum RandomClipSchedule: String, Codable, CaseIterable, Sendable {
    case off
    case loopBoundary
    case hour

    var title: String {
        switch self {
        case .off: "Off"
        case .loopBoundary: "At a shared loop boundary"
        case .hour: "On the hour"
        }
    }

    var detail: String {
        switch self {
        case .off: "Choose a clip yourself."
        case .loopBoundary: "Each change waits for a frame where every bundled clip is at its own loop boundary."
        case .hour: "The same random clip plays for the whole clock hour."
        }
    }
}
