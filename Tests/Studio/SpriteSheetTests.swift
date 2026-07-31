import CoreGraphics
import XCTest

/// The names table is the layout as well as the labels, so a parse that comes
/// out the wrong shape silently pairs every icon with the wrong name.
final class SpriteSheetTests: XCTestCase {
    private let table = """
    | Messages  | Mail        | Phone        |
    | --------- | ----------- | ------------ |
    | Maps      | Weather     | Clock        |
    | **Games** | **Banking** | **Shopping** |
    """

    func testAMarkdownTableParsesToAGrid() throws {
        let layout = try XCTUnwrap(SpriteSheet.parseNames(table))
        XCTAssertEqual(layout.columns, 3)
        XCTAssertEqual(layout.rows, 3, "the |---| rule is not a row of names")
        XCTAssertEqual(layout.names[0], ["Messages", "Mail", "Phone"])
        XCTAssertEqual(layout.names[2], ["Games", "Banking", "Shopping"], "bold markers survived")
    }

    func testPlainRowsWithoutOuterPipesAlsoParse() throws {
        let layout = try XCTUnwrap(SpriteSheet.parseNames("Mail | Phone\nMaps | Clock"))
        XCTAssertEqual(layout.columns, 2)
        XCTAssertEqual(layout.rows, 2)
        XCTAssertEqual(layout.names[1], ["Maps", "Clock"])
    }

    /// A ragged table would put every name after the short row against the
    /// wrong picture, so short rows are padded rather than left ragged.
    func testShortRowsArePaddedSoIndicesStayAligned() throws {
        let layout = try XCTUnwrap(SpriteSheet.parseNames("| A | B | C |\n| D |"))
        XCTAssertEqual(layout.columns, 3)
        XCTAssertEqual(layout.names[1], ["D", "", ""])
        XCTAssertEqual(layout.flattened.count, 6)
    }

    func testEmptyTextIsNoLayout() {
        XCTAssertNil(SpriteSheet.parseNames("   \n\n"))
    }

    func testSlicingCutsEveryCellAtEqualSize() throws {
        let sheet = try Self.solid(width: 300, height: 200)
        let cells = SpriteSheet.slice(sheet, rows: 2, columns: 3)
        XCTAssertEqual(cells.count, 6)
        for cell in cells {
            XCTAssertEqual(cell.width, 100)
            XCTAssertEqual(cell.height, 100)
        }
    }

    /// Reading order, because that is the order the names table is written in.
    func testSlicingIsRowMajor() throws {
        let sheet = try Self.quadrants()
        let cells = SpriteSheet.slice(sheet, rows: 2, columns: 2)
        XCTAssertEqual(cells.count, 4)
        // Top-left is red, top-right green: the second cell is the one to the
        // right, not the one below.
        XCTAssertTrue(Self.isRed(cells[0]))
        XCTAssertTrue(Self.isGreen(cells[1]))
    }

    func testASheetWithNoRowsSlicesToNothing() throws {
        let sheet = try Self.solid(width: 100, height: 100)
        XCTAssertTrue(SpriteSheet.slice(sheet, rows: 0, columns: 4).isEmpty)
    }

    func testNamesMatchTheCatalogueLoosely() {
        XCTAssertEqual(SpriteSheet.app(named: "Apple Music")?.id, "applemusic")
        XCTAssertEqual(SpriteSheet.app(named: "apple music")?.id, "applemusic")
        XCTAssertEqual(SpriteSheet.app(named: "Google Maps")?.id, "gmaps")
        XCTAssertEqual(SpriteSheet.app(named: "Clash Royale")?.id, "clashroyale")
        XCTAssertEqual(SpriteSheet.app(named: "X")?.id, "x")
    }

    /// A label the catalogue has no app for still imports as artwork; it just
    /// cannot be offered as a swap, and the importer says so.
    func testACategoryLabelMatchesNoApp() {
        XCTAssertNil(SpriteSheet.app(named: "Banking"))
        XCTAssertNil(SpriteSheet.app(named: "Microsoft Teams"))
        XCTAssertNil(SpriteSheet.app(named: ""))
    }

    /// Two sheets carrying the same labels must not overwrite each other's
    /// icons, which is what the prefix is for.
    func testSkinNamesAreSafeAndPrefixed() {
        let name = SpriteSheet.skinName(for: "Clash Royale!", prefix: "sheet-neon")
        XCTAssertEqual(name, "sheet-neon-clash-royale.png")
        XCTAssertNotEqual(
            SpriteSheet.skinName(for: "Mail", prefix: "sheet-a"),
            SpriteSheet.skinName(for: "Mail", prefix: "sheet-b")
        )
    }

    // MARK: - Helpers

    private static func solid(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    /// Red top-left, green top-right, so cell order can be told apart. Drawn
    /// in CoreGraphics' bottom-up space, hence the flipped y.
    private static func quadrants() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 50, width: 50, height: 50))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 50, y: 50, width: 50, height: 50))
        return try XCTUnwrap(context.makeImage())
    }

    private static func average(_ image: CGImage) -> (r: Int, g: Int, b: Int) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let drew = pixel.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drew else { return (0, 0, 0) }
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    private static func isRed(_ image: CGImage) -> Bool {
        let pixel = average(image)
        return pixel.r > 150 && pixel.g < 90
    }

    private static func isGreen(_ image: CGImage) -> Bool {
        let pixel = average(image)
        return pixel.g > 150 && pixel.r < 90
    }
}
