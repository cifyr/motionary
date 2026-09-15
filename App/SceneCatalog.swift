import Foundation
import os

enum SceneCatalogError: Error, CustomStringConvertible {
    case badResponse(status: Int)
    case emptyDownload(URL)
    case decodeFailed(underlying: Error)

    var description: String {
        switch self {
        case .badResponse(let status):
            "the scene catalogue answered \(status)"
        case .emptyDownload(let url):
            "nothing came back from \(url.lastPathComponent)"
        case .decodeFailed(let underlying):
            "the scene catalogue could not be read: \(underlying)"
        }
    }
}

/// The list of designs that can be downloaded into an installed app.
///
/// A design is data, not code - `DesignPackage` writes one and
/// `DesignDelivery.receive` takes it in - so a scene can arrive long after the
/// App Store build that is running. This is only the index and the fetch; the
/// unpacking is the same path a delivery over the cable or through Files takes.
enum SceneCatalog {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "SceneCatalog")

    static let catalogURL = URL(string: "https://vwkl9yq0e3a6cbr1.public.blob.vercel-storage.com/catalog.json")!

    /// One downloadable design.
    ///
    /// Named `Entry` rather than `Scene` because SwiftUI already has a `Scene`
    /// and this type is read inside views.
    struct Entry: Codable, Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let bytes: Int
        let published: String
        let package: URL
        let preview: URL
        /// The Home Screen as it will look, moving. Optional so a scene
        /// published before previews existed still lists with its still.
        let motion: URL?
        /// Free today for everything. A scene the app does not recognise is
        /// listed and refused rather than hidden, so an older install says
        /// something honest instead of pretending the scene does not exist.
        let access: String

        var isFree: Bool { access == "free" }

        var sizeText: String {
            ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
    }

    /// Not private so the tests can decode the exact shape the
    /// publish script writes.
    struct Document: Codable {
        let version: Int
        let scenes: [Entry]
    }

    static func fetch() async throws -> [Entry] {
        // Skips the phone's own cache only. Vercel's CDN can still answer with
        // the previous catalogue for up to sixty seconds after a publish.
        var request = URLRequest(url: catalogURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            logger.error("catalogue fetch failed with \(http.statusCode, privacy: .public)")
            throw SceneCatalogError.badResponse(status: http.statusCode)
        }
        do {
            let document = try JSONDecoder().decode(Document.self, from: data)
            logger.info("catalogue listed \(document.scenes.count, privacy: .public) scenes")
            return document.scenes
        } catch {
            logger.error("catalogue decode failed: \(String(describing: error), privacy: .public)")
            throw SceneCatalogError.decodeFailed(underlying: error)
        }
    }

    /// A scene's moving preview on disk, fetched the first time it is asked for.
    ///
    /// `LoopingVideoView` plays local files only, and a gallery that fetched
    /// every card again whenever it scrolled back into view would spend the
    /// data twice. Named after the remote file, whose path carries the time it
    /// was published, so a republished preview is a new name rather than a
    /// cache hit on the old one.
    static func cachedMotion(for entry: Entry) async throws -> URL? {
        guard let remote = entry.motion else { return nil }
        let folder = try FileManager.default
            .url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ScenePreviews", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let local = folder.appendingPathComponent(remote.lastPathComponent)
        if FileManager.default.fileExists(atPath: local.path) { return local }

        let (temporary, response) = try await URLSession.shared.download(from: remote)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            logger.error("preview fetch failed with \(http.statusCode, privacy: .public) for \(remote.absoluteString, privacy: .public)")
            throw SceneCatalogError.badResponse(status: http.statusCode)
        }
        try? FileManager.default.removeItem(at: local)
        try FileManager.default.moveItem(at: temporary, to: local)
        logger.info("cached preview for \(entry.name, privacy: .public)")
        return local
    }

    /// Downloads a package to a temporary file and reports progress as it goes.
    ///
    /// A download task rather than iterating `AsyncBytes`: appending one byte
    /// at a time took 25s for an 8.8MB package that curl fetches in 1.6s.
    static func download(
        _ entry: Entry,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        logger.info("downloading \(entry.name, privacy: .public), \(entry.bytes, privacy: .public) bytes expected")
        let observer = ProgressObserver(report: progress)
        let (temporary, response) = try await URLSession.shared.download(from: entry.package, delegate: observer)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            logger.error("package fetch failed with \(http.statusCode, privacy: .public) for \(entry.package.absoluteString, privacy: .public)")
            throw SceneCatalogError.badResponse(status: http.statusCode)
        }
        progress(1)

        let size = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? Int) ?? 0
        guard size > 0 else { throw SceneCatalogError.emptyDownload(entry.package) }

        // Moved straight away: the system is free to reclaim the file it
        // handed back once this call has returned it.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(entry.id).\(DesignPackage.fileExtension)")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        logger.info("downloaded \(entry.name, privacy: .public), \(size, privacy: .public) bytes")
        return destination
    }

    /// Forwards the download task's own `Progress`, which the system keeps
    /// current without this code touching a single byte.
    private final class ProgressObserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let report: @Sendable (Double) -> Void
        private var observation: NSKeyValueObservation?

        init(report: @escaping @Sendable (Double) -> Void) {
            self.report = report
        }

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            observation = task.progress.observe(\.fractionCompleted) { [report] progress, _ in
                report(progress.fractionCompleted)
            }
        }
    }
}
