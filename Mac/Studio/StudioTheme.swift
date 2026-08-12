import AppKit
import SwiftUI

/// The studio's palette and type, taken from the design mockup
/// (`Layout Editor.dc.html`) rather than approximated.
///
/// **The canvas is always dark; the shell follows the system.** A panel that
/// changes weight with the appearance changes what the artwork next to it looks
/// like, which is why this was fixed dark to begin with — but that argument is
/// about the canvas, not about the library, the welcome window or the guide.
/// Every editing tool that shows artwork does the same thing: a neutral,
/// unchanging viewing environment, inside an app that otherwise behaves.
///
/// So `canvas*` below is deliberately not adaptive, and everything else is.
/// Names are unchanged from the fixed-dark version on purpose: the editor alone
/// has thousands of lines referring to them, and a rename would have been a
/// far larger and riskier diff than a change of value.
enum StudioTheme {
    /// One colour that resolves against whichever appearance is drawing it.
    private static func adaptive(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hex: dark)
                : NSColor(hex: light)
        })
    }

    // MARK: - Accent

    /// The amber is the identity and does not change with appearance. It clears
    /// contrast on both grounds because it is only ever a fill or a mark, never
    /// small text on white — `accentInk` is for that.
    static let accent = Color(hex: 0xeb9a3e)
    static let accentEdge = adaptive(dark: 0xd3862c, light: 0xbe7622)
    static let accentHover = adaptive(dark: 0xf2a84f, light: 0xf0a442)
    /// Text on an accent fill. Near-black brown, not white: the amber is light.
    static let onAccent = Color(hex: 0x1a1206)
    /// The accent as *text*, which needs to darken on a light ground to stay
    /// legible where the fill does not.
    static let accentInk = adaptive(dark: 0xeb9a3e, light: 0x9c5f13)

    // MARK: - Surfaces

    /// Behind the canvas, under the radial wash. Fixed: see the note above.
    static let canvasWell = Color(hex: 0x0f0f13)
    static let canvasGlowTop = Color(hex: 0x17171f)
    static let canvasGlowBottom = Color(hex: 0x0d0d11)
    /// Layers and inspector.
    static let panel = adaptive(dark: 0x1a1a20, light: 0xfdfcfa)
    static let panelEdge = adaptive(dark: 0x101014, light: 0xe4e0da)
    /// The inspector's own header strip.
    static let headerFill = adaptive(dark: 0x1f1f26, light: 0xf6f3ef)
    static let headerEdge = adaptive(dark: 0x26262e, light: 0xe4e0da)
    static let toolbarTop = adaptive(dark: 0x2a2a33, light: 0xfbf9f6)
    static let toolbarBottom = adaptive(dark: 0x232329, light: 0xf2efea)
    static let toolbarEdge = adaptive(dark: 0x141419, light: 0xdcd7d0)
    static let statusFill = adaptive(dark: 0x16161b, light: 0xf2efea)
    static let statusEdge = adaptive(dark: 0x24242c, light: 0xe0dbd4)
    static let divider = adaptive(dark: 0x2c2c35, light: 0xe4e0da)
    /// Sunken wells: search fields, the tab strip's trough.
    static let well = adaptive(dark: 0x24242c, light: 0xefebe5)

    // MARK: - Controls

    static let controlFill = adaptive(dark: 0x31313b, light: 0xffffff)
    static let controlEdge = adaptive(dark: 0x3e3e4a, light: 0xd7d2cb)
    static let controlHover = adaptive(dark: 0x3c3c47, light: 0xf6f3ef)
    static let controlText = adaptive(dark: 0xdcdce6, light: 0x2b2823)

    // MARK: - Text

    static let textBright = adaptive(dark: 0xf2f2f7, light: 0x14120f)
    static let text = adaptive(dark: 0xdcdce6, light: 0x2b2823)
    static let textSecondary = adaptive(dark: 0x8e8e9c, light: 0x6b6660)
    static let textTertiary = adaptive(dark: 0x757582, light: 0x847e76)
    static let textDim = adaptive(dark: 0x63636f, light: 0x9a948c)

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

    /// Behind the library's cards. Adaptive, unlike the canvas: this is a room
    /// the cards sit in, not a surface artwork is judged against.
    static let libraryBackground = adaptive(dark: 0x121217, light: 0xf4f1ec)

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

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: 1
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
