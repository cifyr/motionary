import CoreGraphics
import Foundation
import os

/// Widget sizes learned from the system rather than tabulated.
///
/// The built-in table was calibrated on an iOS 26.5 simulator, where the large
/// family is 349x365pt. An iOS 27 phone hands the same family 359x548pt. Any
/// table is a guess about someone else's device and OS, so the widget records
/// the size it was actually given and the app prefers that from then on.
struct ObservedGeometry: Codable, Equatable, Sendable {
    /// Point sizes keyed by `WidgetSizeOption.rawValue`.
    var sizes: [String: CGSize] = [:]
    var updatedAt = Date()

    func size(for option: WidgetSizeOption) -> CGSize? {
        guard let points = sizes[option.rawValue], points.width > 1, points.height > 1 else {
            return nil
        }
        return points
    }
}

enum ObservedGeometryStore {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "ObservedGeometry")
    private static let filename = "observed-geometry.json"

    private static func url(in store: DesignStore) -> URL {
        store.root.deletingLastPathComponent().appendingPathComponent(filename)
    }

    static func load() -> ObservedGeometry {
        guard let store = try? DesignStore(),
              let data = try? Data(contentsOf: url(in: store)),
              let observed = try? JSONDecoder().decode(ObservedGeometry.self, from: data)
        else { return ObservedGeometry() }
        return observed
    }

    /// Records a family's real point size. Writes only on a change, since the
    /// widget calls this on every render.
    static func record(size: CGSize, for option: WidgetSizeOption) {
        guard size.width > 1, size.height > 1, let store = try? DesignStore() else { return }

        var observed = load()
        if let existing = observed.size(for: option),
           abs(existing.width - size.width) < 0.5, abs(existing.height - size.height) < 0.5 {
            return
        }
        observed.sizes[option.rawValue] = size
        observed.updatedAt = Date()

        do {
            try JSONEncoder().encode(observed).write(to: url(in: store), options: .atomic)
            logger.info("""
            learned \(option.rawValue, privacy: .public) = \
            \(Int(size.width))x\(Int(size.height))pt
            """)
        } catch {
            logger.error("could not record geometry: \(String(describing: error), privacy: .public)")
        }
    }
}
