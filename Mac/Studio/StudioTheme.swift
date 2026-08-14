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

    /// The Ember accent, `--em-accent`, shared with the phone app through
    /// `EmberPalette`. It is the identity and does not change with appearance:
    /// it clears contrast on both grounds because it is only ever a fill or a
    /// mark, never small text on white — `accentInk` is for that.
    ///
    /// This was the studio's own amber before the two were brought together.
    /// The names are what the editor's thousands of references use, so the
    /// scheme arrives as a change of value rather than a rename.
    static let accent = Color(hex: EmberPalette.accent)
    static let accentEdge = adaptive(dark: 0xd93400, light: 0xc22e00)
    static let accentHover = adaptive(dark: 0xff5527, light: 0xff5527)
    /// Text on an accent fill. Near-white now rather than near-black: the ember
    /// is a deep red-orange where the amber was light.
    static let onAccent = Color(hex: EmberPalette.light)
    /// The accent as *text*, which needs to darken on a light ground to stay
    /// legible where the fill does not.
    static let accentInk = adaptive(dark: EmberPalette.accent, light: 0xc22e00)

    // MARK: - Surfaces

    /// Behind the canvas, under the radial wash. Fixed: see the note above.
    ///
    /// Left where it was when the scheme arrived. These three are the viewing
    /// environment artwork is judged against, and the argument for keeping them
    /// neutral outranks matching a palette - they sit within a few points of
    /// Ember's ground already, which is why nothing here had to move.
    static let canvasWell = Color(hex: 0x0f0f13)
    static let canvasGlowTop = Color(hex: 0x17171f)
    static let canvasGlowBottom = Color(hex: 0x0d0d11)
    /// Layers and inspector.
    ///
    /// The scheme has one dark ground and layers translucent white over it,
    /// which a web page can do and an opaque native panel cannot - so the
    /// shades from here down are `--em-dark` lifted by the amounts those
    /// overlays produce, and the warm greys the light side used are replaced by
    /// `--em-light` and its `#c4c4c4` hairline.
    static let panel = adaptive(dark: EmberPalette.raised, light: EmberPalette.light)
    static let panelEdge = adaptive(dark: EmberPalette.dark, light: EmberPalette.lightLine)
    /// The inspector's own header strip.
    static let headerFill = adaptive(dark: EmberPalette.raisedHigh, light: 0xf7f4f1)
    static let headerEdge = adaptive(dark: 0x22232a, light: EmberPalette.lightLine)
    static let toolbarTop = adaptive(dark: 0x1f2027, light: EmberPalette.light)
    static let toolbarBottom = adaptive(dark: 0x191a20, light: 0xf7f4f1)
    static let toolbarEdge = adaptive(dark: EmberPalette.dark, light: EmberPalette.lightLine)
    static let statusFill = adaptive(dark: 0x101116, light: 0xf7f4f1)
    static let statusEdge = adaptive(dark: 0x1e1f26, light: EmberPalette.lightLine)
    static let divider = adaptive(dark: 0x22232a, light: EmberPalette.lightLine)
    /// Sunken wells: search fields, the tab strip's trough.
    static let well = adaptive(dark: EmberPalette.sunken, light: 0xf2efec)

    // MARK: - Controls

    static let controlFill = adaptive(dark: 0x22232a, light: EmberPalette.light)
    static let controlEdge = adaptive(dark: 0x30313a, light: EmberPalette.lightLine)
    static let controlHover = adaptive(dark: 0x2b2c35, light: 0xf7f4f1)
    static let controlText = adaptive(dark: 0xe8e8ec, light: EmberPalette.ink)

    // MARK: - Text

    /// The scheme's ladder is white by opacity on the dark ground and ink by
    /// opacity on the light one. Flattened to opaque values here, because these
    /// are read against several different fills and a translucent one would
    /// take the colour of whichever it happened to land on.
    ///
    /// The two working weights - `text` and `textSecondary` - sit a step
    /// brighter than `--em-subtitle` and `--em-body` would put them. This is a
    /// dense editor rather than a page with six words on it, and the scheme's
    /// lower rungs are for copy that is meant to recede.
    static let textBright = adaptive(dark: 0xffffff, light: EmberPalette.ink)
    static let text = adaptive(dark: 0xd6d7da, light: 0x2e2e2e)
    static let textSecondary = adaptive(dark: 0x9a9b9f, light: 0x666666)
    static let textTertiary = adaptive(dark: 0x76777c, light: 0x8e8e8e)
    static let textDim = adaptive(dark: 0x58595d, light: 0xa0a0a0)

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
    /// the cards sit in, not a surface artwork is judged against - so it is the
    /// scheme's ground itself rather than a shade near it.
    static let libraryBackground = adaptive(dark: EmberPalette.dark, light: 0xf7f4f1)

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
