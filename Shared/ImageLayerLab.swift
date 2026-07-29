import CoreGraphics
import Foundation
import UIKit
import os

/// Animates a widget out of ordinary images and one bundled font.
///
/// The lane fonts are the expensive part of this project: a design only reaches
/// the Home Screen by being compiled into the extension's bundle, because
/// runtime-registered fonts resolve inside the extension and still draw black
/// where the widget is actually rasterised. Everything else already works from
/// the app group at runtime - the backdrop is loaded from it every render.
///
/// So this asks whether the fonts are needed at all. The blink mask font is
/// bundled and design-independent, and masking demonstrably advances on its own
/// on device. If a stack of `Image`s loaded from the app group, each masked by
/// that font at a different time offset, shows a different picture in each
/// slot, then a design is just a folder of pictures and there is no compile
/// step left.
///
/// What the mask can express is fixed by the font, and it is worth stating
/// plainly because it caps the result. `Custom-Regular` carries one `liga`
/// lookup: a pair of timer digits becomes a filled em square when the seconds
/// count is even and nothing when it is odd. Six ligature sets exist, one per
/// tens digit, and all six map identically - the tens digit carries no
/// information. So a single blink text is a square wave of period two seconds,
/// and two seconds is the longest loop anything built out of this font can
/// have.
enum ImageLayerLab {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "ImageLayerLab")

    /// The blink font's period: one second opaque, one second clear.
    static let cycleDuration: TimeInterval = 2

    // MARK: - Slot maths

    /// Where slot `index` of `count` starts within the two-second cycle.
    static func slotStart(index: Int, count: Int) -> TimeInterval {
        cycleDuration * Double(index) / Double(max(1, count))
    }

    static func slotWidth(count: Int) -> TimeInterval {
        cycleDuration / Double(max(1, count))
    }

    /// The largest number of slots the cycle can be cut into.
    ///
    /// A window is the overlap of two square waves, each opaque for exactly one
    /// second, so no window can be wider than a second and fewer than two slots
    /// cannot tile the cycle. There is no upper bound in the geometry - the
    /// ceiling is how finely the system re-renders timer text, which is what
    /// the lab measures rather than assumes.
    static let minimumFrameCount = 2

    /// Whether a single blink text offset by `offset` is opaque at `date`.
    ///
    /// The model, not a reimplementation: the font turns the seconds count of
    /// the elapsed time into a filled square when that count is even. Written
    /// down here so the slot arithmetic can be tested without a widget.
    static func pulseIsOpaque(offset: TimeInterval, at date: Date, reference: Date) -> Bool {
        let elapsed = date.timeIntervalSince(reference.addingTimeInterval(offset))
        let whole = Int(floor(elapsed))
        return ((whole % 2) + 2) % 2 == 0
    }

    /// The second offset that, intersected with `start`, cuts the window down
    /// to `width`.
    ///
    /// A pulse at `s` is opaque on `[s, s + 1)`. Intersecting it with a pulse at
    /// `s + width - 1`, which is opaque on `[s + width - 1, s + width)`, leaves
    /// exactly `[s, s + width)`.
    static func trailingOffset(start: TimeInterval, width: TimeInterval) -> TimeInterval {
        let raw = start + width - 1
        return raw.truncatingRemainder(dividingBy: cycleDuration) + (raw < 0 ? cycleDuration : 0)
    }

    static func slotIsOpaque(index: Int, count: Int, at date: Date, reference: Date) -> Bool {
        let start = slotStart(index: index, count: count)
        let width = slotWidth(count: count)
        return pulseIsOpaque(offset: start, at: date, reference: reference)
            && pulseIsOpaque(
                offset: trailingOffset(start: start, width: width),
                at: date,
                reference: reference
            )
    }

    /// Which frames the stack has opaque at `date`. Exactly one, if the
    /// windows tile the cycle as intended.
    static func opaqueSlots(count: Int, at date: Date, reference: Date) -> [Int] {
        (0 ..< count).filter { slotIsOpaque(index: $0, count: count, at: date, reference: reference) }
    }

    // MARK: - Settings

    enum Mode: String, CaseIterable, Sendable {
        /// One file per frame, each decoded on its own.
        case separate
        /// Every frame in one tall strip, decoded once and shown through a
        /// moving window. Same pixel count; one allocation instead of N.
        case sheet
    }

    struct Settings: Equatable, Sendable {
        var frameCount = 16
        /// Width of each frame in pixels. Height follows the widget's aspect.
        var tileSide = 256
        var mode = Mode.separate

        /// Identifies the frames on disk, so a changed setting rewrites them
        /// and an unchanged one does not.
        var stamp: String { "\(frameCount)x\(tileSide)-\(mode.rawValue)" }
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: DesignStore.appGroupIdentifier)
    }

    private static let enabledKey = "imageLayerLabEnabled"
    private static let framesKey = "imageLayerLabFrames"
    private static let sideKey = "imageLayerLabSide"
    private static let modeKey = "imageLayerLabMode"

    static var isEnabled: Bool {
        get { defaults?.bool(forKey: enabledKey) ?? false }
        set {
            defaults?.set(newValue, forKey: enabledKey)
            logger.info("image layer lab \(newValue ? "on" : "off")")
        }
    }

    static var settings: Settings {
        get {
            let stored = defaults
            var settings = Settings()
            if let frames = stored?.object(forKey: framesKey) as? Int, frames >= minimumFrameCount {
                settings.frameCount = frames
            }
            if let side = stored?.object(forKey: sideKey) as? Int, side > 0 {
                settings.tileSide = side
            }
            if let mode = (stored?.string(forKey: modeKey)).flatMap(Mode.init(rawValue:)) {
                settings.mode = mode
            }
            return settings
        }
        set {
            defaults?.set(newValue.frameCount, forKey: framesKey)
            defaults?.set(newValue.tileSide, forKey: sideKey)
            defaults?.set(newValue.mode.rawValue, forKey: modeKey)
        }
    }

    /// Reads the lab's configuration off a launch, so a run can be driven from
    /// the command line without anyone tapping a switch.
    ///
    /// Returns nil for anything the arguments do not mention, leaving whatever
    /// was set before alone.
    static func launchOverride(in arguments: [String]) -> (enabled: Bool?, settings: Settings?) {
        var enabled: Bool?
        if arguments.contains("-MotionaryImageLabOn") { enabled = true }
        if arguments.contains("-MotionaryImageLabOff") { enabled = false }

        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag),
                  arguments.index(after: index) < arguments.endIndex
            else { return nil }
            return arguments[arguments.index(after: index)]
        }

        let frames = value("-MotionaryImageLabFrames").flatMap(Int.init)
        let side = value("-MotionaryImageLabSide").flatMap(Int.init)
        let mode = value("-MotionaryImageLabMode").flatMap(Mode.init(rawValue:))
        guard frames != nil || side != nil || mode != nil else { return (enabled, nil) }

        var settings = self.settings
        if let frames, frames >= minimumFrameCount { settings.frameCount = frames }
        if let side, side > 0 { settings.tileSide = side }
        if let mode { settings.mode = mode }
        return (enabled, settings)
    }

    // MARK: - Probe frames

    /// Where the frames live: a plain folder in the app group, written at
    /// runtime and never compiled into anything.
    static func folder(in store: DesignStore) -> URL {
        store.root.deletingLastPathComponent().appendingPathComponent("ImageLayerLab", isDirectory: true)
    }

    static func frameURL(index: Int, in store: DesignStore) -> URL {
        folder(in: store).appendingPathComponent(String(format: "frame-%03d.png", index))
    }

    static func sheetURL(in store: DesignStore) -> URL {
        folder(in: store).appendingPathComponent("sheet.png")
    }

    private static func stampURL(in store: DesignStore) -> URL {
        folder(in: store).appendingPathComponent("stamp.txt")
    }

    /// A colour per frame, evenly spaced around the hue circle.
    ///
    /// The widget is judged from a screenshot taken outside the simulator, so
    /// each frame has to be identifiable from its pixels alone. A flat, fully
    /// saturated colour survives scaling and compression well enough that the
    /// mean colour of the widget names the frame outright.
    static func probeColour(index: Int, count: Int) -> UIColor {
        UIColor(
            hue: CGFloat(index) / CGFloat(max(1, count)),
            saturation: 1,
            brightness: 1,
            alpha: 1
        )
    }

    /// Writes one flat, numbered picture per frame, unless they are already
    /// there for these settings.
    ///
    /// Deliberately generated on the device at runtime. If the widget animates
    /// these, it animates anything a phone can draw, and the whole build step
    /// this project exists to avoid is gone.
    @discardableResult
    static func writeProbeFrames(_ settings: Settings, in store: DesignStore) throws -> Int {
        let folder = folder(in: store)
        let stamp = stampURL(in: store)
        if let existing = try? String(contentsOf: stamp, encoding: .utf8), existing == settings.stamp {
            logger.info("probe frames already written for \(settings.stamp, privacy: .public)")
            return 0
        }

        do {
            if FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.removeItem(at: folder)
            }
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true,
                attributes: DesignStore.directoryAttributes
            )
        } catch {
            throw ImageLayerLabError.folderUnavailable(path: folder.path, underlying: error)
        }

        // The widget is taller than it is wide, and a frame that does not match
        // it would be scaled before it is masked - which changes the decoded
        // size and would quietly invalidate the memory numbers.
        let aspect = DeviceGeometry.widgetRect.height / max(1, DeviceGeometry.widgetRect.width)
        let size = CGSize(
            width: CGFloat(settings.tileSide),
            height: (CGFloat(settings.tileSide) * aspect).rounded()
        )

        var written = 0
        switch settings.mode {
        case .separate:
            for index in 0 ..< settings.frameCount {
                let image = probeImage(index: index, count: settings.frameCount, size: size)
                try write(image, to: frameURL(index: index, in: store))
                written += 1
            }
        case .sheet:
            let strip = probeSheet(count: settings.frameCount, frameSize: size)
            try write(strip, to: sheetURL(in: store))
            written = 1
        }

        do {
            try Data(settings.stamp.utf8).write(to: stamp, options: DesignStore.writingOptions)
        } catch {
            throw ImageLayerLabError.frameWriteFailed(path: stamp.path, underlying: error)
        }
        logger.info("wrote \(written) probe files for \(settings.stamp, privacy: .public)")
        return written
    }

    private static func write(_ image: UIImage, to url: URL) throws {
        guard let data = image.pngData() else {
            throw ImageLayerLabError.encodeFailed(path: url.lastPathComponent)
        }
        do {
            try data.write(to: url, options: DesignStore.writingOptions)
        } catch {
            throw ImageLayerLabError.frameWriteFailed(path: url.path, underlying: error)
        }
    }

    private static func probeImage(index: Int, count: Int, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            draw(index: index, count: count, in: CGRect(origin: .zero, size: size), context: context.cgContext)
        }
    }

    private static func probeSheet(count: Int, frameSize: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: frameSize.width, height: frameSize.height * CGFloat(count))
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            for index in 0 ..< count {
                draw(
                    index: index,
                    count: count,
                    in: CGRect(
                        x: 0,
                        y: frameSize.height * CGFloat(index),
                        width: frameSize.width,
                        height: frameSize.height
                    ),
                    context: context.cgContext
                )
            }
        }
    }

    private static func draw(index: Int, count: Int, in rect: CGRect, context: CGContext) {
        context.setFillColor(probeColour(index: index, count: count).cgColor)
        context.fill(rect)

        // Readable by eye as well as by mean colour: a screenshot that names
        // its own frame is worth a great deal when the alternative is deciding
        // whether two shades of orange are the same shade.
        let label = "\(index)" as NSString
        let font = UIFont.systemFont(ofSize: rect.width * 0.5, weight: .heavy)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.black,
        ]
        let bounds = label.size(withAttributes: attributes)
        UIGraphicsPushContext(context)
        label.draw(
            at: CGPoint(x: rect.midX - bounds.width / 2, y: rect.midY - bounds.height / 2),
            withAttributes: attributes
        )
        UIGraphicsPopContext()
    }
}

enum ImageLayerLabError: Error, CustomStringConvertible {
    case folderUnavailable(path: String, underlying: Error)
    case frameWriteFailed(path: String, underlying: Error)
    case encodeFailed(path: String)

    var description: String {
        switch self {
        case .folderUnavailable(let path, let underlying):
            "image lab: could not prepare \(path): \(underlying)"
        case .frameWriteFailed(let path, let underlying):
            "image lab: could not write \(path): \(underlying)"
        case .encodeFailed(let path):
            "image lab: could not encode \(path) as PNG"
        }
    }
}
