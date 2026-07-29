import CoreGraphics
import Foundation
import WidgetKit

/// Which Home Screen widget shape a design is cut for.
enum WidgetSizeOption: String, Codable, CaseIterable, Identifiable, Sendable {
    case small
    case medium
    case large
    case fullScreen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .fullScreen: "Full screen"
        }
    }

    /// Point size of the widget on the calibrated device.
    var pointSize: CGSize {
        switch self {
        case .small: CGSize(width: 170, height: 170)
        case .medium: CGSize(width: 364, height: 170)
        case .large: CGSize(width: 364, height: 382)
        case .fullScreen: CGSize(width: 358, height: 544)
        }
    }

    /// How many slot positions exist across and down the Home Screen.
    var slotGrid: (columns: Int, rows: Int) {
        switch self {
        case .small: (2, 3)
        case .medium: (1, 3)
        case .large: (1, 2)
        case .fullScreen: (1, 1)
        }
    }

    var widgetFamily: WidgetFamily? {
        switch self {
        case .small: .systemSmall
        case .medium: .systemMedium
        case .large: .systemLarge
        // The tall portrait family only exists on newer systems; the
        // compatibility shim decides whether it can actually be offered.
        case .fullScreen: WidgetFamilyCompatibility.portraitFamily()
        }
    }
}

/// Where on the Home Screen the widget sits, so the composition can be cropped
/// to exactly the pixels that widget will cover.
struct WidgetSlot: Codable, Equatable, Hashable, Sendable {
    var column: Int
    var row: Int

    static let topLeft = WidgetSlot(column: 0, row: 0)
}

/// Pixel geometry of the one calibrated device.
///
/// Only the full-screen slot is measured: it is inherited from the Onewheel
/// build that was verified against a physical iPhone 17 Pro. Every other family
/// is derived from Apple's published point sizes for a 402x874pt screen and
/// should be treated as a starting point, which is why each design carries its
/// own nudge offset.
enum DeviceGeometry {
    static let scale: CGFloat = 3
    static let screenPixelSize = CGSize(width: 1206, height: 2622)
    static var screenPointSize: CGSize {
        CGSize(width: screenPixelSize.width / scale, height: screenPixelSize.height / scale)
    }

    /// Measured origin of the tall portrait widget in the top slot, in pixels.
    static let fullScreenOrigin = CGPoint(x: 66, y: 270)

    /// Horizontal inset of the standard families, in points.
    private static let standardSideMargin: CGFloat = 19
    /// Vertical distance between consecutive widget rows, in points. Derived
    /// from a 170pt small widget plus the Home Screen's inter-widget gap.
    private static let rowPitch: CGFloat = 191
    /// Top of the first widget row, in points, shared with the measured
    /// full-screen origin.
    private static var firstRowTop: CGFloat { fullScreenOrigin.y / scale }

    /// The widget's pixel rect on the calibrated screen, before any nudge.
    static func widgetRect(size: WidgetSizeOption, slot: WidgetSlot) -> CGRect {
        let points = size.pointSize
        let grid = size.slotGrid

        let column = min(max(slot.column, 0), grid.columns - 1)
        let row = min(max(slot.row, 0), grid.rows - 1)

        let x: CGFloat
        switch size {
        case .fullScreen:
            x = fullScreenOrigin.x / scale
        case .small:
            // Two horizontal positions: flush left column pair, or right pair.
            x = column == 0
                ? standardSideMargin
                : screenPointSize.width - standardSideMargin - points.width
        case .medium, .large:
            x = standardSideMargin
        }

        let y: CGFloat = size == .fullScreen
            ? fullScreenOrigin.y / scale
            : firstRowTop + CGFloat(row) * rowPitch

        return CGRect(
            x: x * scale,
            y: y * scale,
            width: points.width * scale,
            height: points.height * scale
        )
    }

    /// Widget rect with the design's manual correction applied and clamped to
    /// the screen, so a large nudge can never crop outside the composition.
    static func widgetRect(size: WidgetSizeOption, slot: WidgetSlot, nudge: CGPoint) -> CGRect {
        let base = widgetRect(size: size, slot: slot)
        let screen = CGRect(origin: .zero, size: screenPixelSize)
        let offset = base.offsetBy(dx: nudge.x, dy: nudge.y)
        let clampedX = min(max(offset.minX, 0), max(0, screen.width - offset.width))
        let clampedY = min(max(offset.minY, 0), max(0, screen.height - offset.height))
        return CGRect(origin: CGPoint(x: clampedX, y: clampedY), size: offset.size)
    }
}
