import CoreGraphics
import Foundation

/// Alignment and distribution over a selection of tiles.
///
/// Pure and whole-array in, whole-array out, so the editor's toolbar is a
/// one-line call and the rules are testable without a canvas. Lining tiles up
/// used to be done by eye against the snap guides, which is why a row of
/// launchers either took a long time or never quite landed.
enum LayoutActions {
    enum Edge {
        case left, centerX, right
        case top, centerY, bottom

        var isHorizontal: Bool {
            switch self {
            case .left, .centerX, .right: true
            case .top, .centerY, .bottom: false
            }
        }
    }

    /// Aligns the selection.
    ///
    /// Two or more tiles align to the selection's own bounding box, the way a
    /// drawing tool does it; a lone tile has nothing to line up against, so it
    /// aligns to the widget frame - the region it has to live in to be tapped.
    static func aligned(
        _ tiles: [PlacedTile],
        selection: Set<UUID>,
        to edge: Edge,
        widgetRect: CGRect
    ) -> [PlacedTile] {
        let chosen = tiles.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return tiles }
        let box = chosen.count > 1 ? bounds(of: chosen) : widgetRect

        return tiles.map { tile in
            guard selection.contains(tile.id) else { return tile }
            var moved = tile
            let half = tile.boundingExtent / 2
            switch edge {
            case .left: moved.center.x = box.minX + half
            case .centerX: moved.center.x = box.midX
            case .right: moved.center.x = box.maxX - half
            case .top: moved.center.y = box.minY + half
            case .centerY: moved.center.y = box.midY
            case .bottom: moved.center.y = box.maxY - half
            }
            // Moving a tile by hand takes it off its cell; the label in the
            // layer list has to stop claiming a cell the tile has left.
            moved.cell = nil
            return moved
        }
    }

    /// Equal gaps between the selection, along whichever axis it is longer on,
    /// leaving the two end tiles where they are.
    ///
    /// Fewer than three tiles have no interior to space, so the selection is
    /// returned untouched rather than jumping.
    static func spacedEvenly(_ tiles: [PlacedTile], selection: Set<UUID>) -> [PlacedTile] {
        let chosen = tiles.filter { selection.contains($0.id) }
        guard chosen.count > 2 else { return tiles }
        let box = bounds(of: chosen)
        let horizontal = box.width >= box.height

        let ordered = chosen.sorted {
            horizontal ? $0.center.x < $1.center.x : $0.center.y < $1.center.y
        }
        // Distributes the free space between the extents, so the gaps end up
        // equal rather than the centres - tiles differ in size.
        let extents = ordered.reduce(CGFloat.zero) { $0 + $1.boundingExtent }
        let span = horizontal ? box.width : box.height
        let gap = (span - extents) / CGFloat(ordered.count - 1)

        var placements: [UUID: CGPoint] = [:]
        var cursor = horizontal ? box.minX : box.minY
        for tile in ordered {
            let half = tile.boundingExtent / 2
            placements[tile.id] = horizontal
                ? CGPoint(x: cursor + half, y: tile.center.y)
                : CGPoint(x: tile.center.x, y: cursor + half)
            cursor += tile.boundingExtent + gap
        }

        return tiles.map { tile in
            guard let center = placements[tile.id] else { return tile }
            var moved = tile
            moved.center = center
            moved.cell = nil
            return moved
        }
    }

    /// Lays the selection out as one row: tops aligned, equal gaps, in the
    /// left-to-right order they are already in. The row keeps its left edge
    /// and its top, so it does not jump across the canvas.
    static func madeIntoRow(
        _ tiles: [PlacedTile],
        selection: Set<UUID>,
        gap: CGFloat
    ) -> [PlacedTile] {
        let chosen = tiles.filter { selection.contains($0.id) }
        guard chosen.count > 1 else { return tiles }
        let box = bounds(of: chosen)
        let ordered = chosen.sorted { $0.center.x < $1.center.x }

        var placements: [UUID: CGPoint] = [:]
        var cursor = box.minX
        for tile in ordered {
            let half = tile.boundingExtent / 2
            placements[tile.id] = CGPoint(x: cursor + half, y: box.minY + half)
            cursor += tile.boundingExtent + gap
        }

        return tiles.map { tile in
            guard let center = placements[tile.id] else { return tile }
            var moved = tile
            moved.center = center
            moved.cell = nil
            return moved
        }
    }

    /// The box the tiles occupy, rotation included - a tile at 45 degrees
    /// reaches wider than its side.
    static func bounds(of tiles: [PlacedTile]) -> CGRect {
        guard let first = tiles.first else { return .zero }
        return tiles.dropFirst().reduce(box(of: first)) { $0.union(box(of: $1)) }
    }

    private static func box(of tile: PlacedTile) -> CGRect {
        let extent = tile.boundingExtent
        return CGRect(
            x: tile.center.x - extent / 2,
            y: tile.center.y - extent / 2,
            width: extent,
            height: extent
        )
    }
}

/// Taking a scene's own clip out of it.
///
/// A scene is its clip, so this is a swap rather than a deletion: one of the
/// variants steps into the place the retired clip leaves. Pure, because which
/// clip succeeds and what the document becomes is the part worth being sure
/// about - the file removal and the re-measure follow from it.
enum ClipPromotion {
    struct Result: Equatable {
        var design: DesignDocument
        /// The clip file the design no longer references.
        var retiredFileName: String
        var promotedName: String
    }

    /// The design with one of its variants as its own clip, or nil when there
    /// is nothing to take over - the last clip cannot go.
    ///
    /// The successor is whichever clip the scene leads with, since that is
    /// already the one a phone shows; a scene leading with itself hands over to
    /// the first variant instead.
    static func promoting(in design: DesignDocument) -> Result? {
        guard !design.variants.isEmpty else { return nil }
        let successor = design.variants.first { $0.id == design.defaultVariantID } ?? design.variants[0]

        var updated = design
        updated.sourceVideoName = successor.sourceVideoName
        updated.primaryClipName = successor.name
        updated.variants.removeAll { $0.id == successor.id }
        // It is the design's own clip now, and the design's own clip is what
        // nil means - leaving the id would name a variant that is gone, and
        // the build would write no default at all.
        if updated.defaultVariantID == successor.id { updated.defaultVariantID = nil }

        return Result(
            design: updated,
            retiredFileName: design.sourceVideoName,
            promotedName: successor.name
        )
    }
}
