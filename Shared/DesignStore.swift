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

    let root: URL

    init(appGroupIdentifier: String = DesignStore.appGroupIdentifier) throws {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
        else {
            throw DesignStoreError.appGroupUnavailable(identifier: appGroupIdentifier)
        }
        let designsRoot = container.appendingPathComponent("Designs", isDirectory: true)
        try FileManager.default.createDirectory(at: designsRoot, withIntermediateDirectories: true)
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
        try FileManager.default.createDirectory(at: fontsFolder(for: id), withIntermediateDirectories: true)
    }

    func save(_ design: DesignDocument) throws {
        try createFolder(for: design.id)
        var updated = design
        updated.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(updated)
        try data.write(to: designURL(for: design.id), options: .atomic)
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
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.moveItem(to: destination.appendingPathComponent(id.uuidString), from: source)
        Self.logger.info("archived design \(id.uuidString, privacy: .public) to \(destination.path, privacy: .public)")
    }

    // MARK: - Manifests

    func save(_ manifest: BuildManifest) throws {
        try createFolder(for: manifest.designID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL(for: manifest.designID), options: .atomic)
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
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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
