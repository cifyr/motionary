import SwiftUI

/// The app's share of the Ember scheme, ported from `ember-ds/styles/tokens.css`.
///
/// Only the parts a phone app can carry honestly: the ground, the text ladder,
/// and the one accent. The display face is Switzer, which ships as woff2 and so
/// cannot be loaded by iOS without converting it first - the system face at a
/// heavy weight with the same tight tracking reads close enough that the
/// conversion is not worth the bundle.
///
/// Used sparingly on purpose. The app is a window onto a Home Screen, and the
/// picture in it is the design's, not the scheme's - so the scheme lives in the
/// chrome around the picture rather than over it.
extension Color {
    init(emberHex hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// `--em-dark`. The ground everything sits on. The app is dark throughout -
    /// it is a window onto a Home Screen, and the scheme's light ground is the
    /// studio's business.
    static let emberDark = Color(emberHex: EmberPalette.dark)
    /// `--em-accent`. One accent, and it earns its place by being rare.
    static let emberAccent = Color(emberHex: EmberPalette.accent)

    /// `--em-title` through `--em-line`: one ladder of white, by opacity.
    /// Anything that needs to be quieter than `emberDesc` is not worth drawing.
    static let emberTitle = Color.white.opacity(EmberPalette.onDarkTitle.alpha)
    static let emberSubtitle = Color.white.opacity(EmberPalette.onDarkSubtitle.alpha)
    static let emberBody = Color.white.opacity(EmberPalette.onDarkBody.alpha)
    static let emberDesc = Color.white.opacity(EmberPalette.onDarkDesc.alpha)
    static let emberLine = Color.white.opacity(EmberPalette.onDarkLine.alpha)
}

extension View {
    /// A section header the way the scheme sets one: small, upper case, tracked
    /// out, and quiet enough to read as a label rather than as a heading.
    func emberLabel(size: CGFloat = 12) -> some View {
        font(.system(size: size, weight: .medium))
            .textCase(.uppercase)
            // `--em-tracking-label` is 0.02em, which is a fraction of the size
            // rather than a fixed distance.
            .tracking(size * 0.02)
            .foregroundStyle(Color.emberDesc)
    }

    /// A sheet on the scheme's ground rather than on the system's grouped grey.
    ///
    /// The list's own background is hidden rather than recoloured: a grouped
    /// list draws its fill behind the rows, and tinting that leaves the rows
    /// themselves sitting on a lighter slab.
    func emberSheet() -> some View {
        scrollContentBackground(.hidden)
            .background(Color.emberDark.ignoresSafeArea())
            .toolbarBackground(Color.emberDark, for: .navigationBar)
    }

    /// The scheme has two radii and nothing between them - `--em-radius-none`
    /// and `--em-radius-full`. A square edge is the one that reads as Ember;
    /// the pill is for things that are already pills.
    func emberEdge(_ opacity: Double = 1) -> some View {
        overlay(Rectangle().strokeBorder(Color.emberLine.opacity(opacity), lineWidth: 1))
    }
}
