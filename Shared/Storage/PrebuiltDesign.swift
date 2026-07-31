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

    /// One bundled design, addressed by its identity.
    ///
    /// Several can ship at once - a design's font family is derived from its
    /// id, so their fonts coexist in one bundle without colliding - and the
    /// phone chooses between them.
    struct Entry: Identifiable, Sendable {
        let id: UUID
        let name: String
        /// A build made before several designs could ship names its files
        /// without an id. Falling back keeps such a build working rather than
        /// requiring a rebuild to see anything at all.
        var isLegacy = false

        private func resource(_ kind: String) -> String {
            isLegacy ? "prebuilt-\(kind)" : "prebuilt-\(id.uuidString.lowercased())-\(kind)"
        }

        var manifestName: String { resource("manifest") }
        var backdropURL: URL? { PrebuiltDesign.resource(named: resource("backdrop"), extension: "jpg") }
        var wallpaperURL: URL? { PrebuiltDesign.resource(named: resource("wallpaper"), extension: "png") }
        /// The wallpaper without the tiles, when this build shipped one. The
        /// phone bakes its own occupants onto it at export time; nil means the
        /// design was built before the plain variant existed and only the
        /// pre-baked wallpaper can be offered.
        var plainWallpaperURL: URL? { PrebuiltDesign.resource(named: resource("wallpaper-plain"), extension: "png") }
        var previewURL: URL? { PrebuiltDesign.resource(named: resource("preview"), extension: "mp4") }

        /// A clip variant's own backdrop and preview, addressed by variant id.
        func backdropURL(variant: UUID) -> URL? {
            PrebuiltDesign.resource(
                named: resource("backdrop-\(variant.uuidString.lowercased())"),
                extension: "jpg"
            )
        }

        func previewURL(variant: UUID) -> URL? {
            PrebuiltDesign.resource(
                named: resource("preview-\(variant.uuidString.lowercased())"),
                extension: "mp4"
            )
        }

        var manifest: BuildManifest? {
            guard let url = PrebuiltDesign.resource(named: manifestName, extension: "json"),
                  let data = try? Data(contentsOf: url)
            else { return nil }
            return try? JSONDecoder().decode(BuildManifest.self, from: data)
        }
    }

    /// Every design compiled into this build, in the order the studio wrote
    /// them. Empty when nothing has been bundled yet.
    static let entries: [Entry] = {
        guard let url = PrebuiltDesign.resource(named: "prebuilt-index", extension: "json"),
              let data = try? Data(contentsOf: url)
        else {
            // A build made before several designs could ship names its files
            // without an id. Presented as one entry so the phone and the widget
            // do not need to know the difference.
            return legacyEntry.map { [$0] } ?? []
        }
        struct Index: Decodable {
            struct Item: Decodable {
                let id: UUID
                let name: String
            }
            let designs: [Item]
        }
        guard let index = try? JSONDecoder().decode(Index.self, from: data) else { return [] }
        return index.designs.map { Entry(id: $0.id, name: $0.name) }
    }()

    /// The single-design layout this shipped with first.
    private static let legacyEntry: Entry? = {
        guard let manifest else { return nil }
        return Entry(id: manifest.designID, name: "Design", isLegacy: true)
    }()

    /// The design the phone last chose, or the first bundled one.
    static func selected(id: UUID? = ActiveDesign.identifier) -> Entry? {
        if let id, let match = entries.first(where: { $0.id == id }) { return match }
        return entries.first
    }

    /// Loaded once: the manifest is small, but a widget re-reads it on every
    /// render and there is no reason to touch the disk each time.
    static let manifest: BuildManifest? = {
        guard let url = PrebuiltDesign.resource(named: manifestResource, extension: "json") else {
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

    /// The chosen bundled design's manifest.
    ///
    /// `manifest` alone reads the single-design filename, which stopped existing
    /// once several designs could ship at once - so anything asking for "the
    /// bundled manifest" got nil on a modern build even though the widget was
    /// drawing one. That silently disabled the font lab.
    static var selectedManifest: BuildManifest? { selected()?.manifest ?? manifest }

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
        resource(
            named: LaneFontBuilder.postScriptName(family: familyBase, lane: 0),
            extension: "ttf"
        ) != nil
    }

    /// The design a launch argument asks for: `-MotionaryDesignIndex 1` is the
    /// second bundled design, in the order the studio wrote them.
    ///
    /// nil when the arguments say nothing, so a normal launch leaves whatever
    /// was swiped to alone.
    static func launchSelection(in arguments: [String]) -> UUID? {
        guard let flag = arguments.firstIndex(of: "-MotionaryDesignIndex"),
              arguments.index(after: flag) < arguments.endIndex,
              let index = Int(arguments[arguments.index(after: flag)]),
              entries.indices.contains(index)
        else { return nil }
        return entries[index].id
    }

    /// Marker so the resources can be found in the bundle this code was compiled
    /// into, not only in `Bundle.main`.
    private final class BundleMarker {}

    /// Where a bundled design's files are.
    ///
    /// `Bundle.main` in the app and in the extension, which is what production
    /// needs. In a unit test `Bundle.main` is the runner, so every lookup came
    /// back nil and every test that asked about a bundled design skipped itself
    /// - which is how the widget's design selection went untested long enough to
    /// regress.
    static func resource(named name: String, extension ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext)
            ?? Bundle(for: BundleMarker.self).url(forResource: name, withExtension: ext)
    }

    static var backdropURL: URL? {
        PrebuiltDesign.resource(named: backdropResource, extension: "jpg")
    }

    static var wallpaperURL: URL? {
        PrebuiltDesign.resource(named: wallpaperResource, extension: "png")
    }

    /// The animation as a video, for the app to play.
    ///
    /// The app cannot draw the lane fonts at all - only the widget renderer
    /// advances timer text - so showing the design full screen means playing
    /// the same frames back as a film. It is seeked by wall clock, so opening
    /// the app picks up wherever the widget had got to.
    static var previewURL: URL? {
        PrebuiltDesign.resource(named: previewResource, extension: "mp4")
    }

    static let previewResource = "prebuilt-preview"

    /// A tile's icon, rasterised at build time.
    ///
    /// The widget cannot fetch or render one - no network, no time, and the
    /// SVG renderer is not worth its memory in an extension with a 45MB
    /// ceiling - so the studio bakes each icon into the bundle and the widget
    /// only has to load it.
    static func iconURL(tileID: UUID) -> URL? {
        PrebuiltDesign.resource(named: iconResource(tileID: tileID), extension: "png")
    }

    static func iconResource(tileID: UUID) -> String {
        "prebuilt-icon-\(tileID.uuidString.lowercased())"
    }

    /// The baked icon for whatever app occupies a slot right now.
    ///
    /// The authored occupant keeps the un-suffixed name older builds wrote, so
    /// designs baked before slots could be reassigned still find their artwork.
    /// An alternate's file only exists when it shipped with a skin; there is
    /// deliberately no fallback to the authored file, because showing one app's
    /// icon on a tile that launches another is worse than the catalogue's
    /// SF Symbol plate.
    static func iconResource(tileID: UUID, appID: String, authoredAppID: String) -> String {
        appID == authoredAppID
            ? iconResource(tileID: tileID)
            : "\(iconResource(tileID: tileID))-\(appID.lowercased())"
    }

    static func iconURL(tileID: UUID, appID: String, authoredAppID: String) -> URL? {
        PrebuiltDesign.resource(
            named: iconResource(tileID: tileID, appID: appID, authoredAppID: authoredAppID),
            extension: "png"
        )
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
