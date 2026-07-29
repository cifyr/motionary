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
    /// Clockwise rotation in degrees, so tiles can follow an angled element in
    /// the footage instead of always sitting square to the screen.
    var rotation: Double = 0

    var rect: CGRect {
        CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
    }

    /// Width of the tile's axis-aligned bounding box once rotated. A tile at
    /// 45 degrees reaches about 1.41x its side, so clamping against `size`
    /// alone would let a corner hang off the screen.
    var boundingExtent: CGFloat {
        let radians = rotation * .pi / 180
        return size * (abs(cos(radians)) + abs(sin(radians)))
    }

    init(
        id: UUID = UUID(),
        appID: String,
        center: CGPoint,
        size: CGFloat,
        cornerRadius: CGFloat = 0.22,
        showsLabel: Bool = true,
        opacity: Double = 1,
        icon: IconAsset? = nil,
        tintHex: String? = nil,
        rotation: Double = 0
    ) {
        self.id = id
        self.appID = appID
        self.center = center
        self.size = size
        self.cornerRadius = cornerRadius
        self.showsLabel = showsLabel
        self.opacity = opacity
        self.icon = icon
        self.tintHex = tintHex
        self.rotation = rotation
    }

    /// Decoded field by field rather than by the synthesised initialiser.
    ///
    /// Swift does not fall back to a property's default when a key is absent,
    /// so a design written before a field existed would fail to decode
    /// entirely — and the store skips designs it cannot read, which would make
    /// them disappear from the library rather than fail loudly.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        appID = try container.decode(String.self, forKey: .appID)
        center = try container.decode(CGPoint.self, forKey: .center)
        size = try container.decode(CGFloat.self, forKey: .size)
        cornerRadius = try container.decodeIfPresent(CGFloat.self, forKey: .cornerRadius) ?? 0.22
        showsLabel = try container.decodeIfPresent(Bool.self, forKey: .showsLabel) ?? true
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        icon = try container.decodeIfPresent(IconAsset.self, forKey: .icon)
        tintHex = try container.decodeIfPresent(String.self, forKey: .tintHex)
        rotation = try container.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
    }
}

/// Everything needed to rebuild and render a design.
struct DesignDocument: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date
    var updatedAt: Date

    /// Filename of the imported source inside the design's folder.
    var sourceVideoName: String
    /// How the imported media is fitted to the screen before rendering.
    var mediaTransform: MediaTransform = .identity
    /// How fast to move through the source. 2 plays it twice as fast, 0.5 half.
    /// A slow GIF can be sped up to read as motion rather than a drift.
    var playbackSpeed: Double = 1
    /// The source's own length, kept so the editor can resize the loop when the
    /// speed changes without decoding the file again.
    var sourceDuration: TimeInterval = 0

    // Loop selection
    var loopStartFrame: Int = 0
    var loopFrameCount: Int = 32

    // Output shape
    var widgetSize: WidgetSizeOption = .fullScreen
    /// Manual pixel correction for the widget rect, in case a phone seats the
    /// widget a pixel or two off the calibrated origin.
    var widgetNudge: CGPoint = .zero

    var smoothness: MotionSmoothness = .standard
    var jpegQuality: Double = 0.62

    /// Draws the animated layer at all. Off leaves the still backdrop, which is
    /// both a usable widget and the way to tell a broken animation layer from a
    /// broken picture: the two are indistinguishable when the result is black.
    var animationEnabled: Bool = true

    /// Region of the screen the animation replaces, in pixels. Auto-detected at
    /// import and then adjustable.
    var animationCrop: CGRect
    var tiles: [PlacedTile] = []
    var snapEnabled: Bool = true

    /// Bumped whenever a regenerated font set is written, so the widget can
    /// tell a stale render from a current one.
    var buildGeneration: Int = 0

    var spec: TimerFontSpec { TimerFontSpec(smoothness: smoothness) }

    /// Frames the source fills at the current speed, for sizing the loop.
    var naturalLoopFrames: Int {
        guard sourceDuration > 0 else { return loopFrameCount }
        let frames = sourceDuration * Double(spec.framesPerSecond) / max(playbackSpeed, 0.01)
        return max(1, Int(frames.rounded()))
    }

    /// Re-sizes the loop to the source's own length at the current frame rate.
    ///
    /// Changing smoothness changes the frame rate, so a loop chosen under the
    /// old one plays at the wrong speed — 40 frames is 1.25s at 32fps but 2.5s
    /// at 16fps, and the same clip suddenly runs at half speed.
    mutating func retuneLoop(maximum: Int = 96) {
        guard sourceDuration > 0 else { return }
        loopFrameCount = spec.seamlessLoopLength(nearest: naturalLoopFrames, maximum: maximum)
    }

    /// How long the built loop runs on screen.
    var loopDuration: TimeInterval {
        Double(loopFrameCount) / Double(spec.framesPerSecond)
    }

    var widgetRect: CGRect {
        DeviceGeometry.widgetRect(nudge: widgetNudge)
    }

    /// Only pixels inside the widget are ever drawn, so the encoded crop is the
    /// intersection: motion outside the widget frame costs nothing to skip.
    var effectiveCrop: CGRect {
        let intersection = animationCrop.intersection(widgetRect)
        return intersection.isNull ? .zero : intersection.integral
    }

    /// Whether there is anything to animate. A crop that misses the widget
    /// frame entirely builds nothing, and is worth catching before a build
    /// rather than as an error at the end of one.
    var hasAnimatedArea: Bool {
        let crop = effectiveCrop
        return crop.width >= 2 && crop.height >= 2
    }

    /// A detected motion box reduced to something that can actually be built.
    /// Motion outside the widget frame is never drawn, so a box that misses it
    /// is no better than no box at all — fall back to the whole frame.
    static func usableCrop(_ detected: CGRect, in widgetRect: CGRect) -> CGRect {
        let clamped = detected.intersection(widgetRect)
        guard !clamped.isNull, clamped.width >= 2, clamped.height >= 2 else { return widgetRect }
        return clamped.integral
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

    /// Tolerant of absent keys for the same reason `PlacedTile` is: a design
    /// written before a field existed must still open, because the store skips
    /// designs it cannot decode and they would quietly leave the library.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        sourceVideoName = try container.decode(String.self, forKey: .sourceVideoName)
        mediaTransform = try container.decodeIfPresent(MediaTransform.self, forKey: .mediaTransform) ?? .identity
        playbackSpeed = try container.decodeIfPresent(Double.self, forKey: .playbackSpeed) ?? 1
        sourceDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .sourceDuration) ?? 0
        loopStartFrame = try container.decodeIfPresent(Int.self, forKey: .loopStartFrame) ?? 0
        loopFrameCount = try container.decodeIfPresent(Int.self, forKey: .loopFrameCount) ?? 32
        widgetSize = try container.decodeIfPresent(WidgetSizeOption.self, forKey: .widgetSize) ?? .fullScreen
        widgetNudge = try container.decodeIfPresent(CGPoint.self, forKey: .widgetNudge) ?? .zero
        smoothness = try container.decodeIfPresent(MotionSmoothness.self, forKey: .smoothness) ?? .standard
        jpegQuality = try container.decodeIfPresent(Double.self, forKey: .jpegQuality) ?? 0.62
        animationEnabled = try container.decodeIfPresent(Bool.self, forKey: .animationEnabled) ?? true
        animationCrop = try container.decode(CGRect.self, forKey: .animationCrop)
        tiles = try container.decodeIfPresent([PlacedTile].self, forKey: .tiles) ?? []
        snapEnabled = try container.decodeIfPresent(Bool.self, forKey: .snapEnabled) ?? true
        buildGeneration = try container.decodeIfPresent(Int.self, forKey: .buildGeneration) ?? 0
    }

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date,
        updatedAt: Date,
        sourceVideoName: String,
        animationCrop: CGRect
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceVideoName = sourceVideoName
        self.animationCrop = animationCrop
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

    /// Screen-space rect covered by the pre-cropped widget backdrop, when one
    /// was baked. Optional so manifests written before it existed still decode
    /// — the widget falls back to the full-screen wallpaper for those.
    var backdropRect: CGRect?

    /// The app tiles to draw over the animation.
    ///
    /// They travel in the manifest because it is the only part of a design
    /// that ships inside the app: the widget has no other way to reach what
    /// was placed on the canvas.
    ///
    /// Optional rather than defaulted, because Swift's synthesised decoding
    /// does not apply property defaults to missing keys. A manifest written
    /// before this existed would throw, and a design that will not decode is
    /// silently dropped rather than reported.
    var tiles: [PlacedTile]?

    var placedTiles: [PlacedTile] { tiles ?? [] }

    var spec: TimerFontSpec {
        TimerFontSpec(laneCount: laneCount, framesPerSecond: framesPerSecond)
    }
}
