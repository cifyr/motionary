import CoreGraphics
import CoreText
import Foundation
import SwiftUI
import UIKit
import os

/// Draws the same frame through every font-delivery route at once, so the Home
/// Screen can say which of them the widget renderer honours.
///
/// A widget's view is built in the extension and rasterised somewhere else:
/// `WidgetRenderer_Default` sits next to the extension in the jetsam reports.
/// Anything registered into the extension therefore resolves by name inside the
/// extension and can still be absent where the glyph is drawn, which is how 32
/// of 32 lanes report usable while the picture comes out black. Nothing
/// documents which route survives that hop, so instead of guessing again, all
/// of them are drawn as labelled bands of one picture: the bands with a picture
/// in them are the routes that work.
enum FontLab {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "FontLab")
    private static let flagKey = "fontLabEnabled"

    static var isEnabled: Bool {
        get { UserDefaults(suiteName: DesignStore.appGroupIdentifier)?.bool(forKey: flagKey) ?? false }
        set {
            UserDefaults(suiteName: DesignStore.appGroupIdentifier)?.set(newValue, forKey: flagKey)
            logger.info("font lab \(newValue ? "on" : "off")")
        }
    }

    /// Lets a test run switch the lab without anyone tapping a toggle on a
    /// phone that may be in somebody's hand.
    static func launchOverride(in arguments: [String]) -> Bool? {
        if arguments.contains("-MotionaryFontLabOn") { return true }
        if arguments.contains("-MotionaryFontLabOff") { return false }
        return nil
    }

    /// The routes still worth drawing.
    ///
    /// Four others were tried and measured out, on the simulator and on the
    /// phone alike: `.persistent` scope is refused with CoreText error 307
    /// from the app group and from the extension's own Caches,
    /// `CTFontManagerRegisterFontURLs` persistent reports success and never
    /// resolves, and `RegisterFontDescriptors` does the same. None of them can
    /// hand the renderer a font, so drawing them only spent memory the
    /// extension does not have - nine glyphs at 1074x1086 is about 40MB, and
    /// this widget is killed a little above 45.
    enum Route: String, CaseIterable, Sendable {
        /// The control. Bundled at install time and listed in `UIAppFonts`,
        /// which is the one arrangement already known to animate on device.
        case bundled
        case groupProcess
        case cachesProcess
        case graphicsFont
        /// No registry at all: a `CTFont` built straight from the bytes and
        /// handed to SwiftUI. If the view archive carries the font rather than
        /// its name, the renderer never has to look anything up.
        case direct

        var label: String {
            switch self {
            case .bundled: "BUNDLE"
            case .groupProcess: "GRP proc"
            case .cachesProcess: "CACHE proc"
            case .graphicsFont: "CGFont"
            case .direct: "Direct CTFont"
            }
        }

        var detail: String {
            switch self {
            case .bundled: "in the extension bundle, UIAppFonts"
            case .groupProcess: "app group file, RegisterFontsForURL .process"
            case .cachesProcess: "copied to the extension's Caches, .process"
            case .graphicsFont: "RegisterGraphicsFont from in-memory data"
            case .direct: "CTFont from data, never registered, no name lookup"
            }
        }

        /// A family of its own, so nine copies of one font can be registered
        /// side by side. Sharing a PostScript name would resolve every route to
        /// whichever registered first and quietly make the whole lab agree.
        var family: String { "MLab\(rawValue.prefix(1).uppercased())\(rawValue.dropFirst())" }

        var postScriptName: String { "\(family)-Regular" }
    }

    struct Outcome: Identifiable {
        let route: Route
        /// What registration did, in words, for the render log.
        let note: String
        /// nil when the route could not produce a usable font at all.
        let font: ((CGFloat) -> Font)?

        var id: String { route.rawValue }
        var isDrawable: Bool { font != nil }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: (key: String, outcomes: [Outcome])?

    /// Prepares every route for a design's first lane.
    ///
    /// Cached per build, because the widget evaluates its body more than once
    /// per render and rewriting nine multi-megabyte fonts each time would cost
    /// more memory than the extension is allowed.
    static func run(manifest: BuildManifest, store: DesignStore) -> [Outcome] {
        let key = "\(manifest.designID.uuidString)#\(manifest.buildGeneration)"
        lock.lock()
        if let cache, cache.key == key {
            lock.unlock()
            return cache.outcomes
        }
        lock.unlock()

        // Falls back to the bundled copy so the lab still runs on a phone with
        // nothing imported: the routes under test are about where a font comes
        // from, not which clip it holds.
        let name = LaneFontBuilder.postScriptName(family: manifest.fontFamilyBase, lane: 0)
        let laneZero = store.fontURL(
            for: manifest.designID,
            familyBase: manifest.fontFamilyBase,
            lane: 0
        )
        let source = (try? Data(contentsOf: laneZero))
            ?? Bundle.main.url(forResource: name, withExtension: "ttf").flatMap { try? Data(contentsOf: $0) }
        let sourceFamily = "\(manifest.fontFamilyBase)0"
        let outcomes = Route.allCases.map {
            prepare(route: $0, source: source, sourceFamily: sourceFamily)
        }

        lock.lock()
        cache = (key, outcomes)
        lock.unlock()

        for outcome in outcomes {
            logger.info("\(outcome.route.rawValue, privacy: .public): \(outcome.note, privacy: .public)")
        }
        return outcomes
    }

    private static func prepare(route: Route, source: Data?, sourceFamily: String) -> Outcome {
        if route == .bundled { return bundledControl() }

        guard let source else {
            return Outcome(route: route, note: "no lane 0 font on disk", font: nil)
        }
        let renamed: Data
        do {
            renamed = try rename(source, from: sourceFamily, to: route.family)
        } catch {
            return Outcome(route: route, note: "rename failed: \(error)", font: nil)
        }

        switch route {
        case .bundled:
            return bundledControl()
        case .groupProcess:
            return byURL(route: route, data: renamed, directory: .appGroup, scope: .process)
        case .cachesProcess:
            return byURL(route: route, data: renamed, directory: .caches, scope: .process)
        case .graphicsFont:
            return byGraphicsFont(route: route, data: renamed)
        case .direct:
            return direct(route: route, data: renamed)
        }
    }

    private static func bundledControl() -> Outcome {
        guard let manifest = PrebuiltDesign.manifest else {
            return Outcome(route: .bundled, note: "no bundled design in this build", font: nil)
        }
        let name = LaneFontBuilder.postScriptName(family: manifest.fontFamilyBase, lane: 0)
        guard resolves(name) else {
            return Outcome(route: .bundled, note: "\(name) is not in UIAppFonts", font: nil)
        }
        return Outcome(route: .bundled, note: "bundled as \(name)", font: { .custom(name, size: $0) })
    }

    /// Rasterises one animation glyph with CoreText rather than SwiftUI.
    ///
    /// SwiftUI's `Text` draws nothing at all for these fonts outside a widget,
    /// so this is how the app can tell "the font is unusable here" apart from
    /// "SwiftUI will not draw it here" - two very different findings that look
    /// the same on a black screen.
    static func coreTextProof(route: Route, side: Int) -> UIImage? {
        let name = route == .bundled
            ? PrebuiltDesign.manifest.map { LaneFontBuilder.postScriptName(family: $0.fontFamilyBase, lane: 0) }
            : route.postScriptName
        guard let name else { return nil }

        let font = CTFontCreateWithName(name as CFString, CGFloat(side), nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: "10:00",
            attributes: [.font: font]
        ))
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { context in
            let cg = context.cgContext
            cg.translateBy(x: 0, y: CGFloat(side))
            cg.scaleBy(x: 1, y: -1)
            cg.textPosition = CGPoint(x: 0, y: CGFloat(side) / 5)
            CTLineDraw(line, cg)
        }
    }

    // MARK: - Reporting

    private static let reportFilename = "font-lab.txt"

    private static func reportURL(in store: DesignStore) -> URL {
        store.root.deletingLastPathComponent().appendingPathComponent(reportFilename)
    }

    /// The registration side of the answer, written where the app can show it.
    /// The bands say what drew; this says what CoreText claimed beforehand, and
    /// the gap between the two is the whole finding.
    static func record(_ outcomes: [Outcome], store: DesignStore) {
        let text = (["recorded \(Date().formatted(date: .omitted, time: .standard))"]
            + outcomes.map { "\($0.route.label.padding(toLength: 12, withPad: " ", startingAt: 0))\($0.note)" })
            .joined(separator: "\n")
        do {
            try Data(text.utf8).write(to: reportURL(in: store), options: DesignStore.writingOptions)
        } catch {
            logger.error("could not record the lab: \(String(describing: error), privacy: .public)")
        }
    }

    static func report(store: DesignStore) -> String? {
        (try? Data(contentsOf: reportURL(in: store))).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: - Routes

    private enum Directory {
        case appGroup
        case caches
    }

    private static func byURL(route: Route, data: Data, directory: Directory, scope: CTFontManagerScope) -> Outcome {
        guard let url = write(data, named: route.family, in: directory) else {
            return Outcome(route: route, note: "could not stage the file", font: nil)
        }
        var error: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, scope, &error)
        let failure = error?.takeRetainedValue()
        return named(route: route, registered: ok || isAlreadyRegistered(failure), failure: failure, path: url)
    }

    private static func byGraphicsFont(route: Route, data: Data) -> Outcome {
        guard let provider = CGDataProvider(data: data as CFData), let font = CGFont(provider) else {
            return Outcome(route: route, note: "CGFont would not accept the data", font: nil)
        }
        var error: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterGraphicsFont(font, &error)
        let failure = error?.takeRetainedValue()
        return named(route: route, registered: ok || isAlreadyRegistered(failure), failure: failure, path: nil)
    }

    private static func direct(route: Route, data: Data) -> Outcome {
        guard let descriptor = CTFontManagerCreateFontDescriptorFromData(data as CFData) else {
            return Outcome(route: route, note: "no descriptor came out of the data", font: nil)
        }
        return Outcome(route: route, note: "descriptor held directly, nothing registered") { size in
            Font(CTFontCreateWithFontDescriptor(descriptor, size, nil))
        }
    }

    // MARK: - Plumbing

    /// Turns a registration attempt into a verdict by resolving the name, which
    /// is the only check that means anything: registration returning true is
    /// not proof CoreText will hand the font back.
    private static func named(route: Route, registered: Bool, failure: CFError?, path: URL?) -> Outcome {
        let name = route.postScriptName
        let resolved = resolves(name)
        var note = registered
            ? "registered"
            : "register failed: \(failure.map(String.init(describing:)) ?? "unknown error")"
        note += resolved ? ", name resolves" : ", NAME DOES NOT RESOLVE"
        if let path { note += " (\(path.deletingLastPathComponent().lastPathComponent))" }
        guard resolved else { return Outcome(route: route, note: note, font: nil) }
        return Outcome(route: route, note: note) { .custom(name, size: $0) }
    }

    private static func resolves(_ name: String) -> Bool {
        CTFontCopyPostScriptName(CTFontCreateWithName(name as CFString, 12, nil)) as String == name
    }

    private static func write(_ data: Data, named name: String, in directory: Directory) -> URL? {
        let root: URL?
        switch directory {
        case .appGroup:
            root = (try? DesignStore())?.root.deletingLastPathComponent()
        case .caches:
            root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        }
        guard let root else { return nil }
        let folder = root.appendingPathComponent("fontlab", isDirectory: true)
        let url = folder.appendingPathComponent("\(name).ttf")
        do {
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true,
                attributes: DesignStore.directoryAttributes
            )
            // Rewritten every build so a stale file cannot pass as a working
            // route, and unprotected so a locked phone can still read it.
            try data.write(to: url, options: DesignStore.writingOptions)
            return url
        } catch {
            logger.error("could not stage \(name, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Gives one lane font a family of its own for a route to register under.
    static func rename(_ data: Data, from oldFamily: String, to newFamily: String) throws -> Data {
        var font = try SFNTFile(data: data)
        font.setTable("name", to: try NameTable.replacingFamily(
            in: try font.table("name"),
            from: oldFamily,
            to: newFamily
        ))
        return try font.serialized()
    }

    private static func isAlreadyRegistered(_ error: CFError?) -> Bool {
        guard let error else { return false }
        return (error as Error as NSError).code == Int(CTFontManagerError.alreadyRegistered.rawValue)
    }
}
