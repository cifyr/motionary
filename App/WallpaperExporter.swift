import Photos
import SwiftUI
import WidgetKit
import os

enum ExportError: Error, CustomStringConvertible {
    case wallpaperMissing(path: String)
    case photosDenied(status: PHAuthorizationStatus)
    case saveFailed(underlying: Error)

    var description: String {
        switch self {
        case .wallpaperMissing(let path):
            "export: no wallpaper at \(path); build the design first"
        case .photosDenied(let status):
            "export: Photos access was not granted (status \(status.rawValue)). Enable it in Settings > Motionary."
        case .saveFailed(let underlying):
            "export: saving to Photos failed: \(underlying)"
        }
    }
}

enum WallpaperExporter {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "Export")

    static func saveToPhotos(url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ExportError.wallpaperMissing(path: url.path)
        }

        // Add-only access is all this needs, and it is the least the user has
        // to grant.
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ExportError.photosDenied(status: status)
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil)
            }
            logger.info("saved wallpaper \(url.lastPathComponent, privacy: .public) to Photos")
        } catch {
            throw ExportError.saveFailed(underlying: error)
        }
    }
}

/// WidgetCenter is unavailable to the extension itself, so the app owns the
/// refresh call after a rebuild.
enum WidgetCenterBridge {
    static func reloadAll() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
