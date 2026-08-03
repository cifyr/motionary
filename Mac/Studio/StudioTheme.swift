import SwiftUI

/// The layout editor's palette and type, taken from the design mockup
/// (`Layout Editor.dc.html`) rather than approximated.
///
/// A fixed dark theme on purpose: the canvas is a phone screen, and a panel
/// that changes weight with the system appearance changes what the artwork
/// next to it looks like. The mockup names IBM Plex with `-apple-system` and
/// `monospace` behind it, which is what this uses - the system faces are the
/// design's own declared fallback.
enum StudioTheme {
    // MARK: - Accent

    static let accent = Color(hex: 0xeb9a3e)
    static let accentEdge = Color(hex: 0xd3862c)
    static let accentHover = Color(hex: 0xf2a84f)
    /// Text on an accent fill. Near-black brown, not white: the amber is light.
    static let onAccent = Color(hex: 0x1a1206)

    // MARK: - Surfaces

    /// Behind the canvas, under the radial wash.
    static let canvasWell = Color(hex: 0x0f0f13)
    static let canvasGlowTop = Color(hex: 0x17171f)
    static let canvasGlowBottom = Color(hex: 0x0d0d11)
    /// Layers and inspector.
    static let panel = Color(hex: 0x1a1a20)
    static let panelEdge = Color(hex: 0x101014)
    /// The inspector's own header strip.
    static let headerFill = Color(hex: 0x1f1f26)
    static let headerEdge = Color(hex: 0x26262e)
    static let toolbarTop = Color(hex: 0x2a2a33)
    static let toolbarBottom = Color(hex: 0x232329)
    static let toolbarEdge = Color(hex: 0x141419)
    static let statusFill = Color(hex: 0x16161b)
    static let statusEdge = Color(hex: 0x24242c)
    static let divider = Color(hex: 0x2c2c35)
    /// Sunken wells: search fields, the tab strip's trough.
    static let well = Color(hex: 0x24242c)

    // MARK: - Controls

    static let controlFill = Color(hex: 0x31313b)
    static let controlEdge = Color(hex: 0x3e3e4a)
    static let controlHover = Color(hex: 0x3c3c47)
    static let controlText = Color(hex: 0xdcdce6)

    // MARK: - Text

    static let textBright = Color(hex: 0xf2f2f7)
    static let text = Color(hex: 0xdcdce6)
    static let textSecondary = Color(hex: 0x8e8e9c)
    static let textTertiary = Color(hex: 0x757582)
    static let textDim = Color(hex: 0x63636f)

    // MARK: - Metrics

    static let radius: CGFloat = 6
    static let controlRadius: CGFloat = 7

    // MARK: - Type

    /// Section eyebrows: 9.5px mono, wide tracking, upper case.
    static func eyebrow(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .tracking(1.3)
    }

    static let body = Font.system(size: 11.5)
    static let bodyStrong = Font.system(size: 11.5, weight: .semibold)
    static let small = Font.system(size: 11)
    static let mono = Font.system(size: 10.5, design: .monospaced)
    static let monoSmall = Font.system(size: 9.5, design: .monospaced)
    static let title = Font.system(size: 13, weight: .semibold)

    /// The canvas well's wash, matching the mockup's radial gradient.
    static var canvasBackground: some View {
        RadialGradient(
            colors: [canvasGlowTop, canvasGlowBottom],
            center: UnitPoint(x: 0.3, y: -0.1),
            startRadius: 0,
            endRadius: 900
        )
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// The mockup's chip button: a dark fill, a lighter hairline, and a one-pixel
/// inset highlight along the top edge.
struct StudioButtonStyle: ButtonStyle {
    var prominent = false
    var compact = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = if prominent {
            configuration.isPressed ? StudioTheme.accentEdge
                : (hovering ? StudioTheme.accentHover : StudioTheme.accent)
        } else {
            configuration.isPressed ? StudioTheme.controlEdge
                : (hovering ? StudioTheme.controlHover : StudioTheme.controlFill)
        }
        return configuration.label
            .font(.system(size: compact ? 11 : 12, weight: prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? StudioTheme.onAccent : StudioTheme.controlText)
            .padding(.horizontal, compact ? 8 : 11)
            .frame(height: compact ? 22 : 25)
            .background(fill, in: RoundedRectangle(cornerRadius: StudioTheme.controlRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: StudioTheme.controlRadius, style: .continuous)
                    .strokeBorder(prominent ? StudioTheme.accentEdge : StudioTheme.controlEdge, lineWidth: 1)
            }
            // The highlight the mockup draws inside the top edge, which is what
            // keeps a flat fill from reading as a painted rectangle.
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(.white.opacity(prominent ? 0.28 : 0.05))
                    .frame(height: 1)
                    .padding(.horizontal, 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: StudioTheme.controlRadius, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 }
    }
}

extension ButtonStyle where Self == StudioButtonStyle {
    static var studio: StudioButtonStyle { StudioButtonStyle() }
    static var studioCompact: StudioButtonStyle { StudioButtonStyle(compact: true) }
    static var studioProminent: StudioButtonStyle { StudioButtonStyle(prominent: true) }
}

/// A field that reads as sunk into the panel rather than sitting on it.
struct StudioFieldStyle: TextFieldStyle {
    // swiftlint:disable:next identifier_name
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(StudioTheme.text)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(StudioTheme.well, in: RoundedRectangle(cornerRadius: StudioTheme.radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: StudioTheme.radius, style: .continuous)
                    .strokeBorder(StudioTheme.headerEdge, lineWidth: 1)
            }
    }
}
