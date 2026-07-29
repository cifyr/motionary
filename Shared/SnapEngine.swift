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

    /// Keeps a tile inside the screen regardless of snapping.
    func clamp(center: CGPoint, tileSize: CGFloat) -> CGPoint {
        CGPoint(
            x: min(max(center.x, tileSize / 2), screenSize.width - tileSize / 2),
            y: min(max(center.y, tileSize / 2), screenSize.height - tileSize / 2)
        )
    }
}
