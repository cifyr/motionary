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

    /// An icon casts a shadow onto the green it sits on. Those pixels are far
    /// too dark to match the bright corner the key is read from, so matching
    /// on plain colour alone left a dark green rim around every plate.
    func testShadedBackdropIsStillBackdrop() {
        // A bright key, and the same green at a third of the brightness.
        let shaded = SpriteSheet.isBackdrop(
            red: 6, green: 82, blue: 8,
            keyRed: 13, keyGreen: 246, keyBlue: 19, tolerance: 0.30
        )
        XCTAssertTrue(shaded, "a shaded backdrop was treated as artwork")
    }

    /// What an icon's own green is protected by is enclosure, not colour.
    ///
    /// Messages' bubble sits within a few dozen units of the backdrop and
    /// always matched it; `testGreenInsideAnIconSurvives` is what proves it
    /// survives, because the fill can never reach it. Colour only has to tell
    /// the backdrop from things that are plainly not it.
    func testPlainlyDifferentColoursAreNotBackdrop() {
        // The plate, its blue frame, and the gold of the Clash Royale crest.
        for colour in [(10, 10, 12), (26, 60, 140), (196, 148, 44)] {
            XCTAssertFalse(
                SpriteSheet.isBackdrop(
                    red: colour.0, green: colour.1, blue: colour.2,
                    keyRed: 13, keyGreen: 246, keyBlue: 19, tolerance: 0.30
                ),
                "\(colour) was mistaken for backdrop"
            )
        }
    }

    /// Near-black is the icon's shadow, not a shaded backdrop: at that
    /// brightness hue means nothing.
    func testNearBlackIsNotBackdrop() {
        XCTAssertFalse(SpriteSheet.isBackdrop(
            red: 4, green: 9, blue: 5,
            keyRed: 13, keyGreen: 246, keyBlue: 19, tolerance: 0.30
        ))
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
        // These two drew but could not be opened until their routes were
        // researched; Apple documents none of them, so they carry several.
        XCTAssertEqual(SpriteSheet.app(named: "Weather")?.canLaunch, true)
        XCTAssertEqual(SpriteSheet.app(named: "Calculator")?.canLaunch, true)
        XCTAssertEqual(SpriteSheet.app(named: "Zoom")?.canLaunch, true)
    }

    /// A sheet's last row is usually categories - Games, Banking, Work - and
    /// they were imported as artwork but left out of the set, so the phone's
    /// picker never offered them: the one row of a sheet that could not be
    /// chosen on the phone at all.
    func testACategoryLabelStillJoinsTheSet() throws {
        let sheet = try Self.offsetGrid()
        let layout = try XCTUnwrap(SpriteSheet.parseNames("| Safari | Games | Banking |"))
        let library = try SkinLibrary(root: Self.temporaryLibrary())
        defer { try? FileManager.default.removeItem(at: library.root) }

        let report = try SpriteSheet.importSheet(sheet, layout: layout, prefix: "sheet-x", into: library)

        XCTAssertEqual(report.entries.count, 3, "a category was dropped from the set")
        XCTAssertEqual(report.unmatched, ["Games", "Banking"], "they still count as unmatched")
        XCTAssertEqual(
            report.entries.map(\.appID).sorted(), ["banking", "games", "safari"],
            "a category stands under its own name"
        )
    }

    /// It must not shadow a catalogue app, or that app becomes impossible to
    /// choose - though it cannot, since a label matching one never gets here.
    func testACategoryIDIsNotACatalogueApp() {
        for label in ["Games", "Banking", "Work", "Food", "Shopping"] {
            XCTAssertNil(
                AppCatalog.app(id: SpriteSheet.categoryID(for: label)),
                "\(label) collides with a catalogue app"
            )
        }
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

    // MARK: - Taking the backdrop out of the edge

    /// The fill answers yes or no, and an antialiased edge is neither. Left
    /// whole, those half-and-half pixels keep the backdrop's colour, which is
    /// the green line that showed around every plate on the phone.
    func testAHalfAndHalfPixelIsHalfBackdrop() {
        let fraction = SpriteSheet.backdropFraction(
            red: 30, green: 130, blue: 30, keyRed: 60, keyGreen: 240, keyBlue: 50
        )
        XCTAssertGreaterThan(fraction, 0.5)
        XCTAssertLessThan(fraction, 1.01)
    }

    func testTheKeyItselfIsAllBackdrop() {
        XCTAssertEqual(
            SpriteSheet.backdropFraction(
                red: 60, green: 240, blue: 50, keyRed: 60, keyGreen: 240, keyBlue: 50
            ),
            1, accuracy: 0.001
        )
    }

    /// The shadow an icon casts onto the green is still the green, at a third
    /// of the brightness. Measuring on raw values would call it artwork.
    func testShadedKeyIsStillAllBackdrop() {
        XCTAssertEqual(
            SpriteSheet.backdropFraction(
                red: 20, green: 80, blue: 17, keyRed: 60, keyGreen: 240, keyBlue: 50
            ),
            1, accuracy: 0.05
        )
    }

    func testArtworkCarriesNoneOfTheBackdrop() {
        // A blue plate and a red mark: neither leads with the key's channel.
        XCTAssertEqual(
            SpriteSheet.backdropFraction(red: 20, green: 30, blue: 200, keyRed: 60, keyGreen: 240, keyBlue: 50),
            0, accuracy: 0.001
        )
        XCTAssertEqual(
            SpriteSheet.backdropFraction(red: 200, green: 40, blue: 40, keyRed: 60, keyGreen: 240, keyBlue: 50),
            0, accuracy: 0.001
        )
    }

    /// A grey backdrop leads by nothing, and dividing by that would call every
    /// pixel in the picture backdrop.
    func testAColourlessKeyMatchesNothing() {
        XCTAssertEqual(
            SpriteSheet.backdropFraction(red: 0, green: 200, blue: 0, keyRed: 128, keyGreen: 130, keyBlue: 127),
            0
        )
    }

    /// The last of a rim is very dark - a (0,24,0) is unmistakably the key, and
    /// a line of them is what stayed visible after the flood fill.
    func testAVeryDarkRimPixelIsStillTheKey() {
        XCTAssertGreaterThan(
            SpriteSheet.backdropFraction(red: 0, green: 24, blue: 0, keyRed: 60, keyGreen: 240, keyBlue: 50),
            0.9
        )
    }

    /// Black is black at any brightness: its channels are noise apart and any
    /// of the three can come out on top, so nothing may be read into it.
    func testBlackCarriesNoBackdrop() {
        XCTAssertEqual(
            SpriteSheet.backdropFraction(red: 2, green: 3, blue: 2, keyRed: 60, keyGreen: 240, keyBlue: 50),
            0
        )
    }

    /// The whole point, end to end: an icon whose edge was drawn against the
    /// green must come out with no green on it.
    func testNoGreenSurvivesOnAKeyedEdge() throws {
        let cleared = try XCTUnwrap(SpriteSheet.removingSurround(Self.antialiasedPlate()))
        let pixels = try Pixels(cleared)

        for x in 0 ..< 100 {
            for y in 0 ..< 100 where pixels.alpha(x: x, y: y) > 0 {
                XCTAssertFalse(
                    pixels.isGreenish(x: x, y: y),
                    "the backdrop is still mixed into the pixel at \(x),\(y)"
                )
            }
        }
        XCTAssertEqual(pixels.alpha(x: 50, y: 50), 255, "the plate itself was removed")
    }

    /// And it must not cost the artwork: a slot's own green is what the
    /// enclosure rule protects, and softening the edge must not reach it.
    func testTheEdgePassLeavesAnIconsOwnGreenAlone() throws {
        let cleared = try XCTUnwrap(SpriteSheet.removingSurround(try Self.greenIconOnGreen()))
        let pixels = try Pixels(cleared)
        XCTAssertEqual(pixels.alpha(x: 50, y: 50), 255)
        XCTAssertTrue(pixels.isGreenish(x: 50, y: 50))
    }

    // MARK: - Helpers

    /// A dark plate drawn onto green with a soft edge, which is what every
    /// generated sheet hands over: the boundary pixels are a mixture of the two
    /// rather than one or the other.
    private static func antialiasedPlate() -> CGImage {
        let side = 100
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let key = (r: 61.0, g: 240.0, b: 51.0)
        let plate = (r: 13.0, g: 13.0, b: 18.0)
        for y in 0 ..< side {
            for x in 0 ..< side {
                // Distance from the plate's edge, in pixels, so a two-pixel
                // band around it comes out as a mixture.
                let inset = min(min(x, side - 1 - x), min(y, side - 1 - y)) - 24
                let share = min(max(Double(inset) / 2, 0), 1)
                let index = (y * side + x) * 4
                pixels[index] = UInt8(key.r + (plate.r - key.r) * share)
                pixels[index + 1] = UInt8(key.g + (plate.g - key.g) * share)
                pixels[index + 2] = UInt8(key.b + (plate.b - key.b) * share)
                pixels[index + 3] = 255
            }
        }
        return pixels.withUnsafeMutableBytes { raw in
            CGContext(
                data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!.makeImage()!
        }
    }

    private static func temporaryLibrary() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("motionary-sheet-\(UUID().uuidString)", isDirectory: true)
    }

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
