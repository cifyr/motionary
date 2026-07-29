import CoreGraphics
import Foundation
import os

enum IconifyError: Error, CustomStringConvertible {
    case badURL(String)
    case requestFailed(url: String, underlying: Error)
    case badStatus(url: String, code: Int)
    case decodeFailed(url: String, underlying: Error)
    case iconMissing(IconAsset)

    var description: String {
        switch self {
        case .badURL(let text):
            "iconify: could not build a URL from \"\(text)\""
        case .requestFailed(let url, let underlying):
            "iconify: request to \(url) failed: \(underlying)"
        case .badStatus(let url, let code):
            "iconify: \(url) returned HTTP \(code)"
        case .decodeFailed(let url, let underlying):
            "iconify: could not decode the response from \(url): \(underlying)"
        case .iconMissing(let icon):
            "iconify: the API returned no body for \(icon.id)"
        }
    }
}

/// Client for the public Iconify API.
///
/// Chosen because it needs no account or key, exposes one search across ~200
/// open-source sets, and includes Simple Icons, which is what app shortcuts
/// actually want. Licences vary per set, so the picker shows them.
struct IconifyService {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "Iconify")
    private static let host = "https://api.iconify.design"

    struct Collection: Decodable, Sendable {
        let name: String
        let total: Int?
        let license: License?
        let author: Author?

        struct License: Decodable, Sendable {
            let title: String?
            let spdx: String?
            let url: String?
        }

        struct Author: Decodable, Sendable {
            let name: String?
            let url: String?
        }
    }

    private struct SearchResponse: Decodable {
        let icons: [String]
    }

    private struct IconSetResponse: Decodable {
        let width: Int?
        let height: Int?
        let icons: [String: Icon]

        struct Icon: Decodable {
            let body: String
            let width: Int?
            let height: Int?
        }
    }

    /// One icon's drawable content plus the box it is drawn in.
    struct IconBody: Sendable {
        let body: String
        let viewBox: CGRect
    }

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func search(query: String, limit: Int = 96) async throws -> [IconAsset] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var components = URLComponents(string: "\(Self.host)/search")
        components?.queryItems = [
            URLQueryItem(name: "query", value: trimmed),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        let response: SearchResponse = try await get(components?.url)
        let refs = response.icons.compactMap(IconAsset.init(id:))
        Self.logger.info("search \"\(trimmed, privacy: .public)\" returned \(refs.count) icons")
        return refs
    }

    func collections(prefixes: [String]) async throws -> [String: Collection] {
        guard !prefixes.isEmpty else { return [:] }
        var components = URLComponents(string: "\(Self.host)/collections")
        components?.queryItems = [URLQueryItem(name: "prefixes", value: prefixes.joined(separator: ","))]
        return try await get(components?.url)
    }

    /// Fetches several icons from one set in a single request, which is how the
    /// picker avoids one round trip per grid cell.
    func bodies(prefix: String, names: [String]) async throws -> [String: IconBody] {
        guard !names.isEmpty else { return [:] }
        var components = URLComponents(string: "\(Self.host)/\(prefix).json")
        components?.queryItems = [URLQueryItem(name: "icons", value: names.joined(separator: ","))]
        let response: IconSetResponse = try await get(components?.url)

        let defaultWidth = response.width ?? 24
        let defaultHeight = response.height ?? 24
        return response.icons.reduce(into: [:]) { result, entry in
            result[entry.key] = IconBody(
                body: entry.value.body,
                viewBox: CGRect(
                    x: 0, y: 0,
                    width: CGFloat(entry.value.width ?? defaultWidth),
                    height: CGFloat(entry.value.height ?? defaultHeight)
                )
            )
        }
    }

    func body(for icon: IconAsset) async throws -> IconBody {
        guard let found = try await bodies(prefix: icon.prefix, names: [icon.name])[icon.name] else {
            throw IconifyError.iconMissing(icon)
        }
        return found
    }

    private func get<T: Decodable>(_ url: URL?) async throws -> T {
        guard let url else { throw IconifyError.badURL(Self.host) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw IconifyError.requestFailed(url: url.absoluteString, underlying: error)
        }
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw IconifyError.badStatus(url: url.absoluteString, code: http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw IconifyError.decodeFailed(url: url.absoluteString, underlying: error)
        }
    }
}
