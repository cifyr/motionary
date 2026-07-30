import Foundation
import SwiftUI
import os

/// A widget filled with pixels whose every value is known, so what the Home
/// Screen does to the edge can be read off a photograph of it.
///
/// The system composites the widget itself, and whatever it does to the border -
/// a rim highlight, a refraction of the content behind it, nothing at all - is
/// invisible from inside the extension. Cancelling that effect means knowing its
/// shape first, and the only way to get it is to draw a known target, photograph
/// the Home Screen, and subtract.
///
/// The target answers three questions at once:
/// - where the widget's boundary really is, from which of the coloured rings
///   survive at the edge (the frame in `DeviceGeometry` is a measurement, and a
///   pixel of drift there is itself a visible line);
/// - whether the edge adds or scales light, from how the flat grey bands deviate
///   near it - two levels distinguish an offset from a gain;
/// - whether it displaces content, from whether the grid lines bend as they
///   approach it.
enum EdgeLab {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "EdgeLab")
    private static let flagKey = "edgeLabEnabled"

    static var isEnabled: Bool {
        get { UserDefaults(suiteName: DesignStore.appGroupIdentifier)?.bool(forKey: flagKey) ?? false }
        set {
            UserDefaults(suiteName: DesignStore.appGroupIdentifier)?.set(newValue, forKey: flagKey)
            logger.info("edge lab \(newValue ? "on" : "off")")
        }
    }

    /// Switched from a launch argument, so a run needs nobody to tap anything.
    static func launchOverride(in arguments: [String]) -> Bool? {
        if arguments.contains("-MotionaryEdgeLabOn") { return true }
        if arguments.contains("-MotionaryEdgeLabOff") { return false }
        return nil
    }

    /// One saturated 1px ring per pixel of inset from the widget's own bounds.
    ///
    /// Pure primaries, and pure for a reason: any blend the system applies shows
    /// up as a channel that should be 0 or 255 and is not. Which ring lands on
    /// which screen row also fixes the boundary to the pixel.
    static let rings: [(inset: Int, name: String, rgb: (Double, Double, Double))] = [
        (0, "red", (1, 0, 0)),
        (1, "green", (0, 1, 0)),
        (2, "blue", (0, 0, 1)),
        (3, "yellow", (1, 1, 0)),
    ]

    /// Where the flat field starts, leaving the rings their own pixels.
    static let fieldInset = 4

    /// Grey levels for the horizontal bands, as fractions of full white.
    ///
    /// Three, not one: an additive rim shifts every level by the same amount and
    /// a multiplicative one shifts them in proportion, which one level cannot
    /// tell apart. Mid-range values, so a rim has room to move them in either
    /// direction without clipping.
    static let bandLevels: [Double] = [0.25, 0.5, 0.75]
    static let bandHeightPixels = 96
    /// 1px white lines, far enough apart that a band still reads between them
    /// and close enough that a displacement near the edge has a line to bend.
    static let gridSpacingPixels = 24

    static func bandLevel(atPixelY y: Int) -> Double {
        let index = (max(0, y) / bandHeightPixels) % bandLevels.count
        return bandLevels[index]
    }

    static func isGridLine(pixel: Int) -> Bool {
        pixel > 0 && pixel % gridSpacingPixels == 0
    }
}
