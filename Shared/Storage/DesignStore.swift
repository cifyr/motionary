import Foundation
import os

enum DesignStoreError: Error, CustomStringConvertible {
    case appGroupUnavailable(identifier: String)
    case designNotFound(UUID)
    case manifestMissing(designID: UUID, path: String)
    case decodeFailed(path: String, underlying: Error)
    case assetImportFailed(source: URL, name: String, underlying: Error)

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
        case .assetImportFailed(let source, let name, let underlying):
            "storage: could not copy \(source.path) in as \(name): \(underlying)"
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
    /// `none`, not merely `untilFirstUserAuthentication`. A widget is refreshed
    /// in lock states this code cannot observe, and every stricter class has
    /// some state where the file is not there. The content is a wallpaper and
    /// generated fonts — there is nothing here worth protecting, and the cost
    /// of guessing wrong is a widget that silently draws the placeholder.
    ///
    /// It also fixes the diagnostics. A locked render could not write its
    /// report either, so the only reports ever seen came from unlocked renders
    /// and always said ok, while the picture on screen came from a failed one.
    /// Data protection is an iOS notion. On the Mac, where the studio builds
    /// designs, there is nothing to relax rather than something to get wrong.
#if os(iOS)
    static let writingOptions: Data.WritingOptions = [.atomic, .noFileProtection]

    /// Computed rather than stored: `[FileAttributeKey: Any]` is not Sendable,
    /// so a static instance of it cannot be shared across concurrency domains.
    static var directoryAttributes: [FileAttributeKey: Any] {
        [.protectionKey: FileProtectionType.none]
    }
#else
    static let writingOptions: Data.WritingOptions = [.atomic]
    static var directoryAttributes: [FileAttributeKey: Any] { [:] }
#endif

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

    /// A chosen background, kept with the design so reopening it finds the
    /// same picture even if the original file has moved.
    func backgroundURL(for id: UUID, name: String) -> URL {
        folder(for: id).appendingPathComponent(name)
    }

    /// Placed decoration lives with the design rather than in the shared skin
    /// library, so exporting or deleting a design takes its pictures with it.
    /// The library stays the right home for artwork reused across designs.
    func assetsFolder(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("Assets", isDirectory: true)
    }

    func assetURL(for id: UUID, name: String) -> URL {
        assetsFolder(for: id).appendingPathComponent(name)
    }

    /// Copies a picture into the design, returning the filename to store on the
    /// `PlacedAsset`. Names collide constantly -- every second export is called
    /// `image.png` -- so a repeat gets a numbered suffix rather than silently
    /// overwriting the asset already placed.
    @discardableResult
    func importAsset(_ source: URL, for id: UUID) throws -> String {
        let folder = assetsFolder(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var name = ext.isEmpty ? base : "\(base).\(ext)"
        var attempt = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = ext.isEmpty ? "\(base)-\(attempt)" : "\(base)-\(attempt).\(ext)"
            attempt += 1
        }

        do {
            try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(name))
        } catch {
            throw DesignStoreError.assetImportFailed(source: source, name: name, underlying: error)
        }
        return name
    }

    /// Removes an asset's file. A missing file is not an error: the document is
    /// the record of what exists, and a half-deleted design must still open.
    func removeAsset(named name: String, for id: UUID) {
        let url = assetURL(for: id, name: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Self.logger.error(
                "could not remove asset \(name, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
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

    /// `touch: false` writes without restamping `updatedAt`.
    ///
    /// Moving a design between stores is not editing it. Migration used to go
    /// through the touching path, which restamped every design it carried over
    /// to the same second -- and since the library sorts on `updatedAt`, that
    /// replaced the real order of work with the order of one batch job.
    func save(_ design: DesignDocument, touch: Bool = true) throws {
        try createFolder(for: design.id)
        var updated = design
        if touch { updated.updatedAt = Date() }
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

    /// Copies a design under a new id, so a layout can be varied without
    /// risking the one that already works.
    ///
    /// Only the inputs are copied -- the clip, the background and the placed
    /// pictures. Fonts, the manifest and the wallpaper are build outputs that
    /// belong to the id that produced them, and carrying them over would leave
    /// the copy claiming a build it does not have.
    ///
    /// The copy is never starred, whatever the original was: duplicating a
    /// design should not quietly add 29MB to the next install.
    func duplicate(_ design: DesignDocument, named name: String? = nil) throws -> DesignDocument {
        var copy = design
        copy.id = UUID()
        copy.name = Self.uniqueName(
            name ?? Self.copyName(for: design.name),
            among: loadAll().map(\.name)
        )
        copy.createdAt = Date()
        copy.isStarred = false

        try createFolder(for: copy.id)

        let source = folder(for: design.id)
        let destination = folder(for: copy.id)
        var carried: [String] = [design.sourceVideoName]
        if let background = design.backgroundName { carried.append(background) }

        for name in carried {
            let from = source.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            try FileManager.default.copyItem(at: from, to: destination.appendingPathComponent(name))
        }

        if FileManager.default.fileExists(atPath: assetsFolder(for: design.id).path) {
            try FileManager.default.copyItem(
                at: assetsFolder(for: design.id),
                to: assetsFolder(for: copy.id)
            )
        }

        try save(copy)
        Self.logger.info(
            "duplicated \(design.id.uuidString, privacy: .public) as \(copy.id.uuidString, privacy: .public)"
        )
        return copy
    }

    /// Whether a filename carries no information about its contents.
    ///
    /// A downloaded clip is often named by digest - browsers, Slack and Discord
    /// all do it - and naming a design after one gives a row that says nothing.
    /// Dashes are stripped first so a bare UUID counts too.
    static func looksLikeADigest(_ name: String) -> Bool {
        let stripped = name.replacingOccurrences(of: "-", with: "")
        guard stripped.count >= 16 else { return false }
        return stripped.allSatisfy(\.isHexDigit)
    }

    /// Fixed rather than localised: a design name is stored, so it should not
    /// read differently on a machine with different settings.
    private static let dateNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM HH:mm"
        return formatter
    }()

    /// What to call a design made from `fileName`.
    ///
    /// The filename when it says something, the date when it does not. "Clip 30
    /// Jul 12:57" is not a good name either, but it places the design in the
    /// afternoon it came from, which a digest does not.
    static func suggestedName(for fileName: String, created: Date = Date()) -> String {
        let trimmed = fileName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !looksLikeADigest(trimmed) else {
            return "Clip \(dateNameFormatter.string(from: created))"
        }
        return trimmed
    }

    /// A name not already in the library.
    ///
    /// A design is named after the file it was made from, and the same file
    /// gets dropped over and over while a layout is worked out. Without this
    /// the library fills with rows that are identical in every visible
    /// respect, which is exactly what happened: nineteen designs all called
    /// after one downloaded GIF.
    static func uniqueName(_ base: String, among existing: [String]) -> String {
        guard existing.contains(base) else { return base }
        var attempt = 2
        while existing.contains("\(base) \(attempt)") { attempt += 1 }
        return "\(base) \(attempt)"
    }

    /// "Board" -> "Board copy" -> "Board copy 2", so duplicating twice does not
    /// produce two designs with the same name.
    static func copyName(for name: String) -> String {
        guard name.hasSuffix(" copy") || name.contains(" copy ") else { return "\(name) copy" }
        let parts = name.split(separator: " ")
        if let last = parts.last, let number = Int(last) {
            return parts.dropLast().joined(separator: " ") + " \(number + 1)"
        }
        return "\(name) 2"
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
