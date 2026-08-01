import Foundation
import os

/// What a tap on the widget's background does, chosen on the phone.
///
/// The tiles answer taps in their own frames; everything between them was dead
/// space. Off by default, because a Home Screen where the gaps do something
/// unexpected is worse than one where they do nothing.
///
/// The destination has to be a web address rather than an app's scheme. A
/// widget's `Link` to `https://` is handed straight to the default browser,
/// which is the point - an app's own scheme from an extension is unreliable,
/// which is why every tile goes through Motionary first and why this cannot.
enum BackgroundTap {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "BackgroundTap")

    static let defaultAddress = "https://www.google.com"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: DesignStore.appGroupIdentifier)
    }

    private static let enabledKey = "backgroundTapEnabled"
    private static let addressKey = "backgroundTapAddress"

    static var isEnabled: Bool {
        get { defaults?.bool(forKey: enabledKey) ?? false }
        set {
            defaults?.set(newValue, forKey: enabledKey)
            logger.info("background tap \(newValue ? "on" : "off", privacy: .public)")
        }
    }

    /// What was typed, as it was typed - so the field shows it back rather than
    /// the tidied version, which is maddening to edit.
    static var address: String {
        get { defaults?.string(forKey: addressKey) ?? defaultAddress }
        set { defaults?.set(newValue, forKey: addressKey) }
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
    /// accepting one here would make a tile that silently does nothing.
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
