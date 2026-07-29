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

    @discardableResult
    static func register(manifest: BuildManifest, store: DesignStore) -> Report {
        let key = "\(manifest.fontFamilyBase)#\(manifest.buildGeneration)"
        lock.lock()
        let alreadyDone = registered.contains(key)
        lock.unlock()

        let blinkFailures = registerBlinkFont()
        var failures = blinkFailures
        var registeredCount = 0

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
                var error: Unmanaged<CFError>?
                if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                    registeredCount += 1
                } else {
                    let failure = error?.takeRetainedValue()
                    let code = (failure as Error?).map { ($0 as NSError).code } ?? -1
                    // Re-registering the same file is expected on a warm
                    // process and is not an error worth reporting.
                    if code == Int(CTFontManagerError.alreadyRegistered.rawValue) {
                        registeredCount += 1
                    } else {
                        failures.append("lane \(lane): \(failure.map(String.init(describing:)) ?? "unknown error")")
                    }
                }
            }
        } else {
            registeredCount = manifest.laneCount
        }

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
