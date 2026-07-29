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
        let pixels = DeviceGeometry.pixelSize(of: self)
        return CGSize(width: pixels.width / DeviceGeometry.scale, height: pixels.height / DeviceGeometry.scale)
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

/// Pixel geometry of the one calibrated device, an iPhone 17 Pro at standard
/// Display Zoom.
///
/// Everything here is in device pixels because that is what was measured.
/// Apple's published widget point sizes do not match this device: the large
/// family measures 349.67x363.33pt against a documented 364x382, and sits
/// 26.33pt from the edge rather than 19. Using the documented numbers put the
/// origin 7.33pt too far left, which showed up as the composition sitting about
/// 22px to the right inside the widget.
enum DeviceGeometry {
    static let scale: CGFloat = 3
    static let screenPixelSize = CGSize(width: 1206, height: 2622)
    static var screenPointSize: CGSize {
        CGSize(width: screenPixelSize.width / scale, height: screenPixelSize.height / scale)
    }

    /// Measured against a physical iPhone 17 Pro by the Onewheel build.
    static let fullScreenOrigin = CGPoint(x: 66, y: 270)
    private static let fullScreenSize = CGSize(width: 1074, height: 1632)

    /// Width and origin measured from a placed large widget against the system
    /// wallpaper; the height comes from the size the system actually hands the
    /// view, which the widget reports back. A screenshot measurement had put it
    /// at 1090, two pixels short, because the antialiased edge reads as
    /// background.
    private static let standardSideMargin: CGFloat = 79
    private static let firstRowTop: CGFloat = 272
    private static let largeSize = CGSize(width: 1049, height: 1095)

    /// Derived from the large measurement by treating the large family as two
    /// grid units in each axis. `largeWidth = 2*unit + horizontalGutter` and
    /// `largeHeight = 2*unit + verticalGutter`, taking the horizontal gutter to
    /// equal the side margin as iOS layouts generally do. Small and medium are
    /// therefore predictions, not measurements, and remain nudgeable.
    private static let horizontalGutter: CGFloat = standardSideMargin
    private static var unit: CGFloat { (largeSize.width - horizontalGutter) / 2 }
    private static var verticalGutter: CGFloat { largeSize.height - 2 * unit }
    private static var rowPitch: CGFloat { unit + verticalGutter }

    static func pixelSize(of size: WidgetSizeOption) -> CGSize {
        switch size {
        case .small: CGSize(width: unit, height: unit)
        case .medium: CGSize(width: largeSize.width, height: unit)
        case .large: largeSize
        case .fullScreen: fullScreenSize
        }
    }

    /// The widget's pixel rect on the calibrated screen, before any nudge.
    static func widgetRect(size: WidgetSizeOption, slot: WidgetSlot) -> CGRect {
        let pixels = pixelSize(of: size)
        let grid = size.slotGrid

        let column = min(max(slot.column, 0), grid.columns - 1)
        let row = min(max(slot.row, 0), grid.rows - 1)

        let x: CGFloat
        switch size {
        case .fullScreen:
            x = fullScreenOrigin.x
        case .small:
            // Two horizontal positions: flush to the left margin or the right.
            x = column == 0
                ? standardSideMargin
                : screenPixelSize.width - standardSideMargin - pixels.width
        case .medium, .large:
            x = standardSideMargin
        }

        let y: CGFloat = size == .fullScreen
            ? fullScreenOrigin.y
            : firstRowTop + CGFloat(row) * rowPitch

        return CGRect(origin: CGPoint(x: x, y: y), size: pixels)
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
