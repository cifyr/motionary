import CoreGraphics
import Foundation
import WidgetKit

/// Which Home Screen widget shape a design is cut for.
///
/// One case on purpose. Designs are cut for the tall portrait family and
/// nothing else, so the rendered size is a constant rather than something to
/// discover: no family to misreport, no table to be wrong, no size to mismatch.
/// The enum survives only so stored designs and the widget report keep reading
/// the same way.
enum WidgetSizeOption: String, Codable, CaseIterable, Identifiable, Sendable {
    case fullScreen

    var id: String { rawValue }
    var title: String { "Full screen" }

    /// Point size of the widget on the calibrated device.
    var pointSize: CGSize {
        let pixels = DeviceGeometry.pixelSize
        return CGSize(width: pixels.width / DeviceGeometry.scale, height: pixels.height / DeviceGeometry.scale)
    }

    var widgetFamily: WidgetFamily? { WidgetFamilyCompatibility.portraitFamily() }

    /// Designs saved when small, medium and large existed still name those
    /// sizes. Decoding them strictly would throw, and the store drops designs
    /// it cannot read — they would leave the library rather than fail loudly.
    init(from decoder: Decoder) throws {
        _ = try? decoder.singleValueContainer().decode(String.self)
        self = .fullScreen
    }
}

/// Pixel geometry of the one calibrated device, an iPhone 17 Pro at standard
/// Display Zoom running iOS 27.
///
/// Measured against the physical phone by the Onewheel build: the tall portrait
/// family is 358x544 points at 3x, beginning 22 points from the left edge in
/// the top slot. Everything is stated in device pixels because that is what was
/// measured. Deriving these from Apple's published point sizes put the origin
/// 7.33pt off, which showed up as the composition sitting ~22px to the right.
enum DeviceGeometry {
    static let scale: CGFloat = 3
    static let screenPixelSize = CGSize(width: 1206, height: 2622)
    static var screenPointSize: CGSize {
        CGSize(width: screenPixelSize.width / scale, height: screenPixelSize.height / scale)
    }

    static let origin = CGPoint(x: 66, y: 270)
    static let pixelSize = CGSize(width: 1074, height: 1632)

    /// The widget's pixel rect on the calibrated screen, before any nudge.
    static var widgetRect: CGRect { CGRect(origin: origin, size: pixelSize) }

    /// Widget rect with the design's manual correction applied and clamped to
    /// the screen, so a large nudge can never crop outside the composition.
    static func widgetRect(nudge: CGPoint) -> CGRect {
        let screen = CGRect(origin: .zero, size: screenPixelSize)
        let offset = widgetRect.offsetBy(dx: nudge.x, dy: nudge.y)
        let clampedX = min(max(offset.minX, 0), max(0, screen.width - offset.width))
        let clampedY = min(max(offset.minY, 0), max(0, screen.height - offset.height))
        return CGRect(origin: CGPoint(x: clampedX, y: clampedY), size: offset.size)
    }
}
