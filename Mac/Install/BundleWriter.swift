import Foundation

enum BundleWriterError: Error, CustomStringConvertible {
    case projectNotFound(path: String)
    case noFonts(path: String)
    case plistUnreadable(path: String, underlying: Error)
    case plistPatternMissing(path: String)

    var description: String {
        switch self {
        case .projectNotFound(let path):
            "bundle: no Motionary project at \(path); pick the folder holding project.yml"
        case .noFonts(let path):
            "bundle: the generator wrote no lane fonts to \(path)"
        case .plistUnreadable(let path, let underlying):
            "bundle: could not read \(path): \(underlying)"
        case .plistPatternMissing(let path):
            "bundle: \(path) has no UIAppFonts array to replace; it may have been reformatted"
        }
    }
}

/// Finds the Motionary project this studio builds.
///
/// Launched from Finder the working directory is `/`, so deriving the project
/// from it works from a terminal and fails everywhere else. The build products
/// live inside the project, so walking up from the app itself finds it in a
/// normal run, and anything else is a question for the user.
enum ProjectLocator {
    static let bookmarkKey = "projectRoot"

    static func isProject(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("project.yml").path)
    }

    static func find(from start: URL = Bundle.main.bundleURL) -> URL? {
        if let stored = UserDefaults.standard.url(forKey: bookmarkKey), isProject(stored) {
            return stored
        }
        var candidate = start.resolvingSymlinksInPath()
        while candidate.path != "/" {
            if isProject(candidate) { return candidate }
            candidate = candidate.deletingLastPathComponent()
        }
        let working = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return isProject(working) ? working : nil
    }

    static func remember(_ url: URL) {
        UserDefaults.standard.set(url, forKey: bookmarkKey)
    }
}

/// Copies a freshly generated design into the iOS project's `Resources` and
/// lists its fonts in `UIAppFonts` on both targets.
///
/// This is the whole reason the studio exists. A widget extension will only
/// draw a font that was in its bundle at install time - runtime registration
/// resolves by name and then either draws nothing or makes WidgetKit throw out
/// the timeline entirely - so putting a design on the Home Screen means
/// compiling it in.
struct BundleWriter {
    /// The project root: the folder holding `project.yml`.
    let projectRoot: URL

    private var resources: URL { projectRoot.appendingPathComponent("Resources", isDirectory: true) }

    init(projectRoot: URL) throws {
        guard FileManager.default.fileExists(
            atPath: projectRoot.appendingPathComponent("project.yml").path
        ) else {
            throw BundleWriterError.projectNotFound(path: projectRoot.path)
        }
        self.projectRoot = projectRoot
    }

    struct Result: Sendable {
        let fontCount: Int
        let totalBytes: Int
    }

    /// One design in a bundle that may hold several.
    struct Bundled {
        let name: String
        /// The design's folder in the studio's store.
        let folder: URL
        let manifest: BuildManifest
    }

    /// Installs every design the phone should be able to switch between.
    ///
    /// A design's font family is derived from its id, so several sets coexist
    /// without colliding - but every lane of every design has to be declared in
    /// `UIAppFonts`, and each design costs about 29MB of the install.
    @discardableResult
    func install(_ designs: [Bundled], iconsFolder: URL? = nil, store: DesignStore? = nil) throws -> Result {
        let manager = FileManager.default
        try manager.createDirectory(at: resources, withIntermediateDirectories: true)

        // Everything from the previous build goes first, or the bundle
        // accumulates every clip ever made and UIAppFonts names fonts that no
        // longer belong to anything.
        for stale in try manager.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil) {
            let name = stale.lastPathComponent
            if (stale.pathExtension == "ttf" && name.hasPrefix("MFont")) || name.hasPrefix("prebuilt-") {
                try manager.removeItem(at: stale)
            }
        }

        var allFonts: [String] = []
        var totalBytes = 0
        for design in designs {
            let fontsFolder = design.folder.appendingPathComponent("Fonts", isDirectory: true)
            let fonts = try manager.contentsOfDirectory(at: fontsFolder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "ttf" }
                .sorted { laneNumber($0) < laneNumber($1) }
            guard !fonts.isEmpty else { throw BundleWriterError.noFonts(path: fontsFolder.path) }

            for font in fonts {
                try manager.copyItem(at: font, to: resources.appendingPathComponent(font.lastPathComponent))
                totalBytes += (try? Data(contentsOf: font).count) ?? 0
            }
            allFonts += fonts.map(\.lastPathComponent)

            let key = design.manifest.designID.uuidString.lowercased()
            try copy(design.folder.appendingPathComponent("manifest.json"), to: "prebuilt-\(key)-manifest.json")
            try copy(design.folder.appendingPathComponent("widget-backdrop.jpg"), to: "prebuilt-\(key)-backdrop.jpg")
            try copy(design.folder.appendingPathComponent("wallpaper.png"), to: "prebuilt-\(key)-wallpaper.png")
            // Tile-free, so the phone can bake whichever occupants its slots
            // hold at export time. `copy` skips it for designs built before it
            // existed, and the phone falls back to the pre-baked wallpaper.
            try copy(design.folder.appendingPathComponent("wallpaper-plain.png"), to: "prebuilt-\(key)-wallpaper-plain.png")
            // The app plays this rather than drawing the lane fonts: only the
            // widget renderer advances timer text.
            try copy(design.folder.appendingPathComponent("preview.mp4"), to: "prebuilt-\(key)-preview.mp4")
            // Each variant's backdrop and preview; its fonts are already in
            // the lane glob above, since every clip writes into one folder.
            for variant in design.manifest.builtVariants {
                let vid = variant.id.uuidString.lowercased()
                try copy(
                    design.folder.appendingPathComponent("widget-backdrop-\(vid).jpg"),
                    to: "prebuilt-\(key)-backdrop-\(vid).jpg"
                )
                try copy(
                    design.folder.appendingPathComponent("preview-\(vid).mp4"),
                    to: "prebuilt-\(key)-preview-\(vid).mp4"
                )
            }
            try installIcons(manifest: design.manifest, from: iconsFolder)
            try installPictures(manifest: design.manifest, store: store)
        }

        try writeIndex(designs)
        try rewriteAppFonts(at: projectRoot.appendingPathComponent("Widget/Info.plist"), fonts: allFonts)
        try rewriteAppFonts(at: projectRoot.appendingPathComponent("App/Info.plist"), fonts: allFonts)

        return Result(fontCount: allFonts.count, totalBytes: totalBytes)
    }

    /// Names and orders what shipped, so the phone can offer them without
    /// hunting the bundle for files.
    private func writeIndex(_ designs: [Bundled]) throws {
        struct Index: Encodable {
            struct Item: Encodable {
                let id: UUID
                let name: String
            }
            let designs: [Item]
        }
        let index = Index(designs: designs.map { .init(id: $0.manifest.designID, name: $0.name) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(index).write(
            to: resources.appendingPathComponent("prebuilt-index.json"),
            options: .atomic
        )
    }

    /// One PNG per tile rather than one per icon.
    ///
    /// The widget looks an icon up by the tile that owns it, because it has
    /// only the manifest to go on and no icon cache to consult. Two tiles
    /// sharing an icon costs one extra copy of a 256px PNG, which is cheaper
    /// than teaching the extension about cache keys.
    private func installIcons(manifest: BuildManifest, from iconsFolder: URL?) throws {
        let manager = FileManager.default
        let artwork = TileArtwork(iconsFolder: iconsFolder)
        for tile in manifest.placedTiles {
            // Alternates first: they cannot stop the authored icon shipping.
            // Only skinned ones have a file at all - the rest draw their
            // catalogue SF Symbol on the phone, exactly like a missing icon.
            for alternate in tile.alternates {
                guard let skin = alternate.skin, let rendered = artwork.url(forSkin: skin) else { continue }
                let name = PrebuiltDesign.iconResource(
                    tileID: tile.id,
                    appID: alternate.appID,
                    authoredAppID: tile.appID
                )
                try manager.copyItem(at: rendered, to: resources.appendingPathComponent("\(name).png"))
            }

            guard let rendered = artwork.url(for: tile) else {
                // Not fatal: the tile falls back to its catalogue SF Symbol,
                // which is a worse icon rather than a missing one.
                continue
            }
            try manager.copyItem(
                at: rendered,
                to: resources.appendingPathComponent("\(PrebuiltDesign.iconResource(tileID: tile.id)).png")
            )
        }
    }

    /// Placed pictures ship as keyed PNGs, one per placement, because the
    /// widget draws them live over the animation. Baked into the wallpaper
    /// alone - which is all they used to get - they never reached the widget's
    /// own frame, and the app's preview video covered them too.
    private func installPictures(manifest: BuildManifest, store: DesignStore?) throws {
        guard !manifest.placedAssets.isEmpty else { return }
        guard let store else {
            FileHandle.standardError.write(Data("""
            bundle: no store to read placed pictures from; \
            \(manifest.placedAssets.count) picture(s) will not draw on the phone\n
            """.utf8))
            return
        }
        for asset in manifest.placedAssets {
            guard let keyed = AssetArtwork.image(for: asset, designID: manifest.designID, store: store) else {
                // Logged by AssetArtwork; the design still ships, minus this one.
                continue
            }
            try FrameEncoder.pngData(keyed).write(
                to: resources.appendingPathComponent("\(PrebuiltDesign.pictureResource(assetID: asset.id)).png"),
                options: .atomic
            )
        }
    }

    private func copy(_ source: URL, to name: String) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: source.path) else { return }
        let destination = resources.appendingPathComponent(name)
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.copyItem(at: source, to: destination)
    }

    /// Lane order is numeric, not lexical: `L10` sorts before `L2` as text, and
    /// the lane index decides which frame a font holds.
    private func laneNumber(_ url: URL) -> Int {
        guard let range = url.lastPathComponent.range(of: #"L(\d+)-"#, options: .regularExpression) else {
            return 0
        }
        return Int(url.lastPathComponent[range].dropFirst().dropLast()) ?? 0
    }

    /// Rewrites the `UIAppFonts` array in place, keeping the rest of the plist
    /// byte for byte. Re-encoding the whole file through `PropertyListSerialization`
    /// would reorder and reformat every other key in a diff nobody asked for.
    func rewriteAppFonts(at url: URL, fonts: [String]) throws {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw BundleWriterError.plistUnreadable(path: url.path, underlying: error)
        }
        let rewritten = try Self.replacingAppFonts(in: text, with: fonts, path: url.path)
        try Data(rewritten.utf8).write(to: url, options: .atomic)
    }

    /// Pure so it can be tested without a project on disk.
    static func replacingAppFonts(in plist: String, with fonts: [String], path: String) throws -> String {
        // `(?s)` because the array is written one font per line, and without it
        // the match stops at the first newline and finds nothing.
        guard let range = plist.range(
            of: #"(?s)<key>UIAppFonts</key>\s*<array>.*?</array>"#,
            options: [.regularExpression]
        ) else {
            throw BundleWriterError.plistPatternMissing(path: path)
        }
        // The blink mask font drives which lane is visible and is not part of
        // any design, so it stays whatever the design's lanes turn out to be.
        let entries = ([FontSetGenerator.blinkFontResourceName + ".otf"] + fonts)
            .map { "\n    <string>\($0)</string>" }
            .joined()
        return plist.replacingCharacters(
            in: range,
            with: "<key>UIAppFonts</key>\n  <array>\(entries)\n  </array>"
        )
    }
}
