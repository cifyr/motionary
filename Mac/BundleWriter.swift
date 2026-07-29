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

    /// `designFolder` is a built design's folder in the studio's scratch store.
    @discardableResult
    func install(designFolder: URL, manifest: BuildManifest) throws -> Result {
        let manager = FileManager.default
        try manager.createDirectory(at: resources, withIntermediateDirectories: true)

        let fontsFolder = designFolder.appendingPathComponent("Fonts", isDirectory: true)
        let fonts = try manager.contentsOfDirectory(at: fontsFolder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "ttf" }
            .sorted { laneNumber($0) < laneNumber($1) }
        guard !fonts.isEmpty else { throw BundleWriterError.noFonts(path: fontsFolder.path) }

        // The previous design's lanes have to go, or the bundle accumulates
        // every clip ever built and UIAppFonts names fonts that are no longer
        // the current design's.
        for stale in try manager.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
        where stale.pathExtension == "ttf" && stale.lastPathComponent.hasPrefix("MFont") {
            try manager.removeItem(at: stale)
        }

        var totalBytes = 0
        for font in fonts {
            let destination = resources.appendingPathComponent(font.lastPathComponent)
            try manager.copyItem(at: font, to: destination)
            totalBytes += (try? Data(contentsOf: font).count) ?? 0
        }

        try copy(designFolder.appendingPathComponent("manifest.json"), to: "prebuilt-manifest.json")
        try copy(designFolder.appendingPathComponent("widget-backdrop.jpg"), to: "prebuilt-backdrop.jpg")
        try copy(designFolder.appendingPathComponent("wallpaper.png"), to: "prebuilt-wallpaper.png")
        // The app plays this rather than drawing the lane fonts: only the
        // widget renderer advances timer text.
        try copy(designFolder.appendingPathComponent("preview.mp4"), to: "prebuilt-preview.mp4")

        let names = fonts.map(\.lastPathComponent)
        try rewriteAppFonts(at: projectRoot.appendingPathComponent("Widget/Info.plist"), fonts: names)
        try rewriteAppFonts(at: projectRoot.appendingPathComponent("App/Info.plist"), fonts: names)

        _ = manifest
        return Result(fontCount: fonts.count, totalBytes: totalBytes)
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
