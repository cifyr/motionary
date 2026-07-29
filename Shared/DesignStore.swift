import Foundation
import os

enum DesignStoreError: Error, CustomStringConvertible {
    case appGroupUnavailable(identifier: String)
    case designNotFound(UUID)
    case manifestMissing(designID: UUID, path: String)
    case decodeFailed(path: String, underlying: Error)

    var description: String {
        switch self {
        case .appGroupUnavailable(let identifier):
            "storage: app group \(identifier) is not available; check the entitlement on both targets"
        case .designNotFound(let id):
            "storage: no design folder for \(id.uuidString)"
        case .manifestMissing(let id, let path):
            "storage: design \(id.uuidString) has no build manifest at \(path); generate it first"
        case .decodeFailed(let path, let underlying):
            "storage: could not decode \(path): \(underlying)"
        }
    }
}

/// Shared on-disk layout for designs, used by both the app and the extension.
///
/// ```
/// <group>/Designs/<uuid>/design.json
///                       /source.mov
///                       /wallpaper.png
///                       /manifest.json
///                       /Fonts/<family><lane>-Regular.ttf
/// ```
struct DesignStore {
    static let appGroupIdentifier = "group.com.caden.Motionary"

    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "DesignStore")

    /// The widget is refreshed while the phone is locked, so everything the
    /// extension reads has to survive that.
    ///
    /// A file written under the `complete` protection class simply is not
    /// there for a locked-device render. That is exactly how this behaved: the
    /// widget found no design and drew the placeholder, then a later render
    /// with the phone in hand read the same design and reported ok. The report
    /// and the picture disagreed because they were made under different locks.
    static let writingOptions: Data.WritingOptions = [
        .atomic, .completeFileProtectionUntilFirstUserAuthentication,
    ]

    /// Computed rather than stored: `[FileAttributeKey: Any]` is not Sendable,
    /// so a static instance of it cannot be shared across concurrency domains.
    static var directoryAttributes: [FileAttributeKey: Any] {
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    }

    /// Relaxes protection on everything already written, so designs built
    /// before this start working without needing a rebuild.
    @discardableResult
    static func relaxProtection(at url: URL) -> Int {
        let manager = FileManager.default
        let nested = manager.enumerator(at: url, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        var changed = 0
        for target in [url] + nested {
            do {
                try manager.setAttributes(directoryAttributes, ofItemAtPath: target.path)
                changed += 1
            } catch {
                logger.error("could not relax \(target.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return changed
    }

    let root: URL

    /// Roots the store at an arbitrary directory. Tests use this; the app and
    /// the extension always go through the app group.
    init(containerURL: URL) throws {
        let designsRoot = containerURL.appendingPathComponent("Designs", isDirectory: true)
        try FileManager.default.createDirectory(at: designsRoot, withIntermediateDirectories: true, attributes: Self.directoryAttributes)
        root = designsRoot
    }

    init(appGroupIdentifier: String = DesignStore.appGroupIdentifier) throws {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
        else {
            throw DesignStoreError.appGroupUnavailable(identifier: appGroupIdentifier)
        }
        let designsRoot = container.appendingPathComponent("Designs", isDirectory: true)
        try FileManager.default.createDirectory(at: designsRoot, withIntermediateDirectories: true, attributes: Self.directoryAttributes)
        root = designsRoot
        Self.logger.debug("design store rooted at \(designsRoot.path, privacy: .public)")
    }

    func folder(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func fontsFolder(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("Fonts", isDirectory: true)
    }

    func designURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("design.json")
    }

    func manifestURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("manifest.json")
    }

    func wallpaperURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("wallpaper.png")
    }

    /// The wallpaper cropped to the widget's frame, so the extension decodes
    /// only the pixels it draws.
    func widgetBackdropURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("widget-backdrop.jpg")
    }

    func previewVideoURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("preview.mp4")
    }

    func sourceVideoURL(for design: DesignDocument) -> URL {
        folder(for: design.id).appendingPathComponent(design.sourceVideoName)
    }

    func fontURL(for id: UUID, familyBase: String, lane: Int) -> URL {
        fontsFolder(for: id)
            .appendingPathComponent("\(LaneFontBuilder.postScriptName(family: familyBase, lane: lane)).ttf")
    }

    // MARK: - Designs

    func createFolder(for id: UUID) throws {
        try FileManager.default.createDirectory(at: fontsFolder(for: id), withIntermediateDirectories: true, attributes: Self.directoryAttributes)
    }

    func save(_ design: DesignDocument) throws {
        try createFolder(for: design.id)
        var updated = design
        updated.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(updated)
        try data.write(to: designURL(for: design.id), options: Self.writingOptions)
        Self.logger.info("saved design \(design.id.uuidString, privacy: .public) (\(data.count) bytes)")
    }

    func load(id: UUID) throws -> DesignDocument {
        let url = designURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DesignStoreError.designNotFound(id)
        }
        return try decode(DesignDocument.self, from: url)
    }

    func loadAll() -> [DesignDocument] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return ids.compactMap { name -> DesignDocument? in
            guard let id = UUID(uuidString: name) else { return nil }
            do {
                return try load(id: id)
            } catch {
                // A half-written design should not take the whole library down.
                Self.logger.error("skipping design \(name, privacy: .public): \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Designs are whole directories of generated artefacts, so removal moves
    /// them into a timestamped trash folder instead of deleting outright.
    func archive(id: UUID) throws {
        let source = folder(for: id)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw DesignStoreError.designNotFound(id)
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let destination = root
            .deletingLastPathComponent()
            .appendingPathComponent("Archive", isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: Self.directoryAttributes)
        try FileManager.default.moveItem(to: destination.appendingPathComponent(id.uuidString), from: source)
        Self.logger.info("archived design \(id.uuidString, privacy: .public) to \(destination.path, privacy: .public)")
    }

    // MARK: - Manifests

    func save(_ manifest: BuildManifest) throws {
        try createFolder(for: manifest.designID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL(for: manifest.designID), options: Self.writingOptions)
    }

    func loadManifest(id: UUID) throws -> BuildManifest {
        let url = manifestURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DesignStoreError.manifestMissing(designID: id, path: url.path)
        }
        return try decode(BuildManifest.self, from: url)
    }

    /// Clears a design's font folder before a rebuild so lane files from a
    /// larger previous smoothness setting cannot linger and be registered.
    func clearFonts(for id: UUID) throws {
        let folder = fontsFolder(for: id)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: Self.directoryAttributes)
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(contentsOf: url))
        } catch {
            throw DesignStoreError.decodeFailed(path: url.path, underlying: error)
        }
    }
}

private extension FileManager {
    /// `moveItem` fails if the destination exists; a rebuilt archive slot is
    /// not worth failing an archive over.
    func moveItem(to destination: URL, from source: URL) throws {
        if fileExists(atPath: destination.path) {
            try removeItem(at: destination)
        }
        try moveItem(at: source, to: destination)
    }
}
