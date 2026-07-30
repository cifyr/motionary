import CoreGraphics
import XCTest

/// The SVG renderer replaces a dependency, so it carries the risk that a
/// dependency would have absorbed: a parsing slip shows up as a blank or
/// mangled icon rather than a crash.
final class IconRenderingTests: XCTestCase {
    private let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

    // MARK: - Path parsing

    func testAbsoluteAndRelativeCommandsAgree() throws {
        let absolute = try SVGPathParser.path(from: "M10 10 L20 10 L20 20 Z")
        let relative = try SVGPathParser.path(from: "m10 10 l10 0 l0 10 z")
        XCTAssertEqual(absolute.boundingBoxOfPath, relative.boundingBoxOfPath)
    }

    func testShorthandCommandsMatchTheirLongForms() throws {
        let shorthand = try SVGPathParser.path(from: "M0 0 H10 V10 H0 Z")
        let long = try SVGPathParser.path(from: "M0 0 L10 0 L10 10 L0 10 Z")
        XCTAssertEqual(shorthand.boundingBoxOfPath, long.boundingBoxOfPath)
    }

    /// SVG allows numbers to run together: "1.5.5" is 1.5 followed by 0.5, and
    /// a minus sign separates without whitespace.
    func testCompactNumberSyntax() throws {
        let path = try SVGPathParser.path(from: "M0 0L1.5.5-2-3")
        let box = path.boundingBoxOfPath
        XCTAssertEqual(box.minX, -2, accuracy: 0.0001)
        XCTAssertEqual(box.minY, -3, accuracy: 0.0001)
        XCTAssertEqual(box.maxX, 1.5, accuracy: 0.0001)
    }

    func testScientificNotationIsRead() throws {
        let path = try SVGPathParser.path(from: "M0 0 L1e2 5e-1")
        XCTAssertEqual(path.boundingBoxOfPath.maxX, 100, accuracy: 0.0001)
        XCTAssertEqual(path.boundingBoxOfPath.maxY, 0.5, accuracy: 0.0001)
    }

    func testImplicitLinetoAfterMoveto() throws {
        // Extra coordinate pairs after M are linetos, not further movetos.
        let implicit = try SVGPathParser.path(from: "M0 0 10 0 10 10")
        let explicit = try SVGPathParser.path(from: "M0 0 L10 0 L10 10")
        XCTAssertEqual(implicit.boundingBoxOfPath, explicit.boundingBoxOfPath)
    }

    func testArcProducesAPathSpanningItsEndpoints() throws {
        let path = try SVGPathParser.path(from: "M0 0 A5 5 0 0 1 10 0")
        XCTAssertFalse(path.isEmpty)
        let box = path.boundingBoxOfPath
        XCTAssertEqual(box.minX, 0, accuracy: 0.01)
        XCTAssertEqual(box.maxX, 10, accuracy: 0.01)
        XCTAssertGreaterThan(box.height, 4, "a semicircular arc should bulge")
    }

    /// Radii too small to reach the endpoint are scaled up rather than dropped.
    func testUndersizedArcRadiiAreScaled() throws {
        let path = try SVGPathParser.path(from: "M0 0 A1 1 0 0 1 10 0")
        XCTAssertEqual(path.boundingBoxOfPath.maxX, 10, accuracy: 0.01)
    }

    func testSmoothCurveReflectsThePreviousControlPoint() throws {
        let path = try SVGPathParser.path(from: "M0 0 C0 5 5 5 5 0 S10 -5 10 0")
        XCTAssertFalse(path.isEmpty)
        XCTAssertEqual(path.boundingBoxOfPath.maxX, 10, accuracy: 0.01)
    }

    func testUnknownCommandIsRejectedRatherThanIgnored() {
        XCTAssertThrowsError(try SVGPathParser.path(from: "M0 0 K5 5"))
    }

    func testEmptyPathIsEmptyNotAnError() throws {
        XCTAssertTrue(try SVGPathParser.path(from: "").isEmpty)
    }

    // MARK: - Body rendering

    private func render(_ body: String, viewBox: CGRect = CGRect(x: 0, y: 0, width: 24, height: 24)) throws -> CGImage {
        try SVGIconRenderer(viewBox: viewBox, tint: white).image(body: body, side: 64)
    }

    private func opaquePixelCount(_ image: CGImage) -> Int {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return stride(from: 3, to: pixels.count, by: 4).reduce(into: 0) { count, index in
            if pixels[index] > 8 { count += 1 }
        }
    }

    /// A real Simple Icons body: one filled path using `currentColor`.
    func testFilledBrandIconRendersVisiblePixels() throws {
        let body = #"<path fill="currentColor" d="M12 0C5.4 0 0 5.4 0 12s5.4 12 12 12s12-5.4 12-12S18.66 0 12 0"/>"#
        let image = try render(body)
        XCTAssertGreaterThan(opaquePixelCount(image), 1_000, "a filled disc should cover much of the canvas")
    }

    /// A real Lucide body: a `<g>` carrying stroke attributes with no fill.
    func testStrokedOutlineIconIsNotFilledSolid() throws {
        let body = #"<g fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="9"/></g>"#
        let stroked = try render(body)
        let filled = try render(#"<circle cx="12" cy="12" r="9" fill="currentColor"/>"#)

        XCTAssertGreaterThan(opaquePixelCount(stroked), 100, "the outline must be drawn")
        // The centre is the unambiguous discriminator: a thick ring can cover
        // a similar pixel count to a disc, but only a fill reaches the middle.
        XCTAssertLessThan(alpha(at: CGPoint(x: 32, y: 32), in: stroked), 8, "the outline must be hollow")
        XCTAssertGreaterThan(alpha(at: CGPoint(x: 32, y: 32), in: filled), 200, "the filled circle must be solid")
    }

    private func alpha(at point: CGPoint, in image: CGImage) -> UInt8 {
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.translateBy(x: -point.x, y: -(CGFloat(image.height) - point.y - 1))
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixel[3]
    }

    func testBasicShapesAllDraw() throws {
        for body in [
            #"<rect x="2" y="2" width="20" height="20" fill="currentColor"/>"#,
            #"<circle cx="12" cy="12" r="10" fill="currentColor"/>"#,
            #"<ellipse cx="12" cy="12" rx="10" ry="6" fill="currentColor"/>"#,
            #"<polygon points="2,2 22,2 12,22" fill="currentColor"/>"#,
        ] {
            XCTAssertGreaterThan(opaquePixelCount(try render(body)), 500, body)
        }
    }

    func testEvenOddFillLeavesAHole() throws {
        let evenOdd = #"<path fill="currentColor" fill-rule="evenodd" d="M2 2h20v20H2Z M8 8h8v8H8Z"/>"#
        let solid = #"<path fill="currentColor" d="M2 2h20v20H2Z"/>"#
        XCTAssertLessThan(
            opaquePixelCount(try render(evenOdd)), opaquePixelCount(try render(solid)),
            "the inner square should be punched out"
        )
    }

    func testNonSquareViewBoxKeepsProportions() throws {
        // fa6-brands icons are 640x512; a square render must letterbox.
        let body = #"<path fill="currentColor" d="M0 0h640v512H0Z"/>"#
        let image = try render(body, viewBox: CGRect(x: 0, y: 0, width: 640, height: 512))
        let covered = opaquePixelCount(image)
        let total = image.width * image.height
        XCTAssertLessThan(covered, total, "a 640x512 box cannot fill a square without distortion")
        XCTAssertGreaterThan(covered, total / 2)
    }

    func testGroupTransformsMoveShapes() throws {
        let untransformed = try render(#"<rect x="0" y="0" width="8" height="8" fill="currentColor"/>"#)
        let translated = try render(
            #"<g transform="translate(16 16)"><rect x="0" y="0" width="8" height="8" fill="currentColor"/></g>"#
        )
        XCTAssertEqual(opaquePixelCount(untransformed), opaquePixelCount(translated), accuracy: 40)
    }

    func testBodyWithNothingDrawableReportsWhatItSaw() {
        XCTAssertThrowsError(try render("<text>hello</text>")) { error in
            guard case SVGRenderError.noDrawableShapes(let elements) = error else {
                return XCTFail("expected noDrawableShapes, got \(error)")
            }
            XCTAssertEqual(elements, ["text"])
        }
    }

    func testMalformedBodyIsRejected() {
        XCTAssertThrowsError(try render("<path d=\"M0 0\""))
    }

    // MARK: - Icon identity

    func testIconAssetRoundTripsThroughItsIdentifier() {
        let icon = IconAsset(id: "simple-icons:spotify")
        XCTAssertEqual(icon?.prefix, "simple-icons")
        XCTAssertEqual(icon?.name, "spotify")
        XCTAssertEqual(icon?.id, "simple-icons:spotify")
        XCTAssertNil(IconAsset(id: "nocolon"))
        XCTAssertNil(IconAsset(id: ":empty"))
    }

    /// Cache keys become filenames, so a colon would be a problem.
    func testCacheKeyIsFilenameSafe() {
        let icon = IconAsset(prefix: "simple-icons", name: "spotify")
        XCTAssertFalse(icon.cacheKey.contains(":"))
        XCTAssertFalse(icon.cacheKey.contains("/"))
    }
}

private func XCTAssertEqual(_ a: Int, _ b: Int, accuracy: Int, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThanOrEqual(abs(a - b), accuracy, "\(a) and \(b) differ by more than \(accuracy)", file: file, line: line)
}
