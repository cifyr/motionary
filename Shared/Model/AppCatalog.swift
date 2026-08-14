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
    /// Schemes to try when the first one does not open.
    ///
    /// Apple publishes no list of the schemes its own apps answer, and the
    /// community ones disagree and go stale between releases - `calc://` is
    /// documented everywhere and stopped working around iOS 16. The router
    /// tries every candidate in turn and only reports failure when all of them
    /// refuse, so a second spelling costs nothing and is the difference
    /// between a tile that works and one that does nothing.
    var alternates: [String] = []
    /// Whether one of these routes has been *seen* to open the app, as opposed
    /// to being the spelling everybody publishes. The two are not the same
    /// thing, and the difference is a tile that does nothing.
    ///
    /// Only a phone can settle this, and only for the apps it has installed.
    /// A simulator refuses every scheme whose app is not registered in its
    /// LaunchServices, which is indistinguishable from a scheme that does not
    /// exist: a fresh simulator has neither Clock nor Calculator nor Notes nor
    /// Books nor Music nor Podcasts registered, so all of them "refuse"
    /// everything and prove nothing at all.
    ///
    /// False is the honest default. `ExternalAppRouter` writes each attempt
    /// into the pullable report log, so firing `motionary://open?url=...` at a
    /// real phone is what turns one of these true.
    var isVerified: Bool = false
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
        // The web address last: it always opens something, so anything after
        // it would never be reached.
        ([scheme] + alternates.map { Optional($0) } + [webFallback])
            .compactMap { $0 }
            .compactMap(URL.init(string:))
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
        // Four spellings, none of them Apple's - it publishes none. Measured
        // against them all: the lab build that came before this tried clock:,
        // clock-alarm:, clock-worldclock:, clock-timer: and clock-stopwatch:
        // on a physical iPhone running iOS 27 and every one was rejected. They
        // are listed anyway because the router walks its candidates and stops
        // at the first that opens, so they cost a tap nothing and may answer
        // on some other release. Nothing here is a promise that Clock opens.
        CatalogApp(id: "clock", name: "Clock", symbol: "clock.fill", tint: .orange,
                   scheme: "clock-alarm://", webFallback: nil,
                   alternates: ["clock-worldclock://", "clock-timer://", "clock-sleep-alarm://"], category: .system),
        CatalogApp(id: "camera", name: "Camera", symbol: "camera.fill", tint: .gray,
                   scheme: "camera://", webFallback: nil, category: .system),
        CatalogApp(id: "photos", name: "Photos", symbol: "photo.on.rectangle.angled", tint: .pink,
                   scheme: "photos-redirect://", webFallback: nil, category: .system),
        CatalogApp(id: "mail", name: "Mail", symbol: "envelope.fill", tint: .blue,
                   scheme: "message://", webFallback: nil,
                   alternates: ["mailto:"], category: .system),
        CatalogApp(id: "messages", name: "Messages", symbol: "message.fill", tint: .green,
                   scheme: "messages://", webFallback: nil,
                   alternates: ["sms:"], category: .system),
        CatalogApp(id: "phone", name: "Phone", symbol: "phone.fill", tint: .green,
                   scheme: "mobilephone://", webFallback: nil,
                   alternates: ["tel:"], category: .system),
        CatalogApp(id: "facetime", name: "FaceTime", symbol: "video.fill", tint: .green,
                   scheme: "facetime://", webFallback: nil,
                   alternates: ["facetime-prompt://"], category: .system),
        CatalogApp(id: "notes", name: "Notes", symbol: "note.text", tint: .yellow,
                   scheme: "mobilenotes://", webFallback: nil, category: .system),
        CatalogApp(id: "reminders", name: "Reminders", symbol: "checklist", tint: .orange,
                   scheme: "x-apple-reminderkit://", webFallback: nil,
                   alternates: ["x-apple-reminder://"], category: .system),
        CatalogApp(id: "health", name: "Health", symbol: "heart.fill", tint: .pink,
                   scheme: "x-apple-health://", webFallback: nil, category: .system),
        CatalogApp(id: "wallet", name: "Wallet", symbol: "creditcard.fill", tint: .black,
                   scheme: "shoebox://", webFallback: nil, category: .system),
        CatalogApp(id: "appstore", name: "App Store", symbol: "bag.fill", tint: .blue,
                   scheme: "itms-apps://", webFallback: "https://apps.apple.com/",
                   alternates: ["itms-ui://"], category: .system),
        CatalogApp(id: "applemusic", name: "Apple Music", symbol: "music.note", tint: .red,
                   scheme: "music://", webFallback: "https://music.apple.com/",
                   alternates: ["musics://"], category: .media),
        CatalogApp(id: "podcasts", name: "Podcasts", symbol: "mic.fill", tint: .purple,
                   scheme: "podcasts://", webFallback: nil,
                   alternates: ["pcast://"], category: .media),
        CatalogApp(id: "maps", name: "Apple Maps", symbol: "map.fill", tint: .green,
                   scheme: "maps://", webFallback: "https://maps.apple.com/",
                   alternates: ["map://"], category: .travel),
        CatalogApp(id: "safari", name: "Safari", symbol: "safari.fill", tint: .blue,
                   scheme: "x-web-search://", webFallback: "https://www.apple.com/", category: .productivity),

        // Third-party schemes. These are the public routes each vendor
        // documents or has registered for years; a web fallback covers the
        // "app not installed" case.
        CatalogApp(id: "spotify", name: "Spotify", symbol: "waveform", tint: .green,
                   scheme: "spotify://", webFallback: "https://open.spotify.com/", category: .media),
        CatalogApp(id: "youtube", name: "YouTube", symbol: "play.rectangle.fill", tint: .red,
                   scheme: "youtube://", webFallback: "https://www.youtube.com/",
                   alternates: ["vnd.youtube://"], category: .media),
        CatalogApp(id: "netflix", name: "Netflix", symbol: "tv.fill", tint: .red,
                   scheme: "nflx://", webFallback: "https://www.netflix.com/", category: .media),
        CatalogApp(id: "twitch", name: "Twitch", symbol: "gamecontroller.fill", tint: .purple,
                   scheme: "twitch://", webFallback: "https://www.twitch.tv/", category: .media),
        CatalogApp(id: "soundcloud", name: "SoundCloud", symbol: "cloud.fill", tint: .orange,
                   scheme: "soundcloud://", webFallback: "https://soundcloud.com/", category: .media),
        CatalogApp(id: "instagram", name: "Instagram", symbol: "camera.circle.fill", tint: .purple,
                   scheme: "instagram://", webFallback: "https://www.instagram.com/", category: .social),
        CatalogApp(id: "tiktok", name: "TikTok", symbol: "music.note.tv.fill", tint: .black,
                   scheme: "snssdk1233://", webFallback: "https://www.tiktok.com/",
                   alternates: ["tiktok://", "musically://"], category: .social),
        CatalogApp(id: "x", name: "X", symbol: "at", tint: .black,
                   scheme: "twitter://", webFallback: "https://x.com/", category: .social),
        CatalogApp(id: "reddit", name: "Reddit", symbol: "bubble.left.and.bubble.right.fill", tint: .orange,
                   scheme: "reddit://", webFallback: "https://www.reddit.com/", category: .social),
        CatalogApp(id: "discord", name: "Discord", symbol: "bubble.left.fill", tint: .indigo,
                   scheme: "discord://", webFallback: "https://discord.com/app",
                   alternates: ["com.hammerandchisel.discord://"], category: .social),
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
                   scheme: "claude://", webFallback: "https://claude.ai/", category: .productivity),
        CatalogApp(id: "gmaps", name: "Google Maps", symbol: "location.fill", tint: .green,
                   scheme: "comgooglemaps://", webFallback: "https://maps.google.com/",
                   alternates: ["googlemaps://"], category: .travel),
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
                   scheme: "steam://", webFallback: "https://store.steampowered.com/",
                   alternates: ["steammobile://"], category: .games),

        // The rest of a typical Home Screen. Added because an icon pack draws
        // these and a tile that cannot name its app cannot launch it - the
        // artwork imports either way, but only a catalogue entry opens.
        //
        // Weather and Calculator publish no scheme, like Clock: Apple has
        // never shipped one, and claiming a route that cannot work turns a tap
        // into "could not be opened", which sends you looking for a problem on
        // the phone.
        CatalogApp(id: "weather", name: "Weather", symbol: "cloud.sun.fill", tint: .blue,
                   scheme: "weather://", webFallback: "https://weather.apple.com/",
                   alternates: ["x-apple-weather://"], category: .system),
        CatalogApp(id: "calculator", name: "Calculator", symbol: "plusminus", tint: .gray,
                   scheme: "calc://", webFallback: nil,
                   alternates: ["calculator://", "calculator-app://"], category: .system),
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

        // The second wave, taken from the community scheme lists and filtered:
        // apps that no longer exist are gone - Wunderlist, HBO GO, Workflow -
        // and where a list disagrees with a vendor, the vendor wins the primary
        // slot - the lists give Google Maps as `googlemaps://` where Google
        // documents `comgooglemaps://`, which is why the entry above leads with
        // the documented one and keeps the list's spelling as an alternate.
        //
        // None of these are device-verified. That is affordable because the
        // router walks every candidate and stops at the first that opens, so a
        // scheme that has gone stale costs one refused call rather than a dead
        // tile, and the web address at the end always answers.
        CatalogApp(id: "disneyplus", name: "Disney+", symbol: "sparkles.tv.fill", tint: .blue,
                   scheme: "disneyplus://", webFallback: "https://www.disneyplus.com/", category: .media),
        CatalogApp(id: "hulu", name: "Hulu", symbol: "tv.fill", tint: .green,
                   scheme: "hulu://", webFallback: "https://www.hulu.com/", category: .media),
        CatalogApp(id: "max", name: "Max", symbol: "tv.fill", tint: .purple,
                   scheme: "hbomax://", webFallback: "https://play.max.com/", category: .media),
        CatalogApp(id: "primevideo", name: "Prime Video", symbol: "play.tv.fill", tint: .cyan,
                   scheme: "aiv://", webFallback: "https://www.primevideo.com/",
                   alternates: ["primevideo://"], category: .media),
        CatalogApp(id: "appletv", name: "Apple TV", symbol: "appletv.fill", tint: .black,
                   scheme: "videos://", webFallback: nil, category: .system),
        CatalogApp(id: "shazam", name: "Shazam", symbol: "waveform.circle.fill", tint: .blue,
                   scheme: "shazam://", webFallback: "https://www.shazam.com/", category: .media),
        CatalogApp(id: "audible", name: "Audible", symbol: "headphones", tint: .orange,
                   scheme: "audible://", webFallback: "https://www.audible.com/", category: .media),
        CatalogApp(id: "pandora", name: "Pandora", symbol: "music.note.list", tint: .blue,
                   scheme: "pandora://", webFallback: "https://www.pandora.com/", category: .media),
        CatalogApp(id: "plex", name: "Plex", symbol: "play.square.stack.fill", tint: .yellow,
                   scheme: "plex://", webFallback: "https://app.plex.tv/", category: .media),
        CatalogApp(id: "crunchyroll", name: "Crunchyroll", symbol: "play.circle.fill", tint: .orange,
                   scheme: "crunchyroll://", webFallback: "https://www.crunchyroll.com/", category: .media),
        CatalogApp(id: "imdb", name: "IMDb", symbol: "star.square.fill", tint: .yellow,
                   scheme: "imdb://", webFallback: "https://www.imdb.com/", category: .media),
        CatalogApp(id: "vimeo", name: "Vimeo", symbol: "play.rectangle.fill", tint: .cyan,
                   scheme: "vimeo://", webFallback: "https://vimeo.com/", category: .media),

        CatalogApp(id: "signal", name: "Signal", symbol: "lock.message.fill", tint: .blue,
                   scheme: "sgnl://", webFallback: "https://signal.org/", category: .social),
        // Threads ships under its internal name, Barcelona.
        CatalogApp(id: "threads", name: "Threads", symbol: "at.circle.fill", tint: .black,
                   scheme: "barcelona://", webFallback: "https://www.threads.net/",
                   alternates: ["threads://"], category: .social),
        CatalogApp(id: "bluesky", name: "Bluesky", symbol: "cloud.fill", tint: .blue,
                   scheme: "bluesky://", webFallback: "https://bsky.app/", category: .social),
        CatalogApp(id: "skype", name: "Skype", symbol: "video.bubble.left.fill", tint: .blue,
                   scheme: "skype://", webFallback: "https://web.skype.com/", category: .social),
        CatalogApp(id: "tumblr", name: "Tumblr", symbol: "text.bubble.fill", tint: .indigo,
                   scheme: "tumblr://", webFallback: "https://www.tumblr.com/", category: .social),
        CatalogApp(id: "viber", name: "Viber", symbol: "phone.bubble.fill", tint: .purple,
                   scheme: "viber://", webFallback: "https://www.viber.com/", category: .social),
        CatalogApp(id: "line", name: "LINE", symbol: "bubble.left.fill", tint: .green,
                   scheme: "line://", webFallback: "https://line.me/", category: .social),
        CatalogApp(id: "wechat", name: "WeChat", symbol: "bubble.left.and.bubble.right.fill", tint: .green,
                   scheme: "weixin://", webFallback: "https://www.wechat.com/", category: .social),
        CatalogApp(id: "bereal", name: "BeReal", symbol: "camera.viewfinder", tint: .black,
                   scheme: "bereal://", webFallback: "https://bere.al/", category: .social),

        CatalogApp(id: "todoist", name: "Todoist", symbol: "checklist", tint: .red,
                   scheme: "todoist://", webFallback: "https://todoist.com/", category: .productivity),
        CatalogApp(id: "things", name: "Things", symbol: "checkmark.square.fill", tint: .blue,
                   scheme: "things://", webFallback: "https://culturedcode.com/things/", category: .productivity),
        CatalogApp(id: "trello", name: "Trello", symbol: "rectangle.split.3x1.fill", tint: .blue,
                   scheme: "trello://", webFallback: "https://trello.com/", category: .productivity),
        CatalogApp(id: "asana", name: "Asana", symbol: "circle.grid.2x2.fill", tint: .pink,
                   scheme: "asana://", webFallback: "https://app.asana.com/", category: .productivity),
        CatalogApp(id: "evernote", name: "Evernote", symbol: "note.text", tint: .green,
                   scheme: "evernote://", webFallback: "https://www.evernote.com/", category: .productivity),
        CatalogApp(id: "dropbox", name: "Dropbox", symbol: "shippingbox.fill", tint: .blue,
                   scheme: "dbapi-1://", webFallback: "https://www.dropbox.com/",
                   alternates: ["dropbox://"], category: .productivity),
        CatalogApp(id: "onedrive", name: "OneDrive", symbol: "cloud.fill", tint: .blue,
                   scheme: "ms-onedrive://", webFallback: "https://onedrive.live.com/", category: .productivity),
        CatalogApp(id: "gkeep", name: "Google Keep", symbol: "note.text", tint: .yellow,
                   scheme: "comgooglekeep://", webFallback: "https://keep.google.com/", category: .productivity),
        CatalogApp(id: "gphotos", name: "Google Photos", symbol: "photo.stack.fill", tint: .blue,
                   scheme: "googlephotos://", webFallback: "https://photos.google.com/", category: .productivity),
        CatalogApp(id: "gdocs", name: "Google Docs", symbol: "doc.text.fill", tint: .blue,
                   scheme: "googledocs://", webFallback: "https://docs.google.com/", category: .productivity),
        CatalogApp(id: "gtranslate", name: "Google Translate", symbol: "character.bubble.fill", tint: .blue,
                   scheme: "googletranslate://", webFallback: "https://translate.google.com/",
                   category: .productivity),
        CatalogApp(id: "google", name: "Google", symbol: "magnifyingglass", tint: .blue,
                   scheme: "google://", webFallback: "https://www.google.com/", category: .productivity),
        CatalogApp(id: "gemini", name: "Gemini", symbol: "sparkles", tint: .blue,
                   scheme: "googlegemini://", webFallback: "https://gemini.google.com/",
                   alternates: ["googleassistant://"], category: .productivity),
        CatalogApp(id: "onepassword", name: "1Password", symbol: "key.fill", tint: .blue,
                   scheme: "onepassword://", webFallback: "https://1password.com/", category: .productivity),
        CatalogApp(id: "bitwarden", name: "Bitwarden", symbol: "lock.shield.fill", tint: .blue,
                   scheme: "bitwarden://", webFallback: "https://vault.bitwarden.com/", category: .productivity),
        CatalogApp(id: "shortcuts", name: "Shortcuts", symbol: "square.stack.3d.up.fill", tint: .indigo,
                   scheme: "shortcuts://", webFallback: nil, category: .system),
        CatalogApp(id: "files", name: "Files", symbol: "folder.fill", tint: .blue,
                   scheme: "shareddocuments://", webFallback: nil, category: .system),
        CatalogApp(id: "findmy", name: "Find My", symbol: "location.circle.fill", tint: .green,
                   scheme: "findmy://", webFallback: nil, category: .system),
        CatalogApp(id: "home", name: "Home", symbol: "house.fill", tint: .orange,
                   scheme: "x-hm://", webFallback: nil, category: .system),
        CatalogApp(id: "news", name: "News", symbol: "newspaper.fill", tint: .red,
                   scheme: "applenews://", webFallback: nil, category: .system),
        CatalogApp(id: "books", name: "Books", symbol: "book.fill", tint: .orange,
                   scheme: "ibooks://", webFallback: nil, category: .system),
        CatalogApp(id: "stocks", name: "Stocks", symbol: "chart.line.uptrend.xyaxis", tint: .green,
                   scheme: "stocks://", webFallback: nil, category: .system),
        CatalogApp(id: "voicememos", name: "Voice Memos", symbol: "mic.fill", tint: .red,
                   scheme: "voicememos://", webFallback: nil, category: .system),

        CatalogApp(id: "arc", name: "Arc Search", symbol: "safari.fill", tint: .blue,
                   scheme: "arcmobile2://", webFallback: "https://arc.net/", category: .productivity),
        CatalogApp(id: "firefox", name: "Firefox", symbol: "flame.fill", tint: .orange,
                   scheme: "firefox://", webFallback: "https://www.mozilla.org/firefox/",
                   category: .productivity),
        CatalogApp(id: "brave", name: "Brave", symbol: "shield.lefthalf.filled", tint: .orange,
                   scheme: "brave://", webFallback: "https://search.brave.com/", category: .productivity),
        CatalogApp(id: "duckduckgo", name: "DuckDuckGo", symbol: "magnifyingglass.circle.fill", tint: .orange,
                   scheme: "ddgLaunch://", webFallback: "https://duckduckgo.com/", category: .productivity),
        CatalogApp(id: "edge", name: "Edge", symbol: "globe", tint: .blue,
                   scheme: "microsoft-edge://", webFallback: "https://www.bing.com/", category: .productivity),

        CatalogApp(id: "paypal", name: "PayPal", symbol: "creditcard.fill", tint: .blue,
                   scheme: "paypal://", webFallback: "https://www.paypal.com/", category: .productivity),
        CatalogApp(id: "venmo", name: "Venmo", symbol: "dollarsign.circle.fill", tint: .blue,
                   scheme: "venmo://", webFallback: "https://venmo.com/", category: .productivity),
        CatalogApp(id: "cashapp", name: "Cash App", symbol: "dollarsign.square.fill", tint: .green,
                   scheme: "squarecash://", webFallback: "https://cash.app/", category: .productivity),
        CatalogApp(id: "robinhood", name: "Robinhood", symbol: "chart.xyaxis.line", tint: .green,
                   scheme: "robinhood://", webFallback: "https://robinhood.com/", category: .productivity),
        CatalogApp(id: "coinbase", name: "Coinbase", symbol: "bitcoinsign.circle.fill", tint: .blue,
                   scheme: "coinbase://", webFallback: "https://www.coinbase.com/",
                   alternates: ["com.coinbase.accounts://"], category: .productivity),
        CatalogApp(id: "revolut", name: "Revolut", symbol: "creditcard.circle.fill", tint: .black,
                   scheme: "revolut://", webFallback: "https://www.revolut.com/", category: .productivity),

        CatalogApp(id: "doordash", name: "DoorDash", symbol: "bag.fill", tint: .red,
                   scheme: "doordash://", webFallback: "https://www.doordash.com/", category: .travel),
        CatalogApp(id: "ubereats", name: "Uber Eats", symbol: "fork.knife", tint: .green,
                   scheme: "ubereats://", webFallback: "https://www.ubereats.com/", category: .travel),
        CatalogApp(id: "instacart", name: "Instacart", symbol: "basket.fill", tint: .green,
                   scheme: "instacart://", webFallback: "https://www.instacart.com/", category: .travel),
        CatalogApp(id: "starbucks", name: "Starbucks", symbol: "cup.and.saucer.fill", tint: .green,
                   scheme: "starbucks://", webFallback: "https://www.starbucks.com/", category: .travel),
        CatalogApp(id: "ebay", name: "eBay", symbol: "tag.fill", tint: .blue,
                   scheme: "ebay://", webFallback: "https://www.ebay.com/", category: .productivity),
        CatalogApp(id: "etsy", name: "Etsy", symbol: "gift.fill", tint: .orange,
                   scheme: "etsy://", webFallback: "https://www.etsy.com/", category: .productivity),
        CatalogApp(id: "target", name: "Target", symbol: "target", tint: .red,
                   scheme: "target://", webFallback: "https://www.target.com/", category: .productivity),
        CatalogApp(id: "walmart", name: "Walmart", symbol: "cart.circle.fill", tint: .blue,
                   scheme: "walmart://", webFallback: "https://www.walmart.com/", category: .productivity),

        CatalogApp(id: "waze", name: "Waze", symbol: "arrow.triangle.turn.up.right.circle.fill", tint: .cyan,
                   scheme: "waze://", webFallback: "https://waze.com/", category: .travel),
        CatalogApp(id: "booking", name: "Booking.com", symbol: "bed.double.fill", tint: .blue,
                   scheme: "booking://", webFallback: "https://www.booking.com/", category: .travel),
        CatalogApp(id: "tripadvisor", name: "Tripadvisor", symbol: "binoculars.fill", tint: .green,
                   scheme: "tripadvisor://", webFallback: "https://www.tripadvisor.com/", category: .travel),
        CatalogApp(id: "citymapper", name: "Citymapper", symbol: "tram.fill", tint: .green,
                   scheme: "citymapper://", webFallback: "https://citymapper.com/", category: .travel),

        CatalogApp(id: "duolingo", name: "Duolingo", symbol: "character.book.closed.fill", tint: .green,
                   scheme: "duolingo://", webFallback: "https://www.duolingo.com/", category: .productivity),
        CatalogApp(id: "fitbit", name: "Fitbit", symbol: "figure.walk", tint: .teal,
                   scheme: "fitbit://", webFallback: "https://www.fitbit.com/", category: .productivity),
        CatalogApp(id: "myfitnesspal", name: "MyFitnessPal", symbol: "flame.fill", tint: .blue,
                   scheme: "mfp://", webFallback: "https://www.myfitnesspal.com/", category: .productivity),
        CatalogApp(id: "peloton", name: "Peloton", symbol: "figure.indoor.cycle", tint: .red,
                   scheme: "pelotoncycle://", webFallback: "https://members.onepeloton.com/",
                   category: .productivity),
        CatalogApp(id: "headspace", name: "Headspace", symbol: "brain.head.profile", tint: .orange,
                   scheme: "headspace://", webFallback: "https://www.headspace.com/", category: .productivity),
        CatalogApp(id: "calm", name: "Calm", symbol: "moon.stars.fill", tint: .blue,
                   scheme: "calm://", webFallback: "https://www.calm.com/", category: .productivity),

        CatalogApp(id: "pokemongo", name: "Pokemon GO", symbol: "figure.walk.circle.fill", tint: .yellow,
                   scheme: "pokemongo://", webFallback: "https://pokemongolive.com/", category: .games),
        CatalogApp(id: "clashofclans", name: "Clash of Clans", symbol: "shield.fill", tint: .orange,
                   scheme: "clashofclans://",
                   webFallback: "https://supercell.com/en/games/clashofclans/", category: .games),
        CatalogApp(id: "brawlstars", name: "Brawl Stars", symbol: "star.circle.fill", tint: .yellow,
                   scheme: "brawlstars://",
                   webFallback: "https://supercell.com/en/games/brawlstars/", category: .games),
        CatalogApp(id: "chesscom", name: "Chess.com", symbol: "crown.fill", tint: .green,
                   scheme: "chesscom://", webFallback: "https://www.chess.com/", category: .games),
    ]

    private static let index: [String: CatalogApp] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) }
    )

    static func app(id: String) -> CatalogApp? { index[id] }

    static func apps(in category: CatalogApp.Category) -> [CatalogApp] {
        all.filter { $0.category == category }
    }
}
