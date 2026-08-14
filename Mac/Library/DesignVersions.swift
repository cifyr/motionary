import Foundation
import os

/// One design as it stood at a moment worth being able to get back to.
struct DesignVersion: Codable, Identifiable, Equatable, Sendable {
    /// Why the snapshot was taken. Only used to word the row, but it is what
    /// makes a list of timestamps readable: "before building" is a place you
    /// remember being, and "14:32" is not.
    enum Reason: String, Codable, Sendable {
        case opened
        case edited
        case built
        case closed
        case restored

        var label: String {
            switch self {
            case .opened: "when you opened it"
            case .edited: "while editing"
            case .built: "before building"
            case .closed: "when you left"
            case .restored: "before going back"
            }
        }
    }

    var id: UUID = UUID()
    var takenAt: Date
    var reason: Reason
    var document: DesignDocument
}

/// A design's history, kept on disk beside the design itself.
///
/// The editor autosaves over `design.json` in place, so until now the only way
/// back was `UndoManager` - which lives in a window and dies with it. Quitting
/// the studio, or even just going back to the library, made the afternoon's
/// changes permanent. This is the same idea as the autosave, one step behind
/// it: every write the autosave makes is a candidate snapshot, and the ones
/// that survive are written under
///
/// ```
/// <group>/Designs/<uuid>/Versions/<stamp>-<id>.json
/// ```
///
/// Snapshots are not one-per-save. A drag mutates the document on every tick
/// and the autosave debounces at 800ms, so recording each one would bury the
/// list in near-identical rows within a minute of work. Editing snapshots are
/// spaced instead, and the moments that actually matter - opening, building,
/// leaving, and going back - are always recorded whatever the spacing says.
struct DesignVersions {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "DesignVersions")

    let store: DesignStore

    /// Shortest gap between two `.edited` snapshots. The named reasons ignore
    /// it: those are boundaries rather than samples.
    var spacing: TimeInterval = 300
    /// How many to keep per design. At the default spacing this is a working
    /// day of editing, and a design document is a few KB.
    var limit: Int = 40

    init(store: DesignStore, spacing: TimeInterval = 300, limit: Int = 40) {
        self.store = store
        self.spacing = spacing
        self.limit = limit
    }

    func folder(for id: UUID) -> URL {
        store.folder(for: id).appendingPathComponent("Versions", isDirectory: true)
    }

    // MARK: - Reading

    /// Every version of a design, newest first. A file that will not decode is
    /// skipped rather than fatal: history is a convenience, and one bad
    /// snapshot should not take the rest of it down with it.
    func list(for id: UUID) -> [DesignVersion] {
        let folder = folder(for: id)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name -> DesignVersion? in
                let url = folder.appendingPathComponent(name)
                do {
                    return try JSONDecoder().decode(DesignVersion.self, from: Data(contentsOf: url))
                } catch {
                    Self.logger.error("""
                    skipping version \(name, privacy: .public) of \(id.uuidString, privacy: .public): \
                    \(String(describing: error), privacy: .public)
                    """)
                    return nil
                }
            }
            .sorted { $0.takenAt > $1.takenAt }
    }

    // MARK: - Writing

    /// Takes a snapshot if this one is worth keeping, and says which. Nil is
    /// the ordinary answer - most saves change nothing a history should record.
    @discardableResult
    func record(
        _ document: DesignDocument,
        reason: DesignVersion.Reason,
        now: Date = Date()
    ) throws -> DesignVersion? {
        let existing = list(for: document.id)
        guard Self.shouldRecord(
            document,
            reason: reason,
            latest: existing.first,
            now: now,
            spacing: spacing
        ) else { return nil }

        let version = DesignVersion(takenAt: now, reason: reason, document: document)
        let folder = folder(for: document.id)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: DesignStore.directoryAttributes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(version).write(
            to: folder.appendingPathComponent(Self.fileName(for: version)),
            options: DesignStore.writingOptions
        )
        Self.logger.info("""
        kept \(document.id.uuidString, privacy: .public) as it was \
        \(reason.rawValue, privacy: .public) (\(existing.count + 1) versions)
        """)

        prune(id: document.id, among: [version] + existing)
        return version
    }

    /// Sortable in a directory listing, and unique per snapshot even when two
    /// land in the same second.
    static func fileName(for version: DesignVersion) -> String {
        let stamp = ISO8601DateFormatter().string(from: version.takenAt)
            .replacingOccurrences(of: ":", with: "-")
        return "\(stamp)-\(version.id.uuidString.prefix(8)).json"
    }

    /// Whether a snapshot is worth the disk.
    ///
    /// Content, not `updatedAt`: the autosave restamps on every write, so a
    /// straight `==` would call an untouched design changed every 800ms.
    static func shouldRecord(
        _ document: DesignDocument,
        reason: DesignVersion.Reason,
        latest: DesignVersion?,
        now: Date,
        spacing: TimeInterval
    ) -> Bool {
        guard let latest else { return true }
        guard !sameContent(latest.document, document) else { return false }
        guard reason == .edited else { return true }
        return now.timeIntervalSince(latest.takenAt) >= spacing
    }

    /// Two documents that describe the same design, ignoring when they were
    /// last written.
    static func sameContent(_ lhs: DesignDocument, _ rhs: DesignDocument) -> Bool {
        var left = lhs
        var right = rhs
        left.updatedAt = .distantPast
        right.updatedAt = .distantPast
        return left == right
    }

    // MARK: - Pruning

    /// Which of a design's versions to keep, newest first in, newest first out.
    ///
    /// The newest `limit - 1` plus the oldest one there is. Keeping the oldest
    /// costs a single file and is the one row that never stops being useful:
    /// it is the design before this whole stretch of work, which is what
    /// "put it back" usually means.
    static func kept(_ versions: [DesignVersion], limit: Int) -> [DesignVersion] {
        guard limit > 0 else { return [] }
        guard versions.count > limit else { return versions }
        let ordered = versions.sorted { $0.takenAt > $1.takenAt }
        guard limit > 1, let oldest = ordered.last else { return Array(ordered.prefix(limit)) }
        return Array(ordered.prefix(limit - 1)) + [oldest]
    }

    private func prune(id: UUID, among versions: [DesignVersion]) {
        let keeping = Set(Self.kept(versions, limit: limit).map(\.id))
        for version in versions where !keeping.contains(version.id) {
            let url = folder(for: id).appendingPathComponent(Self.fileName(for: version))
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                Self.logger.error("""
                could not drop old version \(url.lastPathComponent, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            }
        }
    }

    // MARK: - Restoring

    /// What a restore would produce, and what it had to leave behind.
    struct Restoration: Equatable, Sendable {
        var document: DesignDocument
        /// Pictures the snapshot placed whose files have since been deleted.
        var droppedAssets: [String] = []
        /// Clips the snapshot listed whose files have since been deleted.
        var droppedClips: [String] = []

        var isClean: Bool { droppedAssets.isEmpty && droppedClips.isEmpty }

        /// One line for the editor to show. Nil when nothing was lost.
        var note: String? {
            guard !isClean else { return nil }
            var parts: [String] = []
            if !droppedAssets.isEmpty {
                parts.append("\(droppedAssets.count) picture\(droppedAssets.count == 1 ? "" : "s")")
            }
            if !droppedClips.isEmpty {
                parts.append("\(droppedClips.count) clip\(droppedClips.count == 1 ? "" : "s")")
            }
            let total = droppedAssets.count + droppedClips.count
            return """
            \(parts.joined(separator: " and ")) in that version \
            \(total == 1 ? "has" : "have") been deleted since, so \
            \(total == 1 ? "it is" : "they are") not back.
            """
        }
    }

    /// A snapshot made safe to open.
    ///
    /// A version records what the document said, not the files it pointed at -
    /// deleting a picture removes its file straight away, so a snapshot from
    /// before the deletion would otherwise come back placing artwork that is not
    /// there. Both callbacks answer "is this file still on disk".
    ///
    /// Skins are left alone: they are removed with the design rather than one at
    /// a time, so a snapshot cannot outlive one the way it outlives a picture.
    static func reconciled(
        _ document: DesignDocument,
        assetExists: (String) -> Bool,
        clipExists: (String) -> Bool
    ) -> Restoration {
        var restored = document
        var result = Restoration(document: document)

        result.droppedAssets = document.assets.map(\.fileName).filter { !assetExists($0) }
        let missingAssets = Set(result.droppedAssets)
        restored.assets = document.assets.filter { !missingAssets.contains($0.fileName) }

        result.droppedClips = document.variants
            .filter { !clipExists($0.sourceVideoName) }
            .map(\.name)
        let missingClips = Set(document.variants.filter { !clipExists($0.sourceVideoName) }.map(\.id))
        restored.variants = document.variants.filter { !missingClips.contains($0.id) }
        // A design that leads with a clip it no longer has opens on nothing.
        if let leads = restored.defaultVariantID, missingClips.contains(leads) {
            restored.defaultVariantID = nil
        }

        result.document = restored
        return result
    }

    /// Puts a version back, keeping the state it replaced as a version of its
    /// own so that going back is itself reversible.
    func restore(_ version: DesignVersion, over current: DesignDocument) throws -> Restoration {
        try record(current, reason: .restored)

        let designID = version.document.id
        let manager = FileManager.default
        let result = Self.reconciled(
            version.document,
            assetExists: { manager.fileExists(atPath: store.assetURL(for: designID, name: $0).path) },
            clipExists: { manager.fileExists(atPath: store.variantClipURL(for: designID, name: $0).path) }
        )
        try store.save(result.document)
        Self.logger.info("""
        put \(designID.uuidString, privacy: .public) back to \(version.reason.rawValue, privacy: .public) \
        (dropped \(result.droppedAssets.count) pictures, \(result.droppedClips.count) clips)
        """)
        return result
    }
}
