import CoreGraphics
import Foundation

/// One slot of the widget's tile grid, numbered from the top left.
struct GridCell: Codable, Equatable, Hashable, Sendable {
    var row: Int
    var column: Int

    /// How the editor names a cell: R1C1 is the top left.
    var label: String { "R\(row + 1)C\(column + 1)" }
}

/// The grid tiles land on inside the widget frame.
///
/// An aid, not a constraint: a tile may sit off grid, because the wallpaper
/// carries a baked picture of anything crossing the frame's edge. What the
/// grid buys is that adding apps never stacks them and a row can be made
/// without measuring.
struct WidgetGrid: Codable, Equatable, Sendable {
    var columns: Int = 4
    var rows: Int = 2
    /// Inset from the widget frame's edges, in screen pixels.
    var margin: CGFloat = 56
    /// Gutter between cells, in screen pixels.
    var gap: CGFloat = 40

    var cellCount: Int { max(columns, 1) * max(rows, 1) }

    var allCells: [GridCell] {
        (0 ..< max(rows, 1)).flatMap { row in
            (0 ..< max(columns, 1)).map { GridCell(row: row, column: $0) }
        }
    }

    func cellRect(_ cell: GridCell, in frame: CGRect) -> CGRect {
        let columns = max(self.columns, 1)
        let rows = max(self.rows, 1)
        // Clamped so a wide gutter on a narrow frame cannot invert the cell.
        let width = max(1, (frame.width - margin * 2 - gap * CGFloat(columns - 1)) / CGFloat(columns))
        let height = max(1, (frame.height - margin * 2 - gap * CGFloat(rows - 1)) / CGFloat(rows))
        return CGRect(
            x: frame.minX + margin + (width + gap) * CGFloat(cell.column),
            y: frame.minY + margin + (height + gap) * CGFloat(cell.row),
            width: width,
            height: height
        )
    }

    func cellCenter(_ cell: GridCell, in frame: CGRect) -> CGPoint {
        let rect = cellRect(cell, in: frame)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    /// A square that fits any cell, which is what a tile is sized to by
    /// default - tiles are square and cells need not be.
    func tileSide(in frame: CGRect) -> CGFloat {
        let rect = cellRect(GridCell(row: 0, column: 0), in: frame)
        return max(40, min(rect.width, rect.height))
    }

    func nearestCell(to point: CGPoint, in frame: CGRect) -> GridCell? {
        allCells.min {
            cellCenter($0, in: frame).distance(to: point) < cellCenter($1, in: frame).distance(to: point)
        }
    }

    /// The first cell nothing occupies, in reading order. Nil when the grid is
    /// full, which the editor reports rather than silently stacking.
    func firstFreeCell(occupied: Set<GridCell>) -> GridCell? {
        allCells.first { !occupied.contains($0) }
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        let dx = x - other.x
        let dy = y - other.y
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// An app the phone may put in a tile's slot instead of the authored one.
///
/// The authored `appID` on the tile is the default occupant - the first of the
/// slot's list - and these are the rest of it. An alternate's artwork is a skin
/// or nothing: the catalogue's SF Symbol plate covers a candidate with no
/// artwork of its own, the same way a tile drew before icons existed.
struct TileAlternate: Codable, Equatable, Identifiable, Sendable {
    var appID: String
    /// Artwork by filename in the skin library, like `PlacedTile.skin`.
    var skin: String?

    /// The appID: one slot offering the same app twice would make the phone's
    /// stored choice ambiguous, so the editor refuses duplicates instead.
    var id: String { appID }

    init(appID: String, skin: String? = nil) {
        self.appID = appID
        self.skin = skin
    }
}

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
    /// A custom icon image, by filename in the skin library.
    ///
    /// A skin is the whole artwork rather than a glyph, so it is drawn edge to
    /// edge with no tinted plate behind it - putting one inside the plate at
    /// 56% would frame somebody's icon inside a second icon.
    var skin: String?
    /// Overrides the catalogue's brand tint for the plate behind the icon.
    var tintHex: String?
    /// Clockwise rotation in degrees, so tiles can follow an angled element in
    /// the footage instead of always sitting square to the screen.
    var rotation: Double = 0
    /// Apps the phone may swap into this slot, after `appID` in the slot's
    /// list. Which one occupies the slot is the phone's choice, stored in the
    /// app group - the one part of a design that is not frozen at install time.
    var alternates: [TileAlternate] = []
    /// The grid cell this tile sits in, or nil for a tile placed off grid.
    /// Dragging with snapping off is what puts a tile off grid; the editor
    /// says which it is rather than leaving it to be guessed from position.
    var cell: GridCell?

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
        skin: String? = nil,
        tintHex: String? = nil,
        rotation: Double = 0,
        alternates: [TileAlternate] = [],
        cell: GridCell? = nil
    ) {
        self.id = id
        self.appID = appID
        self.center = center
        self.size = size
        self.cornerRadius = cornerRadius
        self.showsLabel = showsLabel
        self.opacity = opacity
        self.icon = icon
        self.skin = skin
        self.tintHex = tintHex
        self.rotation = rotation
        self.alternates = alternates
        self.cell = cell
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
        skin = try container.decodeIfPresent(String.self, forKey: .skin)
        tintHex = try container.decodeIfPresent(String.self, forKey: .tintHex)
        rotation = try container.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        alternates = try container.decodeIfPresent([TileAlternate].self, forKey: .alternates) ?? []
        cell = try container.decodeIfPresent(GridCell.self, forKey: .cell)
    }
}

/// An arbitrary image placed on the composition, as decoration.
///
/// Kept distinct from `PlacedTile` because a tile means an *app*: it carries a
/// bundle id, a hit region the widget answers taps in, a label and a square
/// plate. An asset is just a picture — any aspect, any angle, and nothing taps
/// it — so folding the two together would give every asset launcher fields it
/// can never use.
///
/// Positions are in screen pixel space, the same as `PlacedTile`, so the
/// editor, the baked wallpaper and the widget crop all read the same numbers.
struct PlacedAsset: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    /// Filename inside the design's own `Assets` folder.
    var fileName: String
    var center: CGPoint
    /// Rendered size in screen pixels. Free aspect: an asset is not a tile.
    var size: CGSize
    /// Clockwise degrees, to follow an angled element in the footage.
    var rotation: Double = 0
    var opacity: Double = 1
    /// Draw order among assets. Higher draws later, so over the others.
    var zIndex: Int = 0
    /// Keying settings, applied when the asset is drawn.
    ///
    /// Non-destructive on purpose: the imported file is never rewritten, so a
    /// key can be retuned or switched off long after import. Skin import bakes
    /// its keying into the PNG and leaves no way back, which is exactly the
    /// thing to not repeat here.
    var chroma: ChromaKey.Settings?

    var rect: CGRect {
        CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    init(
        id: UUID = UUID(),
        fileName: String,
        center: CGPoint,
        size: CGSize,
        rotation: Double = 0,
        opacity: Double = 1,
        zIndex: Int = 0,
        chroma: ChromaKey.Settings? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.center = center
        self.size = size
        self.rotation = rotation
        self.opacity = opacity
        self.zIndex = zIndex
        self.chroma = chroma
    }

    /// Field by field, for the same reason `PlacedTile` is: a design written
    /// before a field existed must still decode rather than vanish.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        fileName = try container.decode(String.self, forKey: .fileName)
        center = try container.decode(CGPoint.self, forKey: .center)
        size = try container.decode(CGSize.self, forKey: .size)
        rotation = try container.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        zIndex = try container.decodeIfPresent(Int.self, forKey: .zIndex) ?? 0
        chroma = try container.decodeIfPresent(ChromaKey.Settings.self, forKey: .chroma)
    }
}

/// An alternative clip for the same design - the same layout, the same crop,
/// a different animated part.
///
/// Like a game shipping five idle animations: the composition is settled once
/// and each variant only changes what plays inside the animated area. Every
/// variant costs a full lane-font set in the install, so the list is authored
/// deliberately rather than derived.
struct ClipVariant: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    /// Filename inside the design's folder, alongside the primary clip.
    var sourceVideoName: String

    init(id: UUID = UUID(), name: String, sourceVideoName: String) {
        self.id = id
        self.name = name
        self.sourceVideoName = sourceVideoName
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
    /// Decoration placed on the composition, drawn beneath the tiles.
    var assets: [PlacedAsset] = []
    /// Alternative clips for the animated part. The design's own clip is the
    /// default; the phone chooses among all of them after install.
    var variants: [ClipVariant] = []
    /// The grid tiles land on inside the widget frame.
    var grid: WidgetGrid = WidgetGrid()
    var snapEnabled: Bool = true

    /// A chosen background image, by filename inside the design's folder.
    ///
    /// Without one the composition fills whatever the clip does not cover with
    /// a dimmed blow-up of the clip itself, which suits footage that nearly
    /// fills the screen and looks like a mistake when it does not.
    var backgroundName: String?

    /// Starred designs are the ones compiled into the app, and the phone
    /// switches between them. Each one costs about 29MB of fonts in the
    /// install, because a font has to be in the bundle to draw at all.
    var isStarred: Bool = false

    /// Overrides the model's estimated widget corner radius, in screen pixels.
    /// Only the phone can settle this one, so it is adjustable.
    var widgetCornerRadius: CGFloat?

    var effectiveCornerRadius: CGFloat {
        widgetCornerRadius ?? DeviceGeometry.model.widgetCornerRadius
    }

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

    /// A variant's font family, distinct per variant for the same reason the
    /// design's is per design: every set has to coexist in one bundle.
    /// Lowercase, so the `v` can never read as the `L` the lane number follows.
    func fontFamilyBase(for variant: ClipVariant) -> String {
        "MFont\(id.uuidString.prefix(8).lowercased())v\(variant.id.uuidString.prefix(8).lowercased())L"
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
        assets = try container.decodeIfPresent([PlacedAsset].self, forKey: .assets) ?? []
        variants = try container.decodeIfPresent([ClipVariant].self, forKey: .variants) ?? []
        grid = try container.decodeIfPresent(WidgetGrid.self, forKey: .grid) ?? WidgetGrid()
        snapEnabled = try container.decodeIfPresent(Bool.self, forKey: .snapEnabled) ?? true
        backgroundName = try container.decodeIfPresent(String.self, forKey: .backgroundName)
        widgetCornerRadius = try container.decodeIfPresent(CGFloat.self, forKey: .widgetCornerRadius)
        isStarred = try container.decodeIfPresent(Bool.self, forKey: .isStarred) ?? false
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

    /// Placed pictures, drawn live between the animation and the tiles.
    ///
    /// They travel like the tiles do, because baked into the wallpaper alone
    /// they never reach the widget's own frame - the backdrop is the raw
    /// clip, and the app's preview video plays over the wallpaper. Optional
    /// for the same decoding reason `tiles` is.
    var assets: [PlacedAsset]?

    var placedAssets: [PlacedAsset] { assets ?? [] }

    /// What one built variant amounts to at render time. Everything else -
    /// crop, lanes, frame rate, tiles - is the design's, shared.
    struct VariantBuild: Codable, Equatable, Identifiable, Sendable {
        var id: UUID
        var name: String
        var fontFamilyBase: String
        var totalFontBytes: Int
        /// The variant's own loop, sized to its own clip - lengths need not
        /// match across variants. Optional because manifests written before it
        /// existed must still decode; nil falls back to the design's loop.
        var loopFrameCount: Int?
    }

    /// The built alternative clips, in the order they were authored. Optional
    /// for the same decoding reason `tiles` is.
    var clipVariants: [VariantBuild]?

    var builtVariants: [VariantBuild] { clipVariants ?? [] }

    var spec: TimerFontSpec {
        TimerFontSpec(laneCount: laneCount, framesPerSecond: framesPerSecond)
    }
}
