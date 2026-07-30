import CoreGraphics
import XCTest

/// The correction has to land on exactly the rows the system draws its line on.
/// A row out and it darkens the picture next to a line it did not remove, which
/// is two artefacts instead of one.
final class EdgeCompensationTests: XCTestCase {
    private let widgetRect = DeviceGeometry.widgetRect

    func testTheBandsSitAtTheWidgetsRealTopAndBottom() {
        XCTAssertEqual(EdgeCompensation.topEdgeRow(widgetRect: widgetRect), 270)
        // 1914, not the 1901 the composition's own frame ends at: the system
        // hands over more widget than the frame is cut to. A first pass put this
        // a row short, and the bottom line survived almost untouched.
        XCTAssertEqual(EdgeCompensation.bottomEdgeRow(widgetRect: widgetRect), 1914)
        XCTAssertGreaterThan(
            EdgeCompensation.bottomEdgeRow(widgetRect: widgetRect),
            Int(widgetRect.maxY) - 1,
            "the bottom line is below where the composition ends; the padded backdrop is what covers it"
        )
    }

    func testOnlyEdgeRowsAreCorrected() {
        let top = EdgeCompensation.topEdgeRow(widgetRect: widgetRect)
        let bottom = EdgeCompensation.bottomEdgeRow(widgetRect: widgetRect)
        XCTAssertNotNil(EdgeCompensation.correction(screenRow: top, widgetRect: widgetRect))
        XCTAssertNotNil(EdgeCompensation.correction(screenRow: bottom, widgetRect: widgetRect))
        XCTAssertNil(EdgeCompensation.correction(screenRow: top - 1, widgetRect: widgetRect))
        XCTAssertNil(EdgeCompensation.correction(screenRow: bottom + 1, widgetRect: widgetRect))
        XCTAssertNil(
            EdgeCompensation.correction(screenRow: (top + bottom) / 2, widgetRect: widgetRect),
            "the middle of the widget must not be touched"
        )
    }

    /// Strongest at the edge and fading inward, matching the line it cancels.
    ///
    /// Never-stronger rather than always-weaker: the measured tail plateaus for a
    /// row or two, and rounding a real measurement to whole units is allowed to
    /// repeat a value. What would be wrong is a correction that grows with
    /// distance from the edge.
    func testTheCorrectionNeverGrowsInward() throws {
        let top = EdgeCompensation.topEdgeRow(widgetRect: widgetRect)
        let bottom = EdgeCompensation.bottomEdgeRow(widgetRect: widgetRect)
        for (label, edge, step) in [("top", top, 1), ("bottom", bottom, -1)] {
            var previous = Double.infinity
            let depth = step == 1 ? EdgeCompensation.topAdded.count : EdgeCompensation.bottomAdded.count
            for distance in 0 ..< depth {
                let correction = try XCTUnwrap(
                    EdgeCompensation.correction(screenRow: edge + distance * step, widgetRect: widgetRect)
                )
                XCTAssertLessThanOrEqual(
                    correction.g,
                    previous,
                    "\(label) distance \(distance) is stronger than the one before it"
                )
                previous = correction.g
            }
        }
    }

    func testTheCorrectionMatchesTheMeasuredLine() throws {
        XCTAssertGreaterThan(EdgeCompensation.strength, 0)
        XCTAssertLessThanOrEqual(EdgeCompensation.strength, 1)
        let top = EdgeCompensation.topEdgeRow(widgetRect: widgetRect)
        let correction = try XCTUnwrap(EdgeCompensation.correction(screenRow: top, widgetRect: widgetRect))
        XCTAssertEqual(correction.g, EdgeCompensation.topAdded[0].g * EdgeCompensation.strength, accuracy: 0.001)
    }

    /// The two edges were measured separately because they are not the same
    /// shape: reusing one profile for both is what left the bottom line behind.
    func testEachEdgeUsesItsOwnProfile() throws {
        let top = EdgeCompensation.topEdgeRow(widgetRect: widgetRect)
        let bottom = EdgeCompensation.bottomEdgeRow(widgetRect: widgetRect)
        let atTop = try XCTUnwrap(EdgeCompensation.correction(screenRow: top, widgetRect: widgetRect))
        let atBottom = try XCTUnwrap(EdgeCompensation.correction(screenRow: bottom, widgetRect: widgetRect))
        XCTAssertEqual(atTop.r, EdgeCompensation.topAdded[0].r, accuracy: 0.001)
        XCTAssertEqual(atBottom.r, EdgeCompensation.bottomAdded[0].r, accuracy: 0.001)
        XCTAssertNotEqual(atTop.r, atBottom.r)
    }

    func testAnAnimatedCropReachingTheEdgeIsDetected() {
        let reaching = CGRect(x: 100, y: widgetRect.minY, width: 200, height: 400)
        let clear = CGRect(x: 100, y: widgetRect.minY + 200, width: 200, height: 400)
        XCTAssertTrue(EdgeCompensation.overlaps(reaching, widgetRect: widgetRect))
        XCTAssertFalse(EdgeCompensation.overlaps(clear, widgetRect: widgetRect))
    }

    // MARK: - Pixels

    func testEdgeRowsAreDarkenedAndTheRestIsUntouched() throws {
        let originY = Int(widgetRect.minY) - 24
        let height = 80
        let image = try flat(level: 200, width: 8, height: height)

        let corrected = EdgeCompensation.applied(to: image, originY: originY, widgetRect: widgetRect)
        let pixels = try Pixels(corrected)
        // Read back rather than assumed: filling 200 and reading it as 200 needs
        // the fill and the read to agree about colour space, which they do not,
        // and this test is about the subtraction rather than about that.
        let baseline = try Pixels(image).at(x: 4, y: 0).g

        // The widget's top row, 24 rows into this image.
        let edgeRow = Int(widgetRect.minY) - originY
        let expected = Double(baseline) - EdgeCompensation.topAdded[0].g * EdgeCompensation.strength
        XCTAssertEqual(Double(pixels.at(x: 4, y: edgeRow).g), expected, accuracy: 2)
        XCTAssertEqual(pixels.at(x: 4, y: edgeRow - 1).g, baseline, "the row above the widget was darkened")
        XCTAssertEqual(pixels.at(x: 4, y: edgeRow + EdgeCompensation.topAdded.count).g, baseline)
    }

    /// Nothing can be subtracted past black, so a dark edge keeps some of the
    /// line. Better than wrapping around to white.
    func testDarkContentClampsAtBlack() throws {
        let originY = Int(widgetRect.minY)
        let image = try flat(level: 4, width: 8, height: 8)
        let corrected = EdgeCompensation.applied(to: image, originY: originY, widgetRect: widgetRect)
        let pixels = try Pixels(corrected)
        XCTAssertEqual(pixels.at(x: 4, y: 0).g, 0)
    }

    /// An image nowhere near either band comes back as it went in, rather than
    /// being re-encoded for nothing.
    func testAnImageAwayFromTheEdgesIsReturnedUnchanged() throws {
        let image = try flat(level: 128, width: 8, height: 8)
        let corrected = EdgeCompensation.applied(
            to: image,
            originY: Int(widgetRect.midY),
            widgetRect: widgetRect
        )
        XCTAssertTrue(corrected === image)
    }

    // MARK: - As the pipeline composes them

    /// Both corrections, in the order `FontSetGenerator` applies them, on an image
    /// the shape of the padded backdrop.
    ///
    /// A design shipped with neither of them in its backdrop, which is invisible
    /// from any test that exercises the two in isolation: each was fine. What was
    /// not established anywhere is that a backdrop coming out of this pair is both
    /// tinted *and* darkened at the edge, so that is what this pins. A shot of a
    /// design built without them measures the whole line rather than what is left
    /// of it, and folding that into the profile doubles it -
    /// `Tools/edge-calibrate.py` refuses for that reason.
    func testTheBackdropGetsBothTheTintAndTheEdgeSubtraction() throws {
        let widgetRect = DeviceGeometry.widgetRect
        let padded = widgetRect.insetBy(dx: -24, dy: -24)
        let originY = Int(padded.minY)
        let level = 180
        let image = try flat(level: level, width: 8, height: Int(padded.height))

        let corrected = EdgeCompensation.applied(
            to: WidgetTint.applied(to: image),
            originY: originY,
            widgetRect: widgetRect
        )
        let before = try Pixels(image)
        let after = try Pixels(corrected)
        let source = Double(before.at(x: 4, y: 0).g)

        // Well inside the widget: the tint and nothing else.
        let middle = Int(widgetRect.midY) - originY
        XCTAssertEqual(
            Double(after.at(x: 4, y: middle).g),
            source * WidgetTint.gain.g,
            accuracy: 2,
            "the middle of the backdrop is not carrying the colour gain"
        )

        // The widget's own top and bottom rows: the tint, then the line taken out.
        for (label, screenRow, profile) in [
            ("top", EdgeCompensation.topEdgeRow(widgetRect: widgetRect), EdgeCompensation.topAdded[0]),
            ("bottom", EdgeCompensation.bottomEdgeRow(widgetRect: widgetRect), EdgeCompensation.bottomAdded[0]),
        ] {
            let row = screenRow - originY
            XCTAssertEqual(
                Double(after.at(x: 4, y: row).g),
                source * WidgetTint.gain.g - profile.g * EdgeCompensation.strength,
                accuracy: 2,
                "the \(label) row is not both tinted and darkened"
            )
        }

        // And the rows just outside the widget, which the padding covers, keep the
        // tint alone: darkening them would put a band next to no line at all.
        let above = Int(widgetRect.minY) - originY - 1
        XCTAssertEqual(
            Double(after.at(x: 4, y: above).g),
            source * WidgetTint.gain.g,
            accuracy: 2,
            "the padding above the widget was darkened"
        )
    }

    private func flat(level: Int, width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let value = CGFloat(level) / 255
        context.setFillColor(CGColor(red: value, green: value, blue: value, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private struct Pixels {
        let bytes: [UInt8]
        let width: Int

        init(_ image: CGImage) throws {
            let width = image.width
            let height = image.height
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            let drew = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(
                    data: raw.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                ) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            XCTAssertTrue(drew)
            bytes = buffer
            self.width = width
        }

        func at(x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
            let index = (y * width + x) * 4
            return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
        }
    }
}
