/// The Ember scheme's raw tokens, ported from `ember-ds/styles/tokens.css`.
///
/// Values only, as sRGB hex, so the phone app and the studio read the same
/// numbers rather than each keeping its own copy that drifts. How they are
/// spent differs by platform and lives next to the platform: `EmberTheme` on
/// the phone, `StudioTheme` on the Mac.
///
/// The scheme resolves per appearance - `--em-bg` and the text ladder below it
/// are flipped by the site's ThemeProvider - so both grounds are here and the
/// callers pick.
enum EmberPalette {
    /// `--em-dark` / `--em-light`. The two grounds.
    static let dark: UInt32 = 0x0C0D10
    static let light: UInt32 = 0xFFFBF9

    /// `--em-accent`. One accent for the whole scheme, and it earns its place
    /// by being rare.
    static let accent: UInt32 = 0xFF3D00

    /// The text ladder on the dark ground is white by opacity rather than by
    /// hue - `--em-title` through `--em-disable`.
    static let onDarkTitle = (white: 1.0, alpha: 1.0)
    static let onDarkSubtitle = (white: 1.0, alpha: 0.7)
    static let onDarkBody = (white: 1.0, alpha: 0.5)
    static let onDarkDesc = (white: 1.0, alpha: 0.3)
    static let onDarkDisable = (white: 1.0, alpha: 0.15)
    static let onDarkLine = (white: 1.0, alpha: 0.1)

    /// On the light ground the ladder is ink by opacity, and the hairline is a
    /// flat grey rather than a wash - `--em-line` is `#c4c4c4` there.
    static let ink: UInt32 = 0x1D1D1D
    static let lightLine: UInt32 = 0xC4C4C4

    /// Ground shades between `dark` and the panels that sit on it. The scheme
    /// itself has no mid-greys - a web page can layer translucent white over
    /// one ground - but a native window needs opaque fills for its panels, so
    /// these are `dark` lifted by the same amounts the site's overlays produce.
    static let raised: UInt32 = 0x14151A
    static let raisedHigh: UInt32 = 0x1B1C22
    static let sunken: UInt32 = 0x090A0D
}
