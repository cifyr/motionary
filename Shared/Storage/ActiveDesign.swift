import Foundation
import os

/// Which design is "yours" right now.
///
/// One selection drives both the app's Home Screen imitation and the widget, so
/// there is no second place to choose from and no way for the two to disagree.
enum ActiveDesign {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "ActiveDesign")
    private static let key = "activeDesignID"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: DesignStore.appGroupIdentifier)
    }

    static var identifier: UUID? {
        get { defaults?.string(forKey: key).flatMap(UUID.init(uuidString:)) }
        set {
            defaults?.set(newValue?.uuidString, forKey: key)
            logger.info("active design set to \(newValue?.uuidString ?? "none", privacy: .public)")
        }
    }

    /// The design to show, falling back to the most recently edited built one
    /// so a fresh install is never blank and a deleted selection self-heals.
    ///
    /// The selection is a parameter rather than read inside, so the fallback
    /// rules can be tested without a shared-defaults suite.
    static func resolve(in store: DesignStore, selection: UUID?) -> DesignDocument? {
        let designs = store.loadAll()
        let built = designs.filter {
            FileManager.default.fileExists(atPath: store.manifestURL(for: $0.id).path)
        }
        if let selection, let match = built.first(where: { $0.id == selection }) {
            return match
        }
        return built.first ?? designs.first
    }

    static func resolve(in store: DesignStore) -> DesignDocument? {
        resolve(in: store, selection: identifier)
    }
}
