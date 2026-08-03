import Foundation
import os

/// What a tap on the widget's background does, chosen on the phone.
///
/// The tiles answer taps in their own frames; everything between them was dead
/// space. Off by default, because a Home Screen where the gaps do something
/// unexpected is worse than one where they do nothing.
///
/// Where it goes is either a browser or a page, and the two travel differently
/// - see `Destination`. A page is https, which a widget hands straight to
/// whichever browser the phone opens links with; a browser is an app, and an
/// app is opened the way every tile is, through Motionary.
enum BackgroundTap {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "BackgroundTap")

    /// Somewhere a tap can go.
    ///
    /// Two kinds, because they travel differently. A page is https, and a
    /// widget hands that straight to whatever browser the phone opens links
    /// with - no detour. A browser opened *as an app* is a custom scheme, and
    /// a widget cannot open one of those: the lab build that came before this
    /// established that on a physical iPhone, and it is why every tile goes
    /// through Motionary. So those go the same way the tiles do.
    struct Destination: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        /// The app's own scheme, for a browser. Nil for a plain page.
        let scheme: String?
        /// Where it goes: the page for a search engine, and the fallback for a
        /// browser that turns out not to be installed.
        let address: String

        var isApp: Bool { scheme != nil }
    }

    /// Opened as apps, through Motionary, because a widget cannot open a
    /// custom scheme itself. `arcmobile2://` is Arc Search's own, which the
    /// lab build used and which was verified on a physical iPhone.
    static let browsers: [Destination] = [
        Destination(id: "arc", name: "Arc Search", scheme: "arcmobile2://", address: "https://arc.net/"),
        Destination(id: "safari", name: "Safari", scheme: "x-web-search://", address: "https://www.apple.com/"),
        Destination(id: "chrome", name: "Chrome", scheme: "googlechrome://", address: "https://www.google.com"),
        Destination(id: "firefox", name: "Firefox", scheme: "firefox://", address: "https://www.mozilla.org/firefox/"),
        Destination(id: "edge", name: "Edge", scheme: "microsoft-edge://", address: "https://www.bing.com"),
        Destination(id: "bravebrowser", name: "Brave", scheme: "brave://", address: "https://search.brave.com"),
    ]

    /// Opened as pages, straight from the widget, in whichever browser the
    /// phone is set to use. iOS tells an app nothing about which engine that
    /// browser searches with, and there is no address meaning "wherever my
    /// browser opens a new tab" - so it is asked once here rather than guessed.
    static let engines: [Destination] = [
        Destination(id: "google", name: "Google", scheme: nil, address: "https://www.google.com"),
        Destination(id: "duckduckgo", name: "DuckDuckGo", scheme: nil, address: "https://duckduckgo.com"),
        Destination(id: "bing", name: "Bing", scheme: nil, address: "https://www.bing.com"),
        Destination(id: "brave", name: "Brave Search", scheme: nil, address: "https://search.brave.com"),
        Destination(id: "ecosia", name: "Ecosia", scheme: nil, address: "https://www.ecosia.org"),
        Destination(id: "startpage", name: "Startpage", scheme: nil, address: "https://www.startpage.com"),
        Destination(id: "yahoo", name: "Yahoo", scheme: nil, address: "https://search.yahoo.com"),
    ]

    static var allDestinations: [Destination] { browsers + engines }

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

    /// A destination's id, or `customValue`. Defaults to the browser itself,
    /// which is what a tap on empty space most obviously means.
    static var choice: String {
        get { defaults?.string(forKey: choiceKey) ?? browsers[0].id }
        set { defaults?.set(newValue, forKey: choiceKey) }
    }

    /// What was typed, as it was typed - so the field shows it back rather
    /// than the tidied version, which is maddening to edit.
    static var customAddress: String {
        get { defaults?.string(forKey: addressKey) ?? "" }
        set { defaults?.set(newValue, forKey: addressKey) }
    }

    static var destinationChoice: Destination? {
        allDestinations.first { $0.id == choice }
    }

    /// The address the current choice stands for.
    static var address: String {
        destinationChoice?.address ?? customAddress
    }

    /// Where a tap actually goes, or nil when nothing should answer it.
    ///
    /// A browser goes through Motionary, which walks the scheme and then the
    /// web address - so choosing Arc opens Arc, and opens arc.net in whatever
    /// browser is set if Arc is not installed. A page goes direct.
    static var widgetDestination: URL? {
        guard isEnabled else { return nil }
        guard let chosen = destinationChoice, let scheme = chosen.scheme else {
            return url(for: address)
        }
        let candidates = [URL(string: scheme), url(for: chosen.address)].compactMap { $0 }
        return candidates.isEmpty ? nil : LaunchLink.url(opening: candidates)
    }

    /// What the settings screen says it will do, which is the page rather than
    /// the route to it.
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
