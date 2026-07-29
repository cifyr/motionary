import CoreGraphics
import CoreText
import Foundation
import os

/// The one design, built ahead of time and shipped inside the app.
///
/// Everything else about this widget has been proven working: the geometry, the
/// crop, the backdrop, the memory budget, the timeline. The single difference
/// from the Onewheel build that animates on the same phone was that its fonts
/// live in the bundle and are declared in `UIAppFonts`, while these were
/// generated on device and registered at runtime. The animated layer never drew
/// here and always drew there.
///
/// So the fonts are pre-built and bundled, exactly as the working build has
/// them. That removes on-device generation, runtime registration and the shared
/// container from the render path altogether — the widget now reads nothing it
/// did not ship with.
enum PrebuiltDesign {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "Prebuilt")

    static let manifestResource = "prebuilt-manifest"
    static let backdropResource = "prebuilt-backdrop"
    static let wallpaperResource = "prebuilt-wallpaper"

    /// Loaded once: the manifest is small, but a widget re-reads it on every
    /// render and there is no reason to touch the disk each time.
    static let manifest: BuildManifest? = {
        guard let url = Bundle.main.url(forResource: manifestResource, withExtension: "json") else {
            logger.error("\(manifestResource, privacy: .public).json is missing from the bundle")
            return nil
        }
        do {
            return try JSONDecoder().decode(BuildManifest.self, from: Data(contentsOf: url))
        } catch {
            logger.error("could not decode the bundled manifest: \(String(describing: error), privacy: .public)")
            return nil
        }
    }()

    /// Whether a design's lane fonts shipped in this build.
    ///
    /// Only bundled fonts animate. Registering generated fonts at runtime —
    /// `.process` and `.persistent` both — resolves every lane by name on iOS
    /// 27 and then draws nothing, which is indistinguishable from a working
    /// font until you look at the widget. So this is the test, rather than the
    /// registry's own report: the registry cannot tell the difference, and
    /// trusting it is what produced a black widget from a healthy-looking
    /// 32/32.
    static func fontsAreBundled(familyBase: String) -> Bool {
        Bundle.main.url(
            forResource: LaneFontBuilder.postScriptName(family: familyBase, lane: 0),
            withExtension: "ttf"
        ) != nil
    }

    static var backdropURL: URL? {
        Bundle.main.url(forResource: backdropResource, withExtension: "jpg")
    }

    static var wallpaperURL: URL? {
        Bundle.main.url(forResource: wallpaperResource, withExtension: "png")
    }

    /// The animation as a video, for the app to play.
    ///
    /// The app cannot draw the lane fonts at all - only the widget renderer
    /// advances timer text - so showing the design full screen means playing
    /// the same frames back as a film. It is seeked by wall clock, so opening
    /// the app picks up wherever the widget had got to.
    static var previewURL: URL? {
        Bundle.main.url(forResource: previewResource, withExtension: "mp4")
    }

    static let previewResource = "prebuilt-preview"

    /// A tile's icon, rasterised at build time.
    ///
    /// The widget cannot fetch or render one - no network, no time, and the
    /// SVG renderer is not worth its memory in an extension with a 45MB
    /// ceiling - so the studio bakes each icon into the bundle and the widget
    /// only has to load it.
    static func iconURL(tileID: UUID) -> URL? {
        Bundle.main.url(forResource: iconResource(tileID: tileID), withExtension: "png")
    }

    static func iconResource(tileID: UUID) -> String {
        "prebuilt-icon-\(tileID.uuidString.lowercased())"
    }

    /// Whether every lane font declared in `UIAppFonts` actually resolved.
    ///
    /// Bundled fonts are registered by the system before any code runs, so this
    /// is a check rather than a step: if it fails, the build is wrong and no
    /// amount of retrying at runtime will help.
    static func fontReport(for manifest: BuildManifest) -> (resolvable: Int, requested: Int) {
        var resolvable = 0
        for lane in 0 ..< manifest.laneCount {
            let name = LaneFontBuilder.postScriptName(family: manifest.fontFamilyBase, lane: lane)
            if CTFontCopyPostScriptName(CTFontCreateWithName(name as CFString, 12, nil)) as String == name {
                resolvable += 1
            }
        }
        return (resolvable, manifest.laneCount)
    }
}
