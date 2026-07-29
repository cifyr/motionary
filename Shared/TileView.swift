import SwiftUI
import UIKit

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

    var body: some View {
        VStack(spacing: side * 0.06) {
            ZStack {
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
        guard let components = UIColor(self).cgColor.components, components.count >= 3 else { return nil }
        let scaled = components.prefix(3).map { Int(($0 * 255).rounded()) }
        return String(format: "#%02x%02x%02x", scaled[0], scaled[1], scaled[2])
    }
}
