import CoreGraphics
import Foundation
import os

/// Finds the region of the composition that actually moves.
///
/// This matters for cost, not just looks: every pixel inside the crop is
/// re-encoded into all 960 glyph selections, so a crop twice as tall doubles
/// the font payload. Anything static belongs in the still wallpaper instead.
struct MotionCropDetector {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "MotionCrop")

    /// Luma delta above which a cell counts as moving. Chosen to ignore encoder
    /// noise in flat areas while still catching a slow pan.
    var threshold: Int = 12
    /// Analysis grid resolution. Coarse enough to stay cheap, fine enough that
    /// the resulting box is not wildly larger than the motion.
    var gridSize: Int = 64
    /// Padding added around the detected box, as a fraction of screen size.
    var margin: CGFloat = 0.02
    /// Smallest connected run of moving cells that is allowed to widen the box.
    ///
    /// One bounding box has to cover everything that moves, so a single stray
    /// cell in a far corner costs the whole rectangle out to it. Measured on a
    /// real 5s clip: ten clusters, one of 1161 cells and the rest 1-24, and
    /// those stragglers took the box from 28% of the widget to 51% - a payload
    /// of static pixels re-encoded into all 480 glyph selections. 8 cells is
    /// under 0.1% of the grid and below every real cluster measured.
    var minimumClusterCells: Int = 8

    struct Result: Sendable {
        let crop: CGRect
        /// Fraction of analysed cells that moved, for the UI to explain itself.
        let movingCellFraction: Double
        /// Fraction of the returned box's cells that actually moved. Low means
        /// the box is mostly still picture being re-encoded every frame.
        let boxOccupancy: Double
        /// Clusters found, before the small ones were dropped.
        let clusterCount: Int
        /// Clusters too small to widen the box, and therefore left to the
        /// backdrop. Non-zero means the box is tighter than the raw motion.
        let discardedClusterCount: Int
    }

    func detect(frames: [CGImage], screenSize: CGSize) -> Result {
        guard frames.count > 1 else {
            Self.logger.info("single frame supplied; treating the whole screen as animated")
            return Self.wholeScreen(screenSize)
        }

        let columns = gridSize
        let rows = Int((CGFloat(gridSize) * screenSize.height / screenSize.width).rounded())
        let samples = frames.compactMap { lumaGrid(of: $0, columns: columns, rows: rows) }
        guard samples.count == frames.count else {
            Self.logger.error("luma sampling failed; falling back to the full screen")
            return Self.wholeScreen(screenSize)
        }

        var moving = [Bool](repeating: false, count: columns * rows)
        // Compare every frame against the first as well as its predecessor, so
        // a slow drift that never exceeds the per-frame threshold still counts.
        for index in 1 ..< samples.count {
            for cell in 0 ..< moving.count {
                let againstPrevious = abs(Int(samples[index][cell]) - Int(samples[index - 1][cell]))
                let againstFirst = abs(Int(samples[index][cell]) - Int(samples[0][cell]))
                if max(againstPrevious, againstFirst) >= threshold { moving[cell] = true }
            }
        }

        let movingCount = moving.filter { $0 }.count
        guard movingCount > 0 else {
            Self.logger.info("no motion detected above threshold \(self.threshold)")
            return Result(
                crop: .zero, movingCellFraction: 0, boxOccupancy: 0,
                clusterCount: 0, discardedClusterCount: 0
            )
        }

        // The box has to cover every kept cluster, so anything too small to be
        // worth widening it for is left to the still backdrop instead.
        let found = clusters(in: moving, columns: columns, rows: rows)
        var kept = found.filter { $0.cells >= minimumClusterCells }
        if kept.isEmpty, let largest = found.max(by: { $0.cells < $1.cells }) {
            // All the motion there is, is small. Animating the biggest of it
            // beats returning nothing, which fails the build outright.
            kept = [largest]
        }

        let keptCells = kept.reduce(0) { $0 + $1.cells }
        let minColumn = kept.map(\.minColumn).min() ?? 0
        let maxColumn = kept.map(\.maxColumn).max() ?? columns - 1
        let minRow = kept.map(\.minRow).min() ?? 0
        let maxRow = kept.map(\.maxRow).max() ?? rows - 1

        let cellWidth = screenSize.width / CGFloat(columns)
        let cellHeight = screenSize.height / CGFloat(rows)
        let box = CGRect(
            x: CGFloat(minColumn) * cellWidth,
            y: CGFloat(minRow) * cellHeight,
            width: CGFloat(maxColumn - minColumn + 1) * cellWidth,
            height: CGFloat(maxRow - minRow + 1) * cellHeight
        )
        let padded = box
            .insetBy(dx: -screenSize.width * margin, dy: -screenSize.height * margin)
            .intersection(CGRect(origin: .zero, size: screenSize))

        let boxCells = (maxColumn - minColumn + 1) * (maxRow - minRow + 1)
        let discarded = found.count - kept.count
        let fraction = Double(movingCount) / Double(moving.count)
        Self.logger.info("""
        motion box \(String(describing: padded), privacy: .public), \
        \(Int(fraction * 100))% of cells moving, \
        \(Int(Double(keptCells) / Double(max(1, boxCells)) * 100))% of the box, \
        \(discarded) of \(found.count) clusters left static
        """)
        return Result(
            crop: evenSized(padded),
            movingCellFraction: fraction,
            boxOccupancy: Double(keptCells) / Double(max(1, boxCells)),
            clusterCount: found.count,
            discardedClusterCount: discarded
        )
    }

    /// One 8-connected run of moving cells, with the box it forces.
    struct Cluster: Sendable {
        var cells: Int
        var minColumn: Int
        var maxColumn: Int
        var minRow: Int
        var maxRow: Int
    }

    /// 8-connected rather than 4-connected: a diagonal edge sweeping across the
    /// grid touches cells corner to corner, and splitting that into a chain of
    /// singletons would throw away the very motion being looked for.
    func clusters(in moving: [Bool], columns: Int, rows: Int) -> [Cluster] {
        var seen = [Bool](repeating: false, count: moving.count)
        var found: [Cluster] = []
        var stack: [Int] = []
        for start in 0 ..< moving.count where moving[start] && !seen[start] {
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            seen[start] = true
            var cluster = Cluster(
                cells: 0,
                minColumn: columns, maxColumn: -1,
                minRow: rows, maxRow: -1
            )
            while let cell = stack.popLast() {
                let row = cell / columns, column = cell % columns
                cluster.cells += 1
                cluster.minColumn = min(cluster.minColumn, column)
                cluster.maxColumn = max(cluster.maxColumn, column)
                cluster.minRow = min(cluster.minRow, row)
                cluster.maxRow = max(cluster.maxRow, row)
                for rowOffset in -1 ... 1 {
                    for columnOffset in -1 ... 1 {
                        let neighbourRow = row + rowOffset, neighbourColumn = column + columnOffset
                        guard neighbourRow >= 0, neighbourRow < rows,
                              neighbourColumn >= 0, neighbourColumn < columns
                        else { continue }
                        let neighbour = neighbourRow * columns + neighbourColumn
                        if moving[neighbour], !seen[neighbour] {
                            seen[neighbour] = true
                            stack.append(neighbour)
                        }
                    }
                }
            }
            found.append(cluster)
        }
        return found
    }

    /// Downsample to a luma grid by drawing into a tiny grayscale context.
    private func lumaGrid(of image: CGImage, columns: Int, rows: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: columns * rows)
        let success = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: columns,
                height: rows,
                bitsPerComponent: 8,
                bytesPerRow: columns,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
            return true
        }
        return success ? buffer : nil
    }

    /// Nothing usable came back, so everything animates. Costly, but a widget
    /// that moves is recoverable and one that is blank is not.
    private static func wholeScreen(_ screenSize: CGSize) -> Result {
        Result(
            crop: CGRect(origin: .zero, size: screenSize),
            movingCellFraction: 1,
            boxOccupancy: 1,
            clusterCount: 1,
            discardedClusterCount: 0
        )
    }

    /// Even dimensions keep chroma subsampling and any later video encode happy.
    private func evenSized(_ rect: CGRect) -> CGRect {
        let integral = rect.integral
        return CGRect(
            x: integral.minX,
            y: integral.minY,
            width: max(2, integral.width.rounded(.down) - integral.width.rounded(.down).truncatingRemainder(dividingBy: 2)),
            height: max(2, integral.height.rounded(.down) - integral.height.rounded(.down).truncatingRemainder(dividingBy: 2))
        )
    }
}
