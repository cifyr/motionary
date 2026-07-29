import CoreGraphics
import Foundation

/// A line the editor can snap a dragged tile to, and draw while dragging.
struct SnapGuide: Equatable, Identifiable {
    enum Axis: Equatable { case vertical, horizontal }
    enum Kind: Equatable { case screenCenter, screenEdge, widgetFrame, iconGrid, sibling }

    let axis: Axis
    /// Position along the axis, in screen pixels.
    let position: CGFloat
    let kind: Kind

    var id: String { "\(axis)-\(position)-\(kind)" }
}

/// Snapping for tile placement.
///
/// Candidates come from the Home Screen icon grid, the screen's own centre and
/// edges, the widget frame, and the other tiles. Snapping is applied per axis
/// so a tile can lock horizontally while still moving freely up and down.
struct SnapEngine {
    /// Distance in screen pixels within which a candidate captures the tile.
    var threshold: CGFloat = 14
    var screenSize: CGSize = DeviceGeometry.screenPixelSize
    var widgetRect: CGRect
    /// Icon grid columns and rows used for alignment candidates.
    var gridColumns: Int = 4
    var gridRows: Int = 6

    struct Result {
        let center: CGPoint
        let guides: [SnapGuide]
    }

    func snap(center: CGPoint, tileSize: CGFloat, siblings: [PlacedTile]) -> Result {
        let vertical = candidates(axis: .vertical, siblings: siblings, tileSize: tileSize)
        let horizontal = candidates(axis: .horizontal, siblings: siblings, tileSize: tileSize)

        let x = nearest(to: center.x, among: vertical)
        let y = nearest(to: center.y, among: horizontal)

        var guides: [SnapGuide] = []
        if let x { guides.append(x.guide) }
        if let y { guides.append(y.guide) }

        return Result(
            center: CGPoint(x: x?.value ?? center.x, y: y?.value ?? center.y),
            guides: guides
        )
    }

    private func nearest(
        to value: CGFloat,
        among candidates: [(value: CGFloat, guide: SnapGuide)]
    ) -> (value: CGFloat, guide: SnapGuide)? {
        candidates
            .filter { abs($0.value - value) <= threshold }
            .min { abs($0.value - value) < abs($1.value - value) }
    }

    private func candidates(
        axis: SnapGuide.Axis,
        siblings: [PlacedTile],
        tileSize: CGFloat
    ) -> [(value: CGFloat, guide: SnapGuide)] {
        var result: [(CGFloat, SnapGuide)] = []

        func add(_ value: CGFloat, _ kind: SnapGuide.Kind) {
            result.append((value, SnapGuide(axis: axis, position: value, kind: kind)))
        }

        if axis == .vertical {
            add(screenSize.width / 2, .screenCenter)
            add(widgetRect.midX, .widgetFrame)
            // Tile edges flush to the widget frame, not just centred in it.
            add(widgetRect.minX + tileSize / 2, .widgetFrame)
            add(widgetRect.maxX - tileSize / 2, .widgetFrame)
            for column in 0 ..< gridColumns {
                let pitch = widgetRect.width / CGFloat(gridColumns)
                add(widgetRect.minX + pitch * (CGFloat(column) + 0.5), .iconGrid)
            }
            for sibling in siblings {
                add(sibling.center.x, .sibling)
            }
        } else {
            add(screenSize.height / 2, .screenCenter)
            add(widgetRect.midY, .widgetFrame)
            add(widgetRect.minY + tileSize / 2, .widgetFrame)
            add(widgetRect.maxY - tileSize / 2, .widgetFrame)
            for row in 0 ..< gridRows {
                let pitch = widgetRect.height / CGFloat(gridRows)
                add(widgetRect.minY + pitch * (CGFloat(row) + 0.5), .iconGrid)
            }
            for sibling in siblings {
                add(sibling.center.y, .sibling)
            }
        }

        return result.map { (value: $0.0, guide: $0.1) }
    }

    /// Keeps a tile inside the screen regardless of snapping. `tileSize` should
    /// be the rotated bounding extent, not the plate's side, or a rotated
    /// corner can still leave the screen.
    func clamp(center: CGPoint, tileSize: CGFloat) -> CGPoint {
        // A tile larger than the screen has no valid range; centre it rather
        // than letting the clamp invert.
        let halfX = min(tileSize / 2, screenSize.width / 2)
        let halfY = min(tileSize / 2, screenSize.height / 2)
        return CGPoint(
            x: min(max(center.x, halfX), screenSize.width - halfX),
            y: min(max(center.y, halfY), screenSize.height - halfY)
        )
    }

    /// Angles a rotating tile settles onto, so a tile meant to be square or at
    /// a clean diagonal does not end up a degree off.
    static let snapAngles: [Double] = stride(from: -180.0, through: 180.0, by: 15).map { $0 }
    /// How near an increment a rotation has to be before it locks.
    var angleThreshold: Double = 4

    func snap(rotation: Double) -> Double {
        let wrapped = Self.wrap(rotation)
        guard let nearest = Self.snapAngles.min(by: {
            abs(Self.difference($0, wrapped)) < abs(Self.difference($1, wrapped))
        }) else { return wrapped }
        return abs(Self.difference(nearest, wrapped)) <= angleThreshold ? Self.wrap(nearest) : wrapped
    }

    /// Normalises to (-180, 180] so 350 and -10 are the same rotation.
    static func wrap(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value <= -180 { value += 360 }
        return value
    }

    /// Shortest signed distance between two angles, across the wrap point.
    static func difference(_ a: Double, _ b: Double) -> Double {
        wrap(a - b)
    }
}
