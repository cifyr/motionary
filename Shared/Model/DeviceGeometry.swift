import CoreGraphics
import Foundation
import os
#if os(iOS)
import UIKit
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

    /// Side of a Home Screen app icon, in screen pixels.
    let iconSide: CGFloat
    /// Top left of the first icon - row 1, column 1 - in screen pixels.
    let iconGridOrigin: CGPoint
    /// Centre-to-centre spacing of the icon grid, in screen pixels.
    let iconGridPitch: CGSize

    /// Where an app icon sits on the Home Screen, in screen pixels.
    func iconRect(row: Int, column: Int) -> CGRect {
        CGRect(
            x: iconGridOrigin.x + iconGridPitch.width * CGFloat(column),
            y: iconGridOrigin.y + iconGridPitch.height * CGFloat(row),
            width: iconSide,
            height: iconSide
        )
    }

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
    /// first measurement came out 5px narrow and 13px short.
    ///
    /// The origin came from differencing a Home Screen screenshot against the
    /// app's own full-screen render of the same design: the widget's content sat
    /// 2px left of the wallpaper's and dead on vertically. The extent came from
    /// the `EdgeLab` ring target on the device, whose outermost 1px ring lands on
    /// the view's own bounds - rows 270 and 1914, columns 64 and 1142. Both agree
    /// on the origin, and the rings are what the extent is taken from: the
    /// outermost column carries the rim, so it correlates too poorly to be found
    /// by differencing, which is what put an earlier reading a pixel short.
    ///
    /// So the widget grows 2px left, 3px right and 13px down of the cut frame. It
    /// is not simply the cut frame re-centred - the left and right margins come
    /// out 64 and 63 - and there is no known reason for that asymmetry, only the
    /// measurement.
    ///
    /// The icon grid was read off a 1206x2622 Home Screen screenshot from the
    /// phone: icons are 192px square, the first starts at (91, 270), column
    /// lefts run 91, 368, 647, 924 and row tops 270, 571, 872, 1173, 1474,
    /// 1775. So the row pitch is exactly 301 and the column pitch averages
    /// 277.67 - iOS distributes the column rounding as 277, 279, 277, which a
    /// single number cannot reproduce, so columns 2 and 3 land within a pixel
    /// rather than dead on.
    ///
    /// The grid had been divided out of the widget frame instead, at a 272 row
    /// pitch, which drifted from 40px below the real icons at row 1 to 105px
    /// above them at row 6.
    static let iPhone17Pro = DeviceModel(
        id: "iphone17pro",
        name: "iPhone 17 Pro",
        scale: 3,
        screenPixelSize: CGSize(width: 1206, height: 2622),
        widgetOrigin: CGPoint(x: 66, y: 270),
        widgetPixelSize: CGSize(width: 1074, height: 1632),
        widgetRenderedOrigin: CGPoint(x: 64, y: 270),
        widgetRenderedPixelSize: CGSize(width: 1079, height: 1645),
        widgetCornerRadius: 78,
        iconSide: 192,
        iconGridOrigin: CGPoint(x: 91, y: 270),
        iconGridPitch: CGSize(width: 833.0 / 3, height: 301)
    )

    static let all: [DeviceModel] = [.iPhone17Pro]
    static let `default` = iPhone17Pro

    /// A model for a screen nobody has measured, scaled from the one that was.
    ///
    /// **This is an approximation and it is allowed to exist for one reason:**
    /// what it replaces is not an approximation but a certainty of being wrong.
    /// Every phone that is not an iPhone 17 Pro was being handed a 1206x2622
    /// composition for its own screen - a wallpaper of entirely the wrong size,
    /// out by 36x90px on a 16e and 114x246px on a 17 Pro Max. Proportions that
    /// are a few pixels out beat a picture that is the wrong shape.
    ///
    /// Deriving from Apple's published *point* sizes was tried before this and
    /// put the origin 7.33pt out - about 22px right - on the one device that was
    /// checked. See the note on `DeviceModel` above; that warning stands, and it
    /// is why nothing here claims to be measured. This derivation is a different
    /// one: every number is carried across as a fraction of the measured phone's
    /// own screen, so the composition keeps its proportions and stays on screen.
    ///
    /// The parts most likely to be wrong are the icon grid and the corner
    /// radius. iOS sizes icons in points per device class rather than as a
    /// fraction of the screen, so on a phone with a different class this grid
    /// will drift across the rows. `widgetNudge` is the escape hatch, per design.
    static func derived(
        id: String,
        name: String,
        scale: CGFloat,
        screenPixelSize size: CGSize
    ) -> DeviceModel {
        let base = iPhone17Pro
        let kx = size.width / base.screenPixelSize.width
        let ky = size.height / base.screenPixelSize.height
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x * kx).rounded(), y: (p.y * ky).rounded()) }
        func span(_ s: CGSize) -> CGSize { CGSize(width: (s.width * kx).rounded(), height: (s.height * ky).rounded()) }

        return DeviceModel(
            id: id,
            name: name,
            scale: scale,
            screenPixelSize: size,
            widgetOrigin: point(base.widgetOrigin),
            widgetPixelSize: span(base.widgetPixelSize),
            widgetRenderedOrigin: point(base.widgetRenderedOrigin),
            widgetRenderedPixelSize: span(base.widgetRenderedPixelSize),
            // Corners scale with the narrow axis; scaling them by height would
            // make a taller phone's widget read as a rounder rectangle.
            widgetCornerRadius: (base.widgetCornerRadius * kx).rounded(),
            iconSide: (base.iconSide * kx).rounded(),
            iconGridOrigin: point(base.iconGridOrigin),
            iconGridPitch: CGSize(
                width: base.iconGridPitch.width * kx,
                height: base.iconGridPitch.height * ky
            )
        )
    }

    /// The model for a screen of this size: the measured one when it matches,
    /// and a derived one when it does not.
    ///
    /// Matching on the screen rather than on a device identifier on purpose.
    /// There is no list of identifiers to keep current, a Display Zoom setting
    /// changes the screen out from under one anyway, and what every number here
    /// is actually a function of is the screen.
    static func matching(screenPixelSize size: CGSize, scale: CGFloat) -> DeviceModel {
        if let exact = all.first(where: { $0.screenPixelSize == size && $0.scale == scale }) {
            return exact
        }
        let points = CGSize(width: size.width / scale, height: size.height / scale)
        return derived(
            id: "derived-\(Int(size.width))x\(Int(size.height))",
            name: "\(Int(points.width)) x \(Int(points.height)) pt",
            scale: scale,
            screenPixelSize: size
        )
    }

    /// Whether this model's numbers were measured against hardware or scaled
    /// from a phone that was.
    ///
    /// Read at runtime, where it decides what the phone logs about its own
    /// geometry. Not in the editor: `all` holds one entry, so the studio only
    /// ever offers the measured phone and a derived model cannot appear in its
    /// picker.
    var isMeasured: Bool { Self.all.contains(self) }
}

/// Pixel geometry of the phone this is running on.
///
/// Still a set of globals, and still settled once: a screen does not change
/// size while an app is open, and the fonts a font-built design needs are in
/// the bundle either way. What changed is where the numbers come from. They
/// were the iPhone 17 Pro's, compiled in, on every phone that ran this - so a
/// 16e composed its Home Screen at 1206x2622 and missed its own icon grid by
/// 36x90px. On iOS the screen is now read at launch and the model matched to
/// it; on the Mac there is no screen to read, so the studio keeps choosing.
///
/// A derived model is an approximation - see `DeviceModel.derived` - and says
/// so in the log at launch, because a design shown on one wants checking
/// against the real Home Screen before its placement is trusted.
enum DeviceGeometry {
#if os(iOS)
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "DeviceGeometry")

    /// Resolved once from the screen, then read from anywhere.
    ///
    /// Not a lazy `static let` reading `UIScreen`, because that is main-actor
    /// isolated and this is read from the render pipeline off the main thread.
    /// So the reading is an explicit step the app and the extension each take
    /// on the way up, and until it happens the measured model stands in - which
    /// is exactly what every build did before this, so the worst case is the
    /// behaviour that shipped rather than a new one.
    nonisolated(unsafe) private static var resolved: DeviceModel?

    static var model: DeviceModel { resolved ?? .default }

    /// Reads the screen and settles the geometry. Safe to call more than once;
    /// a screen does not change size while a process is alive.
    @MainActor
    static func resolveFromScreen() {
        guard resolved == nil else { return }
        let screen = UIScreen.main
        let scale = screen.scale
        let bounds = screen.bounds.size
        let pixels = CGSize(
            width: (bounds.width * scale).rounded(),
            height: (bounds.height * scale).rounded()
        )
        let matched = DeviceModel.matching(screenPixelSize: pixels, scale: scale)
        resolved = matched
        if matched.isMeasured {
            logger.info("geometry: \(matched.name, privacy: .public), measured")
        } else {
            logger.notice("""
            no measured geometry for \(Int(pixels.width))x\(Int(pixels.height)) at \(scale, format: .fixed(precision: 1))x; \
            scaling the iPhone 17 Pro's - positions are approximate
            """)
        }
    }
#else
    static let model = DeviceModel.default
#endif

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
