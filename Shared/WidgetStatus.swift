import CoreGraphics
import Foundation
import os

/// Everything the widget could see the last time it tried to draw.
///
/// A widget reports through a rectangle a few centimetres wide, in text the
/// system may redact, and on device its log is out of reach: the tunnel hides
/// it from syslog, `log collect` wants root, and `devicectl` refuses the app
/// group path. So it writes the whole picture here and the app shows it as
/// copyable text — one screenshot or paste should be enough to diagnose it.
struct WidgetStatus: Codable, Equatable, Sendable {
    var recordedAt = Date()
    var outcome = "unknown"

    // What the system asked for
    var family = "?"
    var familyRawValue = -1
    /// The size the widget was actually given, in points. This is measured
    /// rather than assumed, so it also checks the geometry table.
    var renderedSize: CGSize = .zero

    // What was found
    var containerReachable = false
    var designID: String?
    var designName: String?
    var designSize: String?
    var buildGeneration = 0

    /// Why there is no design to draw. "No design" used to report nothing at
    /// all, which is the one case where the report most needs to speak up:
    /// an empty store and a store full of designs that will not decode look
    /// identical from the outside.
    var designFolders = 0
    var designsDecoded = 0
    var decodeErrors: [String] = []
    var activeSelection: String?

    var manifestFound = false
    var laneCount = 0
    var framesPerSecond = 0
    var loopFrameCount = 0
    var animationCrop: CGRect = .zero
    var widgetRect: CGRect = .zero
    var screenSize: CGSize = .zero
    var manifestFontBytes = 0

    // Fonts on disk and in the process
    var fontFilesOnDisk = 0
    var fontBytesOnDisk = 0
    var lanesRequested = 0
    var lanesRegistered = 0
    var lanesResolvable = 0
    var blinkFontResolved = false
    var fontFailures: [String] = []

    // The picture behind the animation
    var backdropExists = false
    var backdropBytes = 0
    var backdropDecoded: CGSize = .zero
    var wallpaperExists = false
    var wallpaperBytes = 0

    // Environment
    var memoryFootprintMB = 0
    var memoryLimitHintMB = 0

    var succeeded: Bool { outcome == "ok" }

    /// Whether the animated crop lands anywhere the widget can show it. A crop
    /// entirely outside the visible window draws nothing, which looks identical
    /// to a broken font.
    var cropIsVisible: Bool {
        guard !animationCrop.isEmpty, !widgetRect.isEmpty else { return false }
        return animationCrop.intersects(widgetRect)
    }

    var headline: String {
        if succeeded { return "Widget rendered" }
        return outcome
    }

    /// Plain text, so it can be copied and pasted rather than photographed.
    var report: String {
        func rect(_ r: CGRect) -> String {
            "(\(Int(r.minX)),\(Int(r.minY))) \(Int(r.width))x\(Int(r.height))"
        }
        func mb(_ bytes: Int) -> String { String(format: "%.1fMB", Double(bytes) / 1_000_000) }

        return """
        MOTIONARY WIDGET REPORT
        recorded      \(recordedAt.formatted(date: .abbreviated, time: .standard))
        outcome       \(outcome)

        FAMILY
        family        \(family) (raw \(familyRawValue))
        rendered      \(Int(renderedSize.width))x\(Int(renderedSize.height)) pt
        expected      \(Int(widgetRect.width / 3))x\(Int(widgetRect.height / 3)) pt

        STORE
        container     \(containerReachable ? "reachable" : "UNREACHABLE")
        folders       \(designFolders)
        decoded       \(designsDecoded)
        selection     \(activeSelection ?? "none")
        errors        \(decodeErrors.isEmpty ? "none" : decodeErrors.joined(separator: " | "))

        DESIGN
        design        \(designName ?? "none") [\(designSize ?? "?")] gen \(buildGeneration)
        id            \(designID ?? "none")
        manifest      \(manifestFound ? "found" : "MISSING")
        lanes/fps     \(laneCount) / \(framesPerSecond)
        loop          \(loopFrameCount) frames
        crop          \(rect(animationCrop))
        widgetRect    \(rect(widgetRect))
        screen        \(Int(screenSize.width))x\(Int(screenSize.height))
        cropVisible   \(cropIsVisible ? "yes" : "NO - crop is outside the widget")

        FONTS
        onDisk        \(fontFilesOnDisk) files, \(mb(fontBytesOnDisk))
        manifestSays  \(mb(manifestFontBytes))
        registered    \(lanesRegistered)/\(lanesRequested)
        resolvable    \(lanesResolvable)/\(lanesRequested)
        blinkMask     \(blinkFontResolved ? "resolved" : "MISSING")
        failures      \(fontFailures.isEmpty ? "none" : fontFailures.joined(separator: " | "))

        PICTURE
        backdrop      \(backdropExists ? "\(mb(backdropBytes)) -> \(Int(backdropDecoded.width))x\(Int(backdropDecoded.height))" : "MISSING")
        wallpaper     \(wallpaperExists ? mb(wallpaperBytes) : "MISSING")

        MEMORY
        footprint     \(memoryFootprintMB)MB
        """
    }
}

enum WidgetStatusLog {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "WidgetStatus")
    private static let filename = "widget-status.json"

    private static func url(in store: DesignStore) -> URL {
        store.root.deletingLastPathComponent().appendingPathComponent(filename)
    }

    static func write(_ status: WidgetStatus) {
        guard let store = try? DesignStore() else {
            logger.error("cannot record widget status: the shared container is unavailable")
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(status).write(to: url(in: store), options: .atomic)
            logger.info("widget status: \(status.outcome, privacy: .public)")
        } catch {
            logger.error("could not record widget status: \(String(describing: error), privacy: .public)")
        }
    }

    static func read(store: DesignStore) -> WidgetStatus? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url(in: store)) else { return nil }
        return try? decoder.decode(WidgetStatus.self, from: data)
    }
}

/// Resident memory, so a render that dies on the widget's memory cap can be
/// told apart from one that simply found nothing to draw.
enum MemoryFootprint {
    static var megabytes: Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint / 1_000_000)
    }
}
