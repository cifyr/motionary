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

    struct Result: Sendable {
        let crop: CGRect
        /// Fraction of analysed cells that moved, for the UI to explain itself.
        let movingCellFraction: Double
    }

    func detect(frames: [CGImage], screenSize: CGSize) -> Result {
        guard frames.count > 1 else {
            Self.logger.info("single frame supplied; treating the whole screen as animated")
            return Result(crop: CGRect(origin: .zero, size: screenSize), movingCellFraction: 1)
        }

        let columns = gridSize
        let rows = Int((CGFloat(gridSize) * screenSize.height / screenSize.width).rounded())
        let samples = frames.compactMap { lumaGrid(of: $0, columns: columns, rows: rows) }
        guard samples.count == frames.count else {
            Self.logger.error("luma sampling failed; falling back to the full screen")
            return Result(crop: CGRect(origin: .zero, size: screenSize), movingCellFraction: 1)
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
            return Result(crop: .zero, movingCellFraction: 0)
        }

        var minColumn = columns, maxColumn = -1, minRow = rows, maxRow = -1
        for row in 0 ..< rows {
            for column in 0 ..< columns where moving[row * columns + column] {
                minColumn = min(minColumn, column)
                maxColumn = max(maxColumn, column)
                minRow = min(minRow, row)
                maxRow = max(maxRow, row)
            }
        }

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

        let fraction = Double(movingCount) / Double(moving.count)
        Self.logger.info("motion box \(String(describing: padded), privacy: .public), \(Int(fraction * 100))% of cells moving")
        return Result(crop: evenSized(padded), movingCellFraction: fraction)
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
