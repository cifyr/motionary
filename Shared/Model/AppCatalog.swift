import SwiftUI

/// A launchable destination a user can drop onto their composition.
///
/// iOS does not expose other apps' icons to third parties, so each entry ships
/// an SF Symbol and a brand tint instead of the real artwork.
struct CatalogApp: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let symbol: String
    let tint: Color
    /// Primary custom URL scheme. Nil entries are web-only destinations.
    let scheme: String?
    /// Used when the app is not installed, or when no scheme exists.
    let webFallback: String?
    let category: Category

    enum Category: String, CaseIterable, Identifiable, Sendable {
        case system = "Apple"
        case social = "Social"
        case media = "Media"
        case productivity = "Productivity"
        case games = "Games"
        case travel = "Travel"

        var id: String { rawValue }
    }

    var launchCandidates: [URL] {
        [scheme, webFallback].compactMap { $0 }.compactMap(URL.init(string:))
    }

    /// Whether tapping this tile can open anything. Some Apple apps expose no
    /// URL scheme at all, so a tile for one is decoration whatever it looks
    /// like - the editor says so rather than letting it be found out later.
    var canLaunch: Bool { !launchCandidates.isEmpty }
}

enum AppCatalog {
    static let all: [CatalogApp] = [
        // Apple destinations. These schemes are the documented or long-stable
        // system routes; `app-settings:` opens this app's own Settings page.
        CatalogApp(id: "settings", name: "Settings", symbol: "gearshape.fill", tint: .gray,
                   scheme: "app-settings:", webFallback: nil, category: .system),
        CatalogApp(id: "calendar", name: "Calendar", symbol: "calendar", tint: .red,
                   scheme: "calshow://", webFallback: nil, category: .system),
        // No scheme, deliberately. Apple publishes none for Clock, and
        // clock-alarm:// - which this used - is not one of theirs and does not
        // open on current iOS. Claiming a route that cannot work turns a tap
        // into "Clock could not be opened, it may not be installed", which
        // sends you looking for a problem on the phone.
        CatalogApp(id: "clock", name: "Clock", symbol: "clock.fill", tint: .orange,
                   scheme: nil, webFallback: nil, category: .system),
        CatalogApp(id: "camera", name: "Camera", symbol: "camera.fill", tint: .gray,
                   scheme: "camera://", webFallback: nil, category: .system),
        CatalogApp(id: "photos", name: "Photos", symbol: "photo.on.rectangle.angled", tint: .pink,
                   scheme: "photos-redirect://", webFallback: nil, category: .system),
        CatalogApp(id: "mail", name: "Mail", symbol: "envelope.fill", tint: .blue,
                   scheme: "message://", webFallback: nil, category: .system),
        CatalogApp(id: "messages", name: "Messages", symbol: "message.fill", tint: .green,
                   scheme: "sms:", webFallback: nil, category: .system),
        CatalogApp(id: "phone", name: "Phone", symbol: "phone.fill", tint: .green,
                   scheme: "tel:", webFallback: nil, category: .system),
        CatalogApp(id: "facetime", name: "FaceTime", symbol: "video.fill", tint: .green,
                   scheme: "facetime://", webFallback: nil, category: .system),
        CatalogApp(id: "notes", name: "Notes", symbol: "note.text", tint: .yellow,
                   scheme: "mobilenotes://", webFallback: nil, category: .system),
        CatalogApp(id: "reminders", name: "Reminders", symbol: "checklist", tint: .orange,
                   scheme: "x-apple-reminderkit://", webFallback: nil, category: .system),
        CatalogApp(id: "health", name: "Health", symbol: "heart.fill", tint: .pink,
                   scheme: "x-apple-health://", webFallback: nil, category: .system),
        CatalogApp(id: "wallet", name: "Wallet", symbol: "creditcard.fill", tint: .black,
                   scheme: "shoebox://", webFallback: nil, category: .system),
        CatalogApp(id: "appstore", name: "App Store", symbol: "bag.fill", tint: .blue,
                   scheme: "itms-apps://", webFallback: nil, category: .system),
        CatalogApp(id: "applemusic", name: "Apple Music", symbol: "music.note", tint: .red,
                   scheme: "music://", webFallback: nil, category: .media),
        CatalogApp(id: "podcasts", name: "Podcasts", symbol: "mic.fill", tint: .purple,
                   scheme: "podcasts://", webFallback: nil, category: .media),
        CatalogApp(id: "maps", name: "Apple Maps", symbol: "map.fill", tint: .green,
                   scheme: "maps://", webFallback: nil, category: .travel),
        CatalogApp(id: "safari", name: "Safari", symbol: "safari.fill", tint: .blue,
                   scheme: nil, webFallback: "https://www.apple.com/", category: .productivity),

        // Third-party schemes. These are the public routes each vendor
        // documents or has registered for years; a web fallback covers the
        // "app not installed" case.
        CatalogApp(id: "spotify", name: "Spotify", symbol: "waveform", tint: .green,
                   scheme: "spotify://", webFallback: "https://open.spotify.com/", category: .media),
        CatalogApp(id: "youtube", name: "YouTube", symbol: "play.rectangle.fill", tint: .red,
                   scheme: "youtube://", webFallback: "https://www.youtube.com/", category: .media),
        CatalogApp(id: "netflix", name: "Netflix", symbol: "tv.fill", tint: .red,
                   scheme: "nflx://", webFallback: "https://www.netflix.com/", category: .media),
        CatalogApp(id: "twitch", name: "Twitch", symbol: "gamecontroller.fill", tint: .purple,
                   scheme: "twitch://", webFallback: "https://www.twitch.tv/", category: .media),
        CatalogApp(id: "soundcloud", name: "SoundCloud", symbol: "cloud.fill", tint: .orange,
                   scheme: "soundcloud://", webFallback: "https://soundcloud.com/", category: .media),
        CatalogApp(id: "instagram", name: "Instagram", symbol: "camera.circle.fill", tint: .purple,
                   scheme: "instagram://", webFallback: "https://www.instagram.com/", category: .social),
        CatalogApp(id: "tiktok", name: "TikTok", symbol: "music.note.tv.fill", tint: .black,
                   scheme: "snssdk1233://", webFallback: "https://www.tiktok.com/", category: .social),
        CatalogApp(id: "x", name: "X", symbol: "at", tint: .black,
                   scheme: "twitter://", webFallback: "https://x.com/", category: .social),
        CatalogApp(id: "reddit", name: "Reddit", symbol: "bubble.left.and.bubble.right.fill", tint: .orange,
                   scheme: "reddit://", webFallback: "https://www.reddit.com/", category: .social),
        CatalogApp(id: "discord", name: "Discord", symbol: "bubble.left.fill", tint: .indigo,
                   scheme: "discord://", webFallback: "https://discord.com/app", category: .social),
        CatalogApp(id: "snapchat", name: "Snapchat", symbol: "bolt.fill", tint: .yellow,
                   scheme: "snapchat://", webFallback: "https://www.snapchat.com/", category: .social),
        CatalogApp(id: "whatsapp", name: "WhatsApp", symbol: "phone.bubble.fill", tint: .green,
                   scheme: "whatsapp://", webFallback: "https://web.whatsapp.com/", category: .social),
        CatalogApp(id: "facebook", name: "Facebook", symbol: "person.2.fill", tint: .blue,
                   scheme: "fb://", webFallback: "https://www.facebook.com/", category: .social),
        CatalogApp(id: "pinterest", name: "Pinterest", symbol: "pin.fill", tint: .red,
                   scheme: "pinterest://", webFallback: "https://www.pinterest.com/", category: .social),
        CatalogApp(id: "linkedin", name: "LinkedIn", symbol: "briefcase.fill", tint: .blue,
                   scheme: "linkedin://", webFallback: "https://www.linkedin.com/", category: .social),
        CatalogApp(id: "slack", name: "Slack", symbol: "number.square.fill", tint: .purple,
                   scheme: "slack://", webFallback: "https://slack.com/", category: .productivity),
        CatalogApp(id: "gmail", name: "Gmail", symbol: "envelope.badge.fill", tint: .red,
                   scheme: "googlegmail://", webFallback: "https://mail.google.com/", category: .productivity),
        CatalogApp(id: "chrome", name: "Chrome", symbol: "globe", tint: .blue,
                   scheme: "googlechrome://", webFallback: "https://www.google.com/", category: .productivity),
        CatalogApp(id: "gcal", name: "Google Calendar", symbol: "calendar.badge.clock", tint: .blue,
                   scheme: "comgooglecalendar://", webFallback: "https://calendar.google.com/", category: .productivity),
        CatalogApp(id: "drive", name: "Google Drive", symbol: "folder.fill", tint: .yellow,
                   scheme: "googledrive://", webFallback: "https://drive.google.com/", category: .productivity),
        CatalogApp(id: "notion", name: "Notion", symbol: "doc.text.fill", tint: .black,
                   scheme: "notion://", webFallback: "https://www.notion.so/", category: .productivity),
        CatalogApp(id: "chatgpt", name: "ChatGPT", symbol: "sparkles", tint: .teal,
                   scheme: "chatgpt://", webFallback: "https://chatgpt.com/", category: .productivity),
        CatalogApp(id: "claude", name: "Claude", symbol: "asterisk", tint: .orange,
                   scheme: nil, webFallback: "https://claude.ai/", category: .productivity),
        CatalogApp(id: "gmaps", name: "Google Maps", symbol: "location.fill", tint: .green,
                   scheme: "comgooglemaps://", webFallback: "https://maps.google.com/", category: .travel),
        CatalogApp(id: "uber", name: "Uber", symbol: "car.fill", tint: .black,
                   scheme: "uber://", webFallback: "https://m.uber.com/", category: .travel),
        CatalogApp(id: "lyft", name: "Lyft", symbol: "car.circle.fill", tint: .pink,
                   scheme: "lyft://", webFallback: "https://www.lyft.com/", category: .travel),
        CatalogApp(id: "airbnb", name: "Airbnb", symbol: "house.fill", tint: .pink,
                   scheme: "airbnb://", webFallback: "https://www.airbnb.com/", category: .travel),
        CatalogApp(id: "strava", name: "Strava", symbol: "figure.run", tint: .orange,
                   scheme: "strava://", webFallback: "https://www.strava.com/", category: .travel),
        CatalogApp(id: "roblox", name: "Roblox", symbol: "cube.fill", tint: .red,
                   scheme: "roblox://", webFallback: "https://www.roblox.com/", category: .games),
        CatalogApp(id: "clashroyale", name: "Clash Royale", symbol: "crown.fill", tint: .blue,
                   scheme: "clashroyale://", webFallback: "https://link.clashroyale.com/en/", category: .games),
        CatalogApp(id: "minecraft", name: "Minecraft", symbol: "square.grid.3x3.fill", tint: .green,
                   scheme: "minecraft://", webFallback: "https://www.minecraft.net/", category: .games),
        CatalogApp(id: "steam", name: "Steam", symbol: "gamecontroller", tint: .indigo,
                   scheme: "steam://", webFallback: "https://store.steampowered.com/", category: .games),

        // The rest of a typical Home Screen. Added because an icon pack draws
        // these and a tile that cannot name its app cannot launch it - the
        // artwork imports either way, but only a catalogue entry opens.
        //
        // Weather and Calculator publish no scheme, like Clock: Apple has
        // never shipped one, and claiming a route that cannot work turns a tap
        // into "could not be opened", which sends you looking for a problem on
        // the phone.
        CatalogApp(id: "weather", name: "Weather", symbol: "cloud.sun.fill", tint: .blue,
                   scheme: nil, webFallback: nil, category: .system),
        CatalogApp(id: "calculator", name: "Calculator", symbol: "plusminus", tint: .gray,
                   scheme: nil, webFallback: nil, category: .system),
        CatalogApp(id: "messenger", name: "Messenger", symbol: "message.circle.fill", tint: .blue,
                   scheme: "fb-messenger://", webFallback: "https://www.messenger.com/", category: .social),
        CatalogApp(id: "telegram", name: "Telegram", symbol: "paperplane.fill", tint: .cyan,
                   scheme: "tg://", webFallback: "https://web.telegram.org/", category: .social),
        CatalogApp(id: "outlook", name: "Outlook", symbol: "envelope.fill", tint: .blue,
                   scheme: "ms-outlook://", webFallback: "https://outlook.office.com/", category: .productivity),
        CatalogApp(id: "teams", name: "Microsoft Teams", symbol: "person.2.badge.gearshape.fill", tint: .indigo,
                   scheme: "msteams://", webFallback: "https://teams.microsoft.com/", category: .productivity),
        CatalogApp(id: "zoom", name: "Zoom", symbol: "video.fill", tint: .blue,
                   scheme: "zoomus://", webFallback: "https://zoom.us/", category: .productivity),
        CatalogApp(id: "amazon", name: "Amazon", symbol: "cart.fill", tint: .orange,
                   scheme: "com.amazon.mobile.shopping://",
                   webFallback: "https://www.amazon.com/", category: .productivity),
    ]

    private static let index: [String: CatalogApp] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) }
    )

    static func app(id: String) -> CatalogApp? { index[id] }

    static func apps(in category: CatalogApp.Category) -> [CatalogApp] {
        all.filter { $0.category == category }
    }
}
