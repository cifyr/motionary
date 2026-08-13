import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// How a placed app tile is drawn, in both the editor and the widget.
///
/// iOS gives third parties no access to other apps' icons, so a tile is a
/// glyph on a tinted, translucent plate that reads over any wallpaper.
struct TileView: View {
    let tile: PlacedTile
    let side: CGFloat
    var isSelected: Bool = false
    /// Rasterised icon from the shared cache. The widget cannot fetch one, so
    /// whoever draws the tile supplies it and the SF Symbol is the fallback.
    var iconImage: Image?

    private var app: CatalogApp? { AppCatalog.app(id: tile.appID) }

    private var plateColor: Color {
        if let hex = tile.tintHex, let color = Color(hex: hex) { return color }
        return app?.tint ?? .gray
    }

    /// The custom name when the tile carries one: a tile opening an app the
    /// catalogue never heard of should still say what it is.
    private var caption: String { tile.displayName }

    /// A skin replaces the plate rather than sitting on it.
    private var isSkinned: Bool { tile.skin != nil && iconImage != nil }

    var body: some View {
        VStack(spacing: side * 0.06) {
            ZStack {
                if isSkinned, let iconImage {
                    iconImage
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: side, height: side)
                        .clipShape(RoundedRectangle(cornerRadius: side * tile.cornerRadius, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: side * 0.06, y: side * 0.03)
                } else {
                RoundedRectangle(cornerRadius: side * tile.cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: side * tile.cornerRadius, style: .continuous)
                            .fill(plateColor.opacity(0.55))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: side * tile.cornerRadius, style: .continuous)
                            .strokeBorder(.white.opacity(0.35), lineWidth: max(0.5, side * 0.012))
                    }
                    .shadow(color: .black.opacity(0.35), radius: side * 0.06, y: side * 0.03)

                if let iconImage {
                    iconImage
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: side * 0.56, height: side * 0.56)
                        .shadow(color: .black.opacity(0.4), radius: side * 0.03)
                } else {
                    Image(systemName: app?.symbol ?? "questionmark")
                        .font(.system(size: side * 0.44, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.4), radius: side * 0.03)
                }
                }
            }
            .frame(width: side, height: side)

            if tile.showsLabel {
                Text(caption)
                    .font(.system(size: max(6, side * 0.15), weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: side * 0.03)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .rotationEffect(.degrees(tile.rotation))
        .opacity(tile.opacity)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: side * tile.cornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: max(1.5, side * 0.03))
                    .frame(width: side, height: side)
            }
        }
    }
}

/// The artwork a slot draws: whatever the phone put on it, else the icon baked
/// for its occupant at build time.
///
/// The chosen one is a skin that shipped with the design, loaded from the
/// bundle and decoded here rather than handed over as a path - a widget's
/// renderer cannot reach a file itself.
enum SlotArtwork {
    /// `artFolder` is a delivered design's own artwork, which arrives beside it
    /// rather than in the bundle. Tried first and then the bundle, so one
    /// lookup serves both kinds of design: a delivered design whose package
    /// predates the artwork still falls back to whatever the build shipped,
    /// which is a worse icon rather than a missing one.
    static func image(
        for tile: PlacedTile,
        designID: UUID,
        authoredAppID: String,
        side: CGFloat,
        artFolder: URL? = nil
    ) -> Image? {
        // Both names, in that order. A delivered design carries each tile's own
        // icon - already rendered from whatever skin it wears - but not the
        // skin library a build ships, because that library is most of a
        // hundred megabytes of artwork the design is not using.
        let names = [
            tile.skin.map { PrebuiltDesign.skinResource(designID: designID, skin: $0) },
            PrebuiltDesign.iconResource(
                tileID: tile.id,
                appID: tile.appID,
                authoredAppID: authoredAppID
            ),
        ].compactMap { $0 }
        let delivered = artFolder.flatMap { folder in
            names
                .map { folder.appendingPathComponent("\($0).png") }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }
        let url = delivered
            ?? tile.skin.flatMap { PrebuiltDesign.skinURL(designID: designID, skin: $0) }
            ?? PrebuiltDesign.iconURL(
                tileID: tile.id,
                appID: tile.appID,
                authoredAppID: authoredAppID
            )
        return url
            .flatMap { ImageLoader.load(at: $0, maxPixelSize: Int(side * 3)) }
            .map { Image(decorative: $0, scale: 1) }
    }
}

/// Deep link the widget uses to hand a launch back to the containing app.
///
/// Everything goes through the app because a `Link` from an extension straight
/// to a third-party scheme is unreliable. A catalogue app travels as its id; an
/// app the catalogue does not know travels as its URL, so a tile can open
/// anything on the phone rather than only what was compiled in.
enum LaunchLink {
    static let scheme = "motionary"

    enum Target: Equatable {
        case app(String)
        case url(URL)
    }

    static func url(for appID: String) -> URL {
        URL(string: "\(scheme)://launch/\(appID)")!
    }

    /// The link for a tile, custom target included.
    static func url(for tile: PlacedTile) -> URL {
        guard let custom = tile.custom, let first = custom.launchCandidates.first else {
            return url(for: tile.appID)
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "url", value: first.absoluteString)]
        // The id is the fallback when the query cannot be built, so a tap
        // still reaches something nameable rather than nothing.
        return components.url ?? url(for: tile.appID)
    }

    /// A link that hands several routes to the app, tried in order.
    ///
    /// A widget cannot open a custom scheme itself - the lab build settled
    /// that on a physical iPhone - so anything that is not https travels this
    /// way, and the app walks the list exactly as it does for a tile.
    static func url(opening candidates: [URL]) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "open"
        components.queryItems = candidates.map { URLQueryItem(name: "url", value: $0.absoluteString) }
        return components.url ?? candidates.first ?? url(for: "")
    }

    /// Every route a link carries, in order. One `url` item is the common
    /// case; a background tap that opens a browser carries two.
    static func candidates(from url: URL) -> [URL] {
        guard url.scheme == scheme, url.host == "open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return [] }
        return items.filter { $0.name == "url" }.compactMap { $0.value }.compactMap(URL.init(string:))
    }

    static func target(from url: URL) -> Target? {
        guard url.scheme == scheme else { return nil }
        if url.host == "launch", let id = url.pathComponents.dropFirst().first {
            return .app(id)
        }
        if url.host == "open",
           let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
               .queryItems?.first(where: { $0.name == "url" })?.value,
           let target = URL(string: raw) {
            return .url(target)
        }
        return nil
    }

    static func appID(from url: URL) -> String? {
        if case .app(let id) = target(from: url) { return id }
        return nil
    }
}

extension Color {
    /// Accepts the `#rrggbb` form the tile editor writes.
    init?(hex: String) {
        var text = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var hexString: String? {
        // The studio edits tints on the Mac and the widget draws them on the
        // phone, so the bridge to a CGColor has to exist on both.
#if canImport(UIKit)
        let native = UIColor(self).cgColor
#else
        let native = NSColor(self).cgColor
#endif
        guard let components = native.components, components.count >= 3 else { return nil }
        let scaled = components.prefix(3).map { Int(($0 * 255).rounded()) }
        return String(format: "#%02x%02x%02x", scaled[0], scaled[1], scaled[2])
    }
}
