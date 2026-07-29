import CoreGraphics
import Foundation

/// One app tile placed on the composition.
///
/// Positions are stored in screen pixel space so the editor, the exported
/// wallpaper, and the widget crop all read the same numbers.
struct PlacedTile: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var appID: String
    var center: CGPoint
    var size: CGFloat
    var cornerRadius: CGFloat = 0.22
    var showsLabel: Bool = true
    var opacity: Double = 1
    /// Chosen from the Iconify catalogue. Nil falls back to the catalogue
    /// entry's SF Symbol, so designs made before icons existed still draw.
    var icon: IconAsset?
    /// Overrides the catalogue's brand tint for the plate behind the icon.
    var tintHex: String?

    var rect: CGRect {
        CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
    }
}

/// Everything needed to rebuild and render a design.
struct DesignDocument: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date
    var updatedAt: Date

    /// Filename of the imported source video inside the design's folder.
    var sourceVideoName: String

    // Loop selection
    var loopStartFrame: Int = 0
    var loopFrameCount: Int = 32

    // Output shape
    var widgetSize: WidgetSizeOption = .fullScreen
    var widgetSlot: WidgetSlot = .topLeft
    /// Manual pixel correction for the widget rect. Every family except the
    /// measured full-screen slot is derived, so this is the escape hatch.
    var widgetNudge: CGPoint = .zero

    var smoothness: MotionSmoothness = .standard
    var jpegQuality: Double = 0.62

    /// Region of the screen the animation replaces, in pixels. Auto-detected at
    /// import and then adjustable.
    var animationCrop: CGRect
    var tiles: [PlacedTile] = []
    var snapEnabled: Bool = true

    /// Bumped whenever a regenerated font set is written, so the widget can
    /// tell a stale render from a current one.
    var buildGeneration: Int = 0

    var spec: TimerFontSpec { TimerFontSpec(smoothness: smoothness) }

    var widgetRect: CGRect {
        DeviceGeometry.widgetRect(size: widgetSize, slot: widgetSlot, nudge: widgetNudge)
    }

    /// Only pixels inside the widget are ever drawn, so the encoded crop is the
    /// intersection. This is what makes a small widget far cheaper than a
    /// full-screen one rather than merely smaller on screen.
    var effectiveCrop: CGRect {
        let intersection = animationCrop.intersection(widgetRect)
        return intersection.isNull ? .zero : intersection.integral
    }

    /// Font family prefix. Per-design so two designs can be registered in the
    /// same extension process without colliding.
    var fontFamilyBase: String {
        "MFont\(id.uuidString.prefix(8).lowercased())L"
    }

    static func new(name: String, sourceVideoName: String) -> DesignDocument {
        let now = Date()
        return DesignDocument(
            name: name,
            createdAt: now,
            updatedAt: now,
            sourceVideoName: sourceVideoName,
            animationCrop: CGRect(origin: .zero, size: DeviceGeometry.screenPixelSize)
        )
    }
}

/// What a completed build produced, written next to the fonts so the widget can
/// validate before it tries to render.
struct BuildManifest: Codable, Equatable, Sendable {
    var designID: UUID
    var buildGeneration: Int
    var fontFamilyBase: String
    var laneCount: Int
    var framesPerSecond: Int
    var loopFrameCount: Int
    var animationCrop: CGRect
    var widgetRect: CGRect
    var screenSize: CGSize
    var wallpaperName: String
    var totalFontBytes: Int
    var builtAt: Date

    var spec: TimerFontSpec {
        TimerFontSpec(laneCount: laneCount, framesPerSecond: framesPerSecond)
    }
}
