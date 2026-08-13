import Foundation
import os

/// Copies the widget's reports into the app's own container, where a script on
/// a Mac can read them off the phone.
///
/// Everything the extension records lands in the app group, and the app group
/// is the one container `devicectl` will not read out of: asking for a file
/// beside `Library` comes back as "file paths cannot contain '..'", which is
/// not what is wrong. So a device experiment used to end with somebody holding
/// the phone and reading a screen, and that is the reason several of the
/// findings in `docs/` are one sample of one render.
///
/// The app's own `Documents` is readable, so the reports are copied there on
/// every launch. Nothing here is the source of truth - it is a copy, taken at a
/// known moment, of what the extension last wrote.
enum DeviceReportMirror {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "ReportMirror")
    static let folderName = "reports"

    /// Named rather than globbed: the app group also holds the designs, and
    /// copying those into the app container on every launch would duplicate
    /// hundreds of megabytes.
    static let reports = [
        "widget-renders.log",
        "widget-status.json",
        "mask-lab.txt",
        "font-lab.txt",
    ]

    static var destination: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(folderName, isDirectory: true)
    }

    @discardableResult
    static func mirror() -> [String] {
        guard let store = try? DesignStore(), let destination else {
            logger.error("no app group or no documents directory to mirror into")
            return []
        }
        let source = store.root.deletingLastPathComponent()
        var copied: [String] = []
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            logger.error("could not make \(folderName, privacy: .public): \(String(describing: error), privacy: .public)")
            return []
        }

        for name in reports {
            let from = source.appendingPathComponent(name)
            let to = destination.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            do {
                // Replaced rather than skipped: a report from a previous run
                // reads exactly like a fresh one, and that is the mistake this
                // whole file exists to stop somebody making.
                if FileManager.default.fileExists(atPath: to.path) {
                    try FileManager.default.removeItem(at: to)
                }
                try FileManager.default.copyItem(at: from, to: to)
                copied.append(name)
            } catch {
                logger.error("could not mirror \(name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        logger.info("mirrored \(copied.count) of \(reports.count) reports")
        return copied
    }
}
