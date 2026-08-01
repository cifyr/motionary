import Foundation
import SwiftUI
import os

/// How a design file that arrived turned out, in the words the screen uses.
///
/// Apart from the receiving so the outcome can be checked without an app group,
/// a share sheet or a screen to read it off.
enum DesignImportOutcome: Equatable {
    case imported(name: String)
    case failed(reason: String)

    var message: String {
        switch self {
        case .imported(let name):
            // Said plainly rather than left to be discovered: a design has to be
            // compiled into the widget extension to draw at all, so one that
            // arrives as a file cannot join the scenes on this screen.
            "Imported \(name). Designs are built on the Mac, so it will not show here until it is built in and installed."
        case .failed(let reason):
            reason
        }
    }
}

/// Takes in a design file the phone was handed.
///
/// Files, AirDrop and Mail all arrive the same way - a file URL through
/// `onOpenURL` - which is the same door a widget tap comes through, so the two
/// have to be told apart before either is acted on.
@MainActor
final class DesignImporter: ObservableObject {
    private nonisolated static let logger = Logger(subsystem: "com.caden.Motionary", category: "Import")

    /// What to say about the file that last arrived, whichever way it went. The
    /// home screen shows it: an import that reports nothing is indistinguishable
    /// from one that never happened.
    @Published var lastMessage: String?

    /// Whether a URL is a file to take in rather than a tap to forward on.
    func claims(_ url: URL) -> Bool { url.isFileURL }

    func receive(_ url: URL) {
        Self.logger.info("received \(url.lastPathComponent, privacy: .public)")
        // A file the system left in place belongs to whichever sandbox lent it,
        // and reading it without asking first simply returns nothing.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let store: DesignStore
        do {
            store = try DesignStore()
        } catch {
            Self.logger.error("no store to import into: \(String(describing: error), privacy: .public)")
            lastMessage = "Could not open \(url.lastPathComponent): \(error)"
            return
        }

        let outcome = Self.take(url, into: store)
        lastMessage = outcome.message
        if case .imported = outcome { discardInboxCopy(of: url) }
    }

    nonisolated static func take(_ url: URL, into store: DesignStore) -> DesignImportOutcome {
        do {
            let design = try DesignArchive.restore(from: url, into: store)
            logger.info(
                "imported \(design.name, privacy: .public) as \(design.id.uuidString, privacy: .public), \(design.tiles.count) tiles"
            )
            return .imported(name: design.name)
        } catch {
            // Named down to the underlying failure: "could not import" alone
            // does not separate a file that is not a design from one whose clip
            // did not survive the send.
            logger.error(
                "could not import \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return .failed(reason: "Could not import \(url.lastPathComponent): \(error)")
        }
    }

    /// A file mailed or AirDropped in is copied into the app's own inbox, and
    /// that copy is ours to clear away; one opened in place is not.
    private func discardInboxCopy(of url: URL) {
        guard url.pathComponents.contains("Inbox") else { return }
        do {
            try FileManager.default.removeItem(at: url)
            Self.logger.debug("cleared the inbox copy of \(url.lastPathComponent, privacy: .public)")
        } catch {
            Self.logger.error(
                "could not clear the inbox copy of \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }
}
