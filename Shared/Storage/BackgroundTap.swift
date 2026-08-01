import Foundation
import os

/// What a tap on the widget's background does, chosen on the phone.
///
/// The tiles answer taps in their own frames; everything between them was dead
/// space. Off by default, because a Home Screen where the gaps do something
/// unexpected is worse than one where they do nothing.
///
/// Where it goes is a web address, and that is not a limitation so much as the
/// whole mechanism: a widget hands `https` straight to whatever browser the
/// phone is set to open links with. Arc, Chrome, Safari - it is the system's
/// choice, not this app's, and the same tap gets it without going through
/// Motionary first. An app's own scheme from an extension is unreliable, which
/// is why every tile does go through Motionary and why this cannot.
enum BackgroundTap {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "BackgroundTap")

    /// A search engine to land on.
    ///
    /// iOS tells an app nothing about which engine the browser is set to, and
    /// there is no address that means "wherever my browser opens a new tab" -
    /// so it is asked once here rather than guessed at every tap.
    struct Engine: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let address: String
    }

    static let engines: [Engine] = [
        Engine(id: "google", name: "Google", address: "https://www.google.com"),
        Engine(id: "duckduckgo", name: "DuckDuckGo", address: "https://duckduckgo.com"),
        Engine(id: "bing", name: "Bing", address: "https://www.bing.com"),
        Engine(id: "brave", name: "Brave Search", address: "https://search.brave.com"),
        Engine(id: "ecosia", name: "Ecosia", address: "https://www.ecosia.org"),
        Engine(id: "startpage", name: "Startpage", address: "https://www.startpage.com"),
        Engine(id: "yahoo", name: "Yahoo", address: "https://search.yahoo.com"),
    ]

    /// Stored value meaning "the address typed by hand" rather than an engine.
    static let customValue = "-custom-"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: DesignStore.appGroupIdentifier)
    }

    private static let enabledKey = "backgroundTapEnabled"
    private static let choiceKey = "backgroundTapChoice"
    private static let addressKey = "backgroundTapAddress"

    static var isEnabled: Bool {
        get { defaults?.bool(forKey: enabledKey) ?? false }
        set {
            defaults?.set(newValue, forKey: enabledKey)
            logger.info("background tap \(newValue ? "on" : "off", privacy: .public)")
        }
    }

    /// An engine's id, or `customValue`.
    static var choice: String {
        get { defaults?.string(forKey: choiceKey) ?? engines[0].id }
        set { defaults?.set(newValue, forKey: choiceKey) }
    }

    /// What was typed, as it was typed - so the field shows it back rather
    /// than the tidied version, which is maddening to edit.
    static var customAddress: String {
        get { defaults?.string(forKey: addressKey) ?? "" }
        set { defaults?.set(newValue, forKey: addressKey) }
    }

    static var engine: Engine? {
        engines.first { $0.id == choice }
    }

    /// The address the current choice stands for, tidied or not.
    static var address: String {
        engine?.address ?? customAddress
    }

    /// Where a tap actually goes, or nil when nothing should answer it.
    static var destination: URL? {
        guard isEnabled else { return nil }
        return url(for: address)
    }

    /// A web address from what somebody typed.
    ///
    /// People type "bbc.co.uk", and a URL without a scheme is not one the
    /// system will open. Anything that is not http or https is refused rather
    /// than passed on: a widget cannot reliably open an app's own scheme, so
    /// accepting one here would make a tap that silently does nothing - which
    /// looks exactly like a gap that was meant to be dead.
    static func url(for text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Any scheme at all, not just "://" - a schemeless test would prefix
        // `mailto:someone@example.com` into a perfectly valid https URL whose
        // host is "mailto", and the refusal below would never see it.
        let hasScheme = trimmed.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil
        let withScheme = hasScheme ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }
}
