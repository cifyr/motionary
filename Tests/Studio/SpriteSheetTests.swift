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

    /// 1254 across 7 columns is 179.14, and rounding each cell's own origin
    /// and size drifts by a pixel and a half before the last column - every
    /// icon cut slightly wrong, worse the further right it sits.
    func testCellsTileExactlyWhenTheSheetDoesNotDivideEvenly() throws {
        let sheet = try Self.solid(width: 1254, height: 1254)
        let cells = SpriteSheet.slice(sheet, rows: 7, columns: 7)
        XCTAssertEqual(cells.count, 49)

        // Widths of one row must add back up to the sheet, with no cell lost
        // or doubled.
        let firstRow = cells.prefix(7).map(\.width)
        XCTAssertEqual(firstRow.reduce(0, +), 1254, "the cut drifts across the row")
        XCTAssertTrue(firstRow.allSatisfy { abs($0 - 179) <= 1 }, "cells are wildly uneven: \(firstRow)")
    }

    /// Green icons on a green sheet: keying by colour hollows out Messages,
    /// Phone, FaceTime, WhatsApp and Spotify. Only backdrop connected to the
    /// border may go.
    func testGreenInsideAnIconSurvives() throws {
        let cell = try Self.greenIconOnGreen()
        let cleared = try XCTUnwrap(SpriteSheet.removingSurround(cell))
        let pixels = try Pixels(cleared)

        XCTAssertEqual(pixels.alpha(x: 2, y: 2), 0, "the surround was not cleared")
        XCTAssertEqual(pixels.alpha(x: 50, y: 50), 255, "the icon's own green was removed")
        XCTAssertTrue(pixels.isGreenish(x: 50, y: 50), "the icon's green did not survive")
    }

    /// A sheet's margins rarely divide into exactly equal cells, so a cut
    /// catches a stripe of the icon next door. It is not backdrop, so the fill
    /// leaves it and the trim treats it as content.
    func testASliverOfTheNeighbourIsDiscarded() throws {
        let cell = try Self.iconWithNeighbourSliver()
        let cleared = try XCTUnwrap(SpriteSheet.removingSurround(cell))
        let pixels = try Pixels(cleared)

        XCTAssertEqual(pixels.alpha(x: 1, y: 50), 0, "the neighbour's sliver survived")
        XCTAssertEqual(pixels.alpha(x: 50, y: 50), 255, "the icon itself was discarded")
    }

    /// Equal division assumes the sheet's outer margin is half a gutter. On a
    /// real sheet it is not, and by the last column the cut starts after its
    /// icon begins - which is what clipped Google Maps and Roblox.
    func testIconsAreFoundWhereTheyActuallyAreNotWhereAnEvenCutFalls() throws {
        // A wide left margin and a narrow right one, so an even cut lands
        // through the icons rather than between them.
        let sheet = try Self.offsetGrid()
        let found = SpriteSheet.icons(in: sheet, rows: 1, columns: 3)

        XCTAssertEqual(found.count, 3)
        XCTAssertEqual(found.compactMap { $0 }.count, 3, "an icon was missed")
        for icon in found.compactMap({ $0 }) {
            // Each plate is 40 wide; a clipped one comes back narrower.
            XCTAssertEqual(icon.width, 40, "an icon was cut short")
            XCTAssertEqual(icon.height, 40)
        }
    }

    /// Cut to its own bounds, which is what centres it once squared up: a
    /// tight crop is the difference between an icon and an icon adrift in its
    /// own tile.
    func testAnIconIsCutTightlyAroundItself() throws {
        let sheet = try Self.offsetGrid()
        let icon = try XCTUnwrap(SpriteSheet.icons(in: sheet, rows: 1, columns: 3).first ?? nil)
        let pixels = try Pixels(icon)
        // Every edge is the plate, with no backdrop left around it.
        XCTAssertFalse(pixels.isGreenish(x: 0, y: 0))
        XCTAssertFalse(pixels.isGreenish(x: icon.width - 1, y: icon.height - 1))
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
    ///
    /// Categories, not apps: a sheet's bottom row is usually a set of generic
    /// tiles meant to point at whatever the person wants.
    func testACategoryLabelMatchesNoApp() {
        XCTAssertNil(SpriteSheet.app(named: "Banking"))
        XCTAssertNil(SpriteSheet.app(named: "Shopping"))
        XCTAssertNil(SpriteSheet.app(named: ""))
    }

    /// The apps an icon pack draws that the catalogue used to miss, so a tile
    /// wearing one can actually open it.
    func testTheAddedHomeScreenAppsResolve() {
        for name in ["Weather", "Calculator", "Messenger", "Telegram",
                     "Outlook", "Microsoft Teams", "Zoom", "Amazon"] {
            XCTAssertNotNil(SpriteSheet.app(named: name), "\(name) is not in the catalogue")
        }
        // Apple publishes no scheme for these two, so they draw but cannot be
        // opened - claimed otherwise, a tap would report a phantom failure.
        XCTAssertEqual(SpriteSheet.app(named: "Weather")?.canLaunch, false)
        XCTAssertEqual(SpriteSheet.app(named: "Calculator")?.canLaunch, false)
        XCTAssertEqual(SpriteSheet.app(named: "Zoom")?.canLaunch, true)
    }

    /// The sheet this was built for, so the catalogue keeps covering it.
    ///
    /// Every one of the 49 cells imports as artwork; what this counts is how
    /// many name an app that can actually be opened, which is the difference
    /// between a tile that launches and a tile that only draws.
    func testTheHomeScreenSheetIsFullyCovered() throws {
        let sheet = """
        | Messages  | Mail        | Phone        | FaceTime        | Camera    | Photos       | Safari      |
        | --------- | ----------- | ------------ | --------------- | --------- | ------------ | ----------- |
        | Maps      | Weather     | Clock        | Calendar        | Notes     | Reminders    | Calculator  |
        | Settings  | App Store   | Apple Music  | Wallet          | YouTube   | WhatsApp     | Instagram   |
        | Facebook  | TikTok      | Snapchat     | Spotify         | Gmail     | Outlook      | Google Maps |
        | Chrome    | Netflix     | Amazon       | Uber            | Messenger | ChatGPT      | X           |
        | Reddit    | Telegram    | Discord      | Microsoft Teams | Zoom      | Clash Royale | Roblox      |
        | **Games** | **Banking** | **Shopping** | **School**      | **Work**  | **Fitness**  | **Food**    |
        """
        let layout = try XCTUnwrap(SpriteSheet.parseNames(sheet))
        XCTAssertEqual(layout.cellCount, 49)

        let unmatched = layout.flattened.filter { !$0.isEmpty && SpriteSheet.app(named: $0) == nil }
        // Only the last row, which names categories rather than apps.
        XCTAssertEqual(
            Set(unmatched),
            ["Games", "Banking", "Shopping", "School", "Work", "Fitness", "Food"],
            "an app in the sheet lost its catalogue entry"
        )
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

    /// A green backdrop with a dark plate in the middle carrying a green
    /// shape - a Messages or WhatsApp icon in miniature. The inner green is
    /// enclosed by the plate, so nothing connects it to the border.
    private static func greenIconOnGreen() throws -> CGImage {
        let side = 100
        let context = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // Backdrop: the bright green these sheets arrive on.
        context.setFillColor(CGColor(red: 0.24, green: 0.94, blue: 0.20, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        // The icon's dark plate.
        context.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1))
        context.fill(CGRect(x: 25, y: 25, width: 50, height: 50))
        // The green bubble inside it, the same green as the backdrop.
        context.setFillColor(CGColor(red: 0.24, green: 0.94, blue: 0.20, alpha: 1))
        context.fill(CGRect(x: 40, y: 40, width: 20, height: 20))
        return try XCTUnwrap(context.makeImage())
    }

    /// A centred icon plus a stripe of the neighbour down the left edge, which
    /// is what an imperfectly divided sheet hands each cell.
    private static func iconWithNeighbourSliver() throws -> CGImage {
        let side = 100
        let context = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.24, green: 0.94, blue: 0.20, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        // This cell's icon, in the middle.
        context.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1))
        context.fill(CGRect(x: 25, y: 25, width: 50, height: 50))
        // The neighbour's edge, cut into this cell and touching it.
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 20, width: 4, height: 60))
        return try XCTUnwrap(context.makeImage())
    }

    /// Three 40px plates on green, with a 30px left margin and a 10px right
    /// one - the uneven margins a generated sheet actually arrives with.
    private static func offsetGrid() throws -> CGImage {
        let width = 210, height = 60
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.24, green: 0.94, blue: 0.20, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1))
        for column in 0 ..< 3 {
            context.fill(CGRect(x: 30 + column * 60, y: 10, width: 40, height: 40))
        }
        return try XCTUnwrap(context.makeImage())
    }

    /// Reads pixels back in a known layout, row 0 at the top.
    private struct Pixels {
        let bytes: [UInt8]
        let width: Int

        init(_ image: CGImage) throws {
            let width = image.width
            let height = image.height
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            let drew = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            XCTAssertTrue(drew, "could not read the image back")
            self.width = width
            bytes = buffer
        }

        func alpha(x: Int, y: Int) -> Int { Int(bytes[(y * width + x) * 4 + 3]) }

        func isGreenish(x: Int, y: Int) -> Bool {
            let index = (y * width + x) * 4
            let red = Int(bytes[index])
            let green = Int(bytes[index + 1])
            let blue = Int(bytes[index + 2])
            return green > 120 && green > red + 40 && green > blue + 40
        }
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
