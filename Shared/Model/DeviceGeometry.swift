import CoreGraphics
import Foundation
#if os(iOS)
import WidgetKit
#endif

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

#if os(iOS)
    var widgetFamily: WidgetFamily? { WidgetFamilyCompatibility.portraitFamily() }
#endif

    /// Designs saved when small, medium and large existed still name those
    /// sizes. Decoding them strictly would throw, and the store drops designs
    /// it cannot read — they would leave the library rather than fail loudly.
    init(from decoder: Decoder) throws {
        _ = try? decoder.singleValueContainer().decode(String.self)
        self = .fullScreen
    }
}

/// A phone a design can be cut for.
///
/// Only devices whose numbers were measured against real hardware belong here.
/// Deriving them from Apple's published point sizes put the origin 7.33pt out
/// on the one device that was checked, which showed as the composition sitting
/// about 22px to the right - so a derived entry would look plausible in the
/// picker and be visibly wrong on the Home Screen.
struct DeviceModel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let scale: CGFloat
    /// Everything is stated in device pixels, because that is what was measured.
    let screenPixelSize: CGSize
    /// The frame a design is cut to: where tiles snap and how much backdrop is
    /// baked. Smaller than what the system hands over, which is why the backdrop
    /// is padded.
    let widgetOrigin: CGPoint
    let widgetPixelSize: CGSize
    /// The frame the system really hands the extension.
    ///
    /// Content is laid out from *this* origin, so the widget must be told this
    /// rect and not the cut frame above: believing the cut origin drew every
    /// design two pixels left of the wallpaper behind it.
    let widgetRenderedOrigin: CGPoint
    let widgetRenderedPixelSize: CGSize
    /// Corner radius of the widget, in screen pixels.
    ///
    /// Estimated rather than measured: iOS derives a widget's corners from its
    /// container and does not publish the number. It matters because the clip
    /// is confined to this shape when a background is chosen, so a radius that
    /// is too small leaves the clip's square corners showing in the wallpaper
    /// where the background should be. Adjustable per design for that reason.
    var widgetCornerRadius: CGFloat = 78

    var widgetRect: CGRect { CGRect(origin: widgetOrigin, size: widgetPixelSize) }

    var widgetRenderedRect: CGRect {
        CGRect(origin: widgetRenderedOrigin, size: widgetRenderedPixelSize)
    }

    var screenPointSize: CGSize {
        CGSize(width: screenPixelSize.width / scale, height: screenPixelSize.height / scale)
    }

    var widgetPointSize: CGSize {
        CGSize(width: widgetPixelSize.width / scale, height: widgetPixelSize.height / scale)
    }

    /// Measured against the physical phone by the Onewheel build: the tall
    /// portrait family is 358x544 points at 3x, beginning 22 points from the
    /// left edge in the top slot, at standard Display Zoom on iOS 27.
    ///
    /// The rendered frame was measured separately, and differently, because that
    /// first measurement came out 4px narrow and 13px short. A Home Screen
    /// screenshot differenced against the app's own full-screen render of the
    /// same design puts the widget's content 2px left of the wallpaper's, dead
    /// on vertically, with the displacement falling to zero outside columns 64
    /// and 1141 and below row 1914. 1078 centred on 1206 begins at exactly 64,
    /// so the two pixels are the width error halved - not an origin of its own.
    /// The extra height lands entirely at the bottom; the slot's top is fixed.
    static let iPhone17Pro = DeviceModel(
        id: "iphone17pro",
        name: "iPhone 17 Pro",
        scale: 3,
        screenPixelSize: CGSize(width: 1206, height: 2622),
        widgetOrigin: CGPoint(x: 66, y: 270),
        widgetPixelSize: CGSize(width: 1074, height: 1632),
        widgetRenderedOrigin: CGPoint(x: 64, y: 270),
        widgetRenderedPixelSize: CGSize(width: 1078, height: 1645),
        widgetCornerRadius: 78
    )

    static let all: [DeviceModel] = [.iPhone17Pro]
    static let `default` = iPhone17Pro
}

/// Pixel geometry of the device this build is cut for.
///
/// Still a set of globals because the iOS app and the extension are compiled
/// for exactly one phone: the fonts are in the bundle, so the geometry is
/// settled at build time too. The studio picks the model; this is what the
/// build was given.
enum DeviceGeometry {
    static let model = DeviceModel.default

    static var scale: CGFloat { model.scale }
    static var screenPixelSize: CGSize { model.screenPixelSize }
    static var screenPointSize: CGSize { model.screenPointSize }

    static var origin: CGPoint { model.widgetOrigin }
    static var pixelSize: CGSize { model.widgetPixelSize }

    /// The widget's pixel rect on the calibrated screen, before any nudge.
    static var widgetRect: CGRect { model.widgetRect }

    /// What the system hands the extension, which is what the extension has to
    /// lay its content out from. Larger than `widgetRect` and starting 2px to
    /// the left of it - see `DeviceModel.iPhone17Pro`.
    static var renderedWidgetRect: CGRect { model.widgetRenderedRect }

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
