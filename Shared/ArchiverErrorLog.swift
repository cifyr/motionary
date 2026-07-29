import Foundation
import OSLog
import os

/// Recovers WidgetKit's own archiving diagnostics out of the extension's log and
/// puts them where the app can show them.
///
/// This exists because the project has been reading the wrong error.
/// `badTimelineData` is a `Reload.Reason` in ChronoCore - the note `chronod`
/// makes when it gives up on what the extension returned and asks again. The
/// real failure is a `WidgetArchiver.ArchivingError`, and one of its four cases,
/// `failedToEncode`, carries the list of offending types outright:
///
///     The body of the Widget entries' view contains the following unsupported
///     types: {...}
///
/// while `imageTooLarge` carries the actual and maximum sizes. Both are printed
/// by the extension's own process every time this fails. Bisecting one font
/// route at a time was recovering, by experiment, a list the system had already
/// named.
///
/// TIMING, and it is a real limitation: archiving happens after the timeline
/// closure returns, so a capture taken while building a view sees the *previous*
/// archive attempt, not the current one. The log therefore lags by one reload.
/// That is still strictly better than a reload reason, because the lagged line
/// names the type; it just means two reloads are needed to read the result of a
/// change.
enum ArchiverErrorLog {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "ArchiverErrors")

    /// The subsystems WidgetKit archives under. `com.apple.widgetkit` carries
    /// the ArchivingError descriptions; `chronod` carries the reload reason that
    /// this whole type exists to stop relying on, kept so the two can be read
    /// side by side and the causal order confirmed.
    private static let subsystems = ["com.apple.widgetkit", "com.apple.chrono", "com.apple.chronod"]

    /// Substrings from `ArchivingError`'s and `ValidationError`'s own
    /// `errorDescription` strings, verbatim as they appear in WidgetKit.
    static let signatures = [
        "unsupported types",
        "beyond the maximum",
        "missing Widget metrics",
        "Failed to lookup Widget bundle",
        "failedToEncode",
        "failedToEncodeView",
        "imageTooLarge",
        "Archiving",
        "archive",
    ]

    /// True when a log line is one of WidgetKit's archiving complaints.
    static func isArchivingDiagnostic(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return signatures.contains { lowered.contains($0.lowercased()) }
    }

    /// Pulls this process's archiving diagnostics since `since` seconds ago.
    ///
    /// Reads only the current process, which is what an app extension is allowed
    /// to do without the diagnostic entitlement - and is also exactly the right
    /// scope, because the archiver runs in-process alongside the view code.
    static func recent(within seconds: TimeInterval = 120) -> [String] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let start = store.position(date: Date().addingTimeInterval(-seconds))
            return try store.getEntries(at: start)
                .compactMap { $0 as? OSLogEntryLog }
                .filter { entry in
                    (subsystems.contains(entry.subsystem) || entry.subsystem.isEmpty)
                        && isArchivingDiagnostic(entry.composedMessage)
                }
                .map { "\($0.subsystem.isEmpty ? "-" : $0.subsystem)  \($0.composedMessage)" }
        } catch {
            // Expected on any OS that tightens extension access to its own log;
            // named rather than swallowed so it is not mistaken for "no errors".
            logger.error("could not read the archiving log: \(String(describing: error), privacy: .public)")
            return ["log unreadable: \(error)"]
        }
    }

    /// Copies whatever the archiver last complained about into the render log the
    /// app already displays.
    @discardableResult
    static func capture(within seconds: TimeInterval = 120) -> [String] {
        let lines = recent(within: seconds)
        guard !lines.isEmpty else { return [] }
        for line in lines.suffix(6) {
            WidgetRenderLog.append("arch \(line)")
        }
        return lines
    }
}
