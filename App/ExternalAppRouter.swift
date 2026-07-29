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
        guard let appID = LaunchLink.appID(from: url) else {
            Self.logger.debug("ignoring unrelated url \(url.absoluteString, privacy: .public)")
            return
        }
        guard let app = AppCatalog.app(id: appID) else {
            lastFailure = "No catalog entry for \"\(appID)\"."
            Self.logger.error("no catalog entry for \(appID, privacy: .public)")
            return
        }

        Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            await self?.open(app)
        }
    }

    private func open(_ app: CatalogApp) async {
        let candidates = app.launchCandidates
        guard !candidates.isEmpty else {
            lastFailure = "\(app.name) has no launch route."
            return
        }

        for candidate in candidates {
            let opened = await UIApplication.shared.open(candidate, options: [:])
            if opened {
                Self.logger.info("opened \(app.name, privacy: .public) via \(candidate.scheme ?? "?", privacy: .public)")
                return
            }
            Self.logger.debug("\(candidate.absoluteString, privacy: .public) did not open; trying next candidate")
        }

        lastFailure = "\(app.name) could not be opened. It may not be installed."
        Self.logger.error("all \(candidates.count) launch candidates failed for \(app.name, privacy: .public)")
    }
}
