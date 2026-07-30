import CoreText
import Foundation
import os

/// Registers a design's generated lane fonts into the current process.
///
/// This is the load-bearing assumption of the whole app: a widget extension can
/// use fonts that were not in its bundle at install time, as long as they are
/// readable in the shared container and registered with process scope.
enum RuntimeFontRegistry {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "FontRegistry")

    struct Report: Sendable {
        let familyBase: String
        let requested: Int
        let registered: Int
        let resolvable: Int
        let failures: [String]

        var isUsable: Bool { resolvable == requested }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var registered: Set<String> = []

    /// Which scope actually took, for the report.
    nonisolated(unsafe) private(set) static var lastScope = "none"

    private enum Registration {
        case success(String)
        case failure(String)
    }

    /// Persistent first, process second.
    ///
    /// A widget is rasterised by a separate system process, not by the
    /// extension that builds the view — `WidgetRenderer_Default` shows up
    /// alongside the extension in jetsam reports. A font registered with
    /// `.process` scope exists only inside the extension, so the renderer has
    /// nothing to draw the glyph with: the name resolves, 32 lanes report
    /// usable, and the colour glyphs come out empty. Bundled fonts avoid this
    /// because the renderer can reach the bundle. `.persistent` is the same
    /// idea for fonts that were not there at install time.
    private static func registerFont(at url: URL) -> Registration {
        for scope in [CTFontManagerScope.persistent, .process] {
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, scope, &error) {
                return .success(scope == .persistent ? "persistent" : "process")
            }
            let failure = error?.takeRetainedValue()
            let code = (failure as Error?).map { ($0 as NSError).code } ?? -1
            // Already registered is a warm process, not a problem.
            if code == Int(CTFontManagerError.alreadyRegistered.rawValue) {
                return .success(scope == .persistent ? "persistent" : "process")
            }
            if scope == .process {
                return .failure(failure.map(String.init(describing:)) ?? "unknown error")
            }
        }
        return .failure("no scope accepted the font")
    }

    @discardableResult
    static func register(manifest: BuildManifest, store: DesignStore) -> Report {
        let key = "\(manifest.fontFamilyBase)#\(manifest.buildGeneration)"
        lock.lock()
        let alreadyDone = registered.contains(key)
        lock.unlock()

        let blinkFailures = registerBlinkFont()
        var failures = blinkFailures
        var registeredCount = 0
        var usedScope = "none"

        if !alreadyDone {
            for lane in 0 ..< manifest.laneCount {
                let url = store.fontURL(
                    for: manifest.designID,
                    familyBase: manifest.fontFamilyBase,
                    lane: lane
                )
                guard FileManager.default.fileExists(atPath: url.path) else {
                    failures.append("lane \(lane): no file at \(url.lastPathComponent)")
                    continue
                }
                switch registerFont(at: url) {
                case .success(let scope):
                    registeredCount += 1
                    usedScope = scope
                case .failure(let message):
                    failures.append("lane \(lane): \(message)")
                }
            }
        } else {
            registeredCount = manifest.laneCount
        }
        if usedScope != "none" { lastScope = usedScope }

        // Registration returning true is not proof the font is usable, so each
        // lane is resolved by PostScript name before the widget draws with it.
        var resolvable = 0
        for lane in 0 ..< manifest.laneCount {
            let name = LaneFontBuilder.postScriptName(family: manifest.fontFamilyBase, lane: lane)
            let font = CTFontCreateWithName(name as CFString, 12, nil)
            if CTFontCopyPostScriptName(font) as String == name {
                resolvable += 1
            } else if failures.count < 8 {
                failures.append("lane \(lane): \(name) did not resolve")
            }
        }

        if resolvable == manifest.laneCount {
            lock.lock()
            registered.insert(key)
            lock.unlock()
        }

        let report = Report(
            familyBase: manifest.fontFamilyBase,
            requested: manifest.laneCount,
            registered: registeredCount,
            resolvable: resolvable,
            failures: failures
        )
        if report.isUsable {
            logger.info("registered \(manifest.fontFamilyBase, privacy: .public): \(resolvable)/\(manifest.laneCount) lanes usable")
        } else {
            logger.error("""
            font registration incomplete for \(manifest.fontFamilyBase, privacy: .public): \
            \(resolvable)/\(manifest.laneCount) usable; \(failures.joined(separator: "; "), privacy: .public)
            """)
        }
        return report
    }

    /// The blink mask font ships in the bundle and drives which lane is visible.
    private static func registerBlinkFont() -> [String] {
        let name = FontSetGenerator.blinkFontResourceName
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        if CTFontCopyPostScriptName(font) as String == name { return [] }

        guard let url = Bundle.main.url(forResource: name, withExtension: "otf") else {
            return ["blink font \(name).otf missing from bundle"]
        }
        var error: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) else {
            let failure = error?.takeRetainedValue()
            let code = (failure as Error?).map { ($0 as NSError).code } ?? -1
            if code == Int(CTFontManagerError.alreadyRegistered.rawValue) { return [] }
            return ["blink font: \(failure.map(String.init(describing:)) ?? "unknown error")"]
        }
        return []
    }
}
