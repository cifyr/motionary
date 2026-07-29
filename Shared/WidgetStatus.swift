import Foundation
import os

/// What the widget saw the last time it tried to render.
///
/// A widget that fails can only report through a rectangle a few centimetres
/// wide, in text the system may dim or redact. Writing the outcome to the
/// shared container instead lets the app show it at a readable size, and gives
/// a record even when the widget never draws at all.
struct WidgetStatus: Codable, Equatable, Sendable {
    var recordedAt: Date
    var family: String
    var outcome: String
    var designName: String?
    var designSize: String?
    var laneFontResolved: Bool
    var blinkFontResolved: Bool
    var lanesRequested: Int
    var lanesResolvable: Int
    var failures: [String]

    var succeeded: Bool { outcome == "ok" }

    var summary: String {
        if succeeded {
            "Rendered \"\(designName ?? "?")\" in the \(family) widget. "
                + "Fonts \(lanesResolvable)/\(lanesRequested), mask \(blinkFontResolved ? "ok" : "MISSING")."
        } else {
            outcome
        }
    }
}

enum WidgetStatusLog {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "WidgetStatus")
    private static let filename = "widget-status.json"

    private static func url(in store: DesignStore) -> URL {
        store.root.deletingLastPathComponent().appendingPathComponent(filename)
    }

    static func write(_ status: WidgetStatus) {
        guard let store = try? DesignStore() else {
            logger.error("cannot record widget status: the shared container is unavailable")
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(status).write(to: url(in: store), options: .atomic)
        } catch {
            logger.error("could not record widget status: \(String(describing: error), privacy: .public)")
        }
    }

    static func read(store: DesignStore) -> WidgetStatus? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url(in: store)) else { return nil }
        return try? decoder.decode(WidgetStatus.self, from: data)
    }
}
