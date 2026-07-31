import SwiftUI
import UIKit
import os

/// Forwards a widget tap to the destination app.
///
/// Widgets open their containing app first because a `Link` straight to a
/// third-party scheme is unreliable from an extension. The short delay lets the
/// app's scene finish activating before the handoff, otherwise the second
/// `openURL` is dropped while the window is still coming up.
@MainActor
final class ExternalAppRouter: ObservableObject {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "Router")
    private static let settleDelay = Duration.milliseconds(220)

    @Published var lastFailure: String?

    func handle(_ url: URL) {
        guard let target = LaunchLink.target(from: url) else {
            Self.logger.debug("ignoring unrelated url \(url.absoluteString, privacy: .public)")
            return
        }

        switch target {
        case .app(let appID):
            guard let app = AppCatalog.app(id: appID) else {
                lastFailure = "No catalog entry for \"\(appID)\"."
                Self.logger.error("no catalog entry for \(appID, privacy: .public)")
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: Self.settleDelay)
                await self?.open(app)
            }
        case .url(let destination):
            // An app the catalogue does not know, addressed by its own URL.
            Task { [weak self] in
                try? await Task.sleep(for: Self.settleDelay)
                await self?.open(candidates: [destination], named: destination.scheme ?? "that app")
            }
        }
    }

    /// Tapped inside the app, where the scene is already active and no settling
    /// delay is needed.
    func launch(appID: String) {
        guard let app = AppCatalog.app(id: appID) else {
            lastFailure = "No catalog entry for \"\(appID)\"."
            return
        }
        Task { [weak self] in await self?.open(app) }
    }

    private func open(_ app: CatalogApp) async {
        await open(candidates: app.launchCandidates, named: app.name)
    }

    /// Tries each route in turn. Shared by catalogue apps and custom targets,
    /// because "it may not be installed" is the same answer either way.
    private func open(candidates: [URL], named name: String) async {
        guard !candidates.isEmpty else {
            lastFailure = "\(name) has no launch route."
            return
        }

        for candidate in candidates {
            let opened = await UIApplication.shared.open(candidate, options: [:])
            if opened {
                Self.logger.info("opened \(name, privacy: .public) via \(candidate.scheme ?? "?", privacy: .public)")
                return
            }
            Self.logger.debug("\(candidate.absoluteString, privacy: .public) did not open; trying next candidate")
        }

        lastFailure = "\(name) could not be opened. It may not be installed."
        Self.logger.error("all \(candidates.count) launch candidates failed for \(name, privacy: .public)")
    }

    /// A tile tapped inside the app, custom target included.
    func launch(tile: PlacedTile) {
        if let custom = tile.custom {
            Task { [weak self] in
                await self?.open(candidates: custom.launchCandidates, named: custom.name)
            }
            return
        }
        launch(appID: tile.appID)
    }
}
