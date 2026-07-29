import SwiftUI

/// How a placed app tile is drawn, in both the editor and the widget.
///
/// iOS gives third parties no access to other apps' icons, so a tile is a
/// glyph on a tinted, translucent plate that reads over any wallpaper.
struct TileView: View {
    let tile: PlacedTile
    let side: CGFloat
    var isSelected: Bool = false

    private var app: CatalogApp? { AppCatalog.app(id: tile.appID) }

    var body: some View {
        VStack(spacing: side * 0.06) {
            ZStack {
                RoundedRectangle(cornerRadius: side * tile.cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: side * tile.cornerRadius, style: .continuous)
                            .fill((app?.tint ?? .gray).opacity(0.55))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: side * tile.cornerRadius, style: .continuous)
                            .strokeBorder(.white.opacity(0.35), lineWidth: max(0.5, side * 0.012))
                    }
                    .shadow(color: .black.opacity(0.35), radius: side * 0.06, y: side * 0.03)

                Image(systemName: app?.symbol ?? "questionmark")
                    .font(.system(size: side * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: side * 0.03)
            }
            .frame(width: side, height: side)

            if tile.showsLabel {
                Text(app?.name ?? "Unknown")
                    .font(.system(size: max(6, side * 0.15), weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: side * 0.03)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
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

/// Deep link the widget uses to hand a launch back to the containing app.
enum LaunchLink {
    static let scheme = "motionary"

    static func url(for appID: String) -> URL {
        URL(string: "\(scheme)://launch/\(appID)")!
    }

    static func appID(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == "launch" else { return nil }
        return url.pathComponents.dropFirst().first
    }
}
