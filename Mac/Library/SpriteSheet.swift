import CoreGraphics
import Foundation
import os

/// A grid of icons in one picture, plus the table of names that says what each
/// cell is.
///
/// Generated icon art arrives as a sheet - 49 icons on a green background in
/// one square PNG - and cutting it up by hand into 49 files, keying each one
/// and naming it, is an afternoon. The names table is also the layout: seven
/// columns of names means seven columns of icons, so nothing has to be counted
/// twice.
enum SpriteSheet {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "SpriteSheet")

    struct Layout: Equatable {
        /// Row-major, and rectangular: short rows are padded so a cell's
        /// position in the picture always matches its position here.
        var names: [[String]]

        var rows: Int { names.count }
        var columns: Int { names.first?.count ?? 0 }
        var cellCount: Int { rows * columns }

        /// The names in reading order, with the blanks left in so an index
        /// still lines up with a cell.
        var flattened: [String] { names.flatMap { $0 } }
    }

    /// Reads a markdown table, or anything close to one.
    ///
    /// Accepts the pipe-separated form as pasted, with or without the
    /// `| --- |` separator row and with or without `**bold**` around a name. A
    /// blank cell is legal and means "skip this one", which is how a sheet
    /// with a gap in it gets described.
    static func parseNames(_ text: String) -> Layout? {
        var rows: [[String]] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // The `|---|---|` rule under a markdown header carries no names.
            if trimmed.allSatisfy({ "|-: \t".contains($0) }) { continue }

            var cells = trimmed.components(separatedBy: "|")
            // A row written `| a | b |` has an empty cell at each end from the
            // outer pipes; one written `a | b` does not.
            if trimmed.hasPrefix("|") { cells.removeFirst() }
            if trimmed.hasSuffix("|"), !cells.isEmpty { cells.removeLast() }

            let names = cells.map { cell in
                cell.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "**", with: "")
                    .replacingOccurrences(of: "*", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            guard !names.isEmpty else { continue }
            rows.append(names)
        }
        guard !rows.isEmpty else { return nil }

        // Padded to the widest row: a ragged table would put every name after
        // the short row against the wrong picture.
        let width = rows.map(\.count).max() ?? 0
        let padded = rows.map { $0 + Array(repeating: "", count: width - $0.count) }
        return Layout(names: padded)
    }

    /// Cuts a sheet into equal cells, row-major.
    ///
    /// Equal division rather than content detection: these sheets are laid out
    /// on a grid by whatever drew them, and guessing at the gaps is how a
    /// one-pixel drift turns into every icon being cropped slightly wrong.
    static func slice(_ image: CGImage, rows: Int, columns: Int) -> [CGImage] {
        guard rows > 0, columns > 0 else { return [] }
        // Boundaries first, then the rects between them. Rounding each cell's
        // own origin and size instead - which is what `.integral` on a
        // separately computed rect does - leaves gaps and overlaps wherever
        // the sheet does not divide evenly: 1254 across 7 columns is 179.14,
        // and by the last column the cut has drifted a pixel and a half.
        func bounds(_ total: Int, _ count: Int) -> [Int] {
            (0 ... count).map { Int((Double(total) * Double($0) / Double(count)).rounded()) }
        }
        let xs = bounds(image.width, columns)
        let ys = bounds(image.height, rows)

        var cells: [CGImage] = []
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                let rect = CGRect(
                    x: xs[column],
                    y: ys[row],
                    width: xs[column + 1] - xs[column],
                    height: ys[row + 1] - ys[row]
                )
                guard let cell = image.cropping(to: rect) else { continue }
                cells.append(cell)
            }
        }
        return cells
    }

    /// Finds each icon in the sheet and cuts tightly around it.
    ///
    /// Equal division assumes the margins are exactly half a gutter, and they
    /// are not: on the sheet this was built for the icons sit at 44-181,
    /// 215-351 and so on, while an even seventh cuts at 0, 179, 358. By the
    /// last column the cut starts ten pixels after its icon begins, which is
    /// what clipped Google Maps and Roblox down one side.
    ///
    /// So the backdrop is what gets measured. Everything that is not backdrop
    /// is grouped into pieces, each piece is an icon, and each is cut to its
    /// own bounds - which also centres it, since the bounds are what get
    /// squared up. Cells with nothing in them come back nil, so a name still
    /// lines up with the picture it belongs to.
    static func icons(in sheet: CGImage, rows: Int, columns: Int) -> [CGImage?] {
        guard rows > 0, columns > 0 else { return [] }
        let width = sheet.width
        let height = sheet.height
        guard width > 2, height > 2 else { return [] }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drew = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(sheet, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return [] }

        let keyR = Int(pixels[0]), keyG = Int(pixels[1]), keyB = Int(pixels[2])
        func isBackdrop(_ point: Int) -> Bool {
            let index = point * 4
            return Self.isBackdrop(
                red: Int(pixels[index]), green: Int(pixels[index + 1]), blue: Int(pixels[index + 2]),
                keyRed: keyR, keyGreen: keyG, keyBlue: keyB, tolerance: 0.30
            )
        }

        // Every run of touching non-backdrop pixels is one icon: the sheet
        // keeps them a good gutter apart, so nothing joins up.
        var seen = [Bool](repeating: false, count: width * height)
        var found: [(rect: CGRect, centre: CGPoint)] = []
        let smallest = (width / columns) * (height / rows) / 12

        for start in 0 ..< width * height where !seen[start] && !isBackdrop(start) {
            var minX = width, maxX = 0, minY = height, maxY = 0
            var area = 0
            var stack = [start]
            seen[start] = true
            while let point = stack.popLast() {
                area += 1
                let x = point % width
                let y = point / width
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                for neighbour in [
                    x > 0 ? point - 1 : -1,
                    x < width - 1 ? point + 1 : -1,
                    y > 0 ? point - width : -1,
                    y < height - 1 ? point + width : -1,
                ] where neighbour >= 0 && !seen[neighbour] && !isBackdrop(neighbour) {
                    seen[neighbour] = true
                    stack.append(neighbour)
                }
            }
            guard area >= smallest else { continue }
            let rect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            found.append((rect, CGPoint(x: rect.midX, y: rect.midY)))
        }

        // Each icon belongs to the cell its middle falls in, which is what
        // keeps a name against the right picture even though the cut does not.
        var result = [CGImage?](repeating: nil, count: rows * columns)
        let cellWidth = Double(width) / Double(columns)
        let cellHeight = Double(height) / Double(rows)
        for icon in found {
            let column = min(columns - 1, max(0, Int(icon.centre.x / cellWidth)))
            let row = min(rows - 1, max(0, Int(icon.centre.y / cellHeight)))
            let slot = row * columns + column
            // Two pieces in one cell means the bigger one is the icon.
            if let existing = result[slot],
               existing.width * existing.height >= Int(icon.rect.width * icon.rect.height) {
                continue
            }
            result[slot] = sheet.cropping(to: icon.rect)
        }
        return result
    }

    /// Whether a pixel is the sheet's backdrop.
    ///
    /// Two ways of being it. Close in plain colour catches the flat field, and
    /// close in *hue* catches the same colour in shadow: an icon casts one
    /// onto the green it sits on, and those pixels are far too dark to match
    /// the bright corner the key was read from. Left unmatched they survived
    /// the fill as a dark rim around every plate.
    ///
    /// Being generous about hue is safe because the fill still has to reach a
    /// pixel from the border, so green enclosed by an icon is never a
    /// candidate however green it is.
    static func isBackdrop(
        red: Int, green: Int, blue: Int,
        keyRed: Int, keyGreen: Int, keyBlue: Int,
        tolerance: Double
    ) -> Bool {
        let dr = Double(red - keyRed), dg = Double(green - keyGreen), db = Double(blue - keyBlue)
        if (dr * dr + dg * dg + db * db).squareRoot() <= tolerance * 255 * 1.75 { return true }

        // Near-black is the icon's own shadow rather than a shaded backdrop,
        // and its hue means nothing at that brightness.
        let sum = red + green + blue
        let keySum = keyRed + keyGreen + keyBlue
        guard sum > 30, keySum > 30 else { return false }
        let hueReach = tolerance * 0.55
        return abs(Double(red) / Double(sum) - Double(keyRed) / Double(keySum)) < hueReach
            && abs(Double(green) / Double(sum) - Double(keyGreen) / Double(keySum)) < hueReach
    }

    /// Clears the backdrop from around a cell without touching the artwork.
    ///
    /// Keying by colour alone removes every matching pixel wherever it is,
    /// which on a green sheet takes the green out of Messages, Phone,
    /// FaceTime, WhatsApp and Spotify - the icons most likely to be on it.
    /// This fills inwards from the border instead, so only backdrop connected
    /// to the outside goes, and green inside an icon stays green.
    static func removingSurround(_ image: CGImage, tolerance: Double = 0.30) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 2, height > 2 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drew = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }

        // The backdrop colour, taken from the corners: a sheet's cell has its
        // artwork in the middle, so the corners are the one place certain to
        // be backdrop.
        let corners = [
            (0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1),
        ]
        var keyR = 0, keyG = 0, keyB = 0
        for (x, y) in corners {
            let index = (y * width + x) * 4
            keyR += Int(pixels[index])
            keyG += Int(pixels[index + 1])
            keyB += Int(pixels[index + 2])
        }
        keyR /= corners.count
        keyG /= corners.count
        keyB /= corners.count

        func matches(_ index: Int) -> Bool {
            isBackdrop(
                red: Int(pixels[index]), green: Int(pixels[index + 1]), blue: Int(pixels[index + 2]),
                keyRed: keyR, keyGreen: keyG, keyBlue: keyB, tolerance: tolerance
            )
        }

        // Flood fill inwards from every border pixel that is backdrop.
        var outside = [Bool](repeating: false, count: width * height)
        var stack: [Int] = []
        for x in 0 ..< width {
            stack.append(x)
            stack.append((height - 1) * width + x)
        }
        for y in 0 ..< height {
            stack.append(y * width)
            stack.append(y * width + width - 1)
        }

        while let point = stack.popLast() {
            guard !outside[point], matches(point * 4) else { continue }
            outside[point] = true
            let x = point % width
            let y = point / width
            if x > 0 { stack.append(point - 1) }
            if x < width - 1 { stack.append(point + 1) }
            if y > 0 { stack.append(point - width) }
            if y < height - 1 { stack.append(point + width) }
        }

        // Anything left that is not this cell's own icon is a sliver of the
        // neighbouring one, caught because a sheet's margins rarely divide
        // into exactly equal cells. It is not backdrop, so the fill leaves it,
        // and the trim then treats it as content - a stripe down the side of
        // half the icons.
        discardStrays(&outside, width: width, height: height)

        for point in 0 ..< width * height where outside[point] {
            let index = point * 4
            pixels[index] = 0
            pixels[index + 1] = 0
            pixels[index + 2] = 0
            pixels[index + 3] = 0
        }

        unmix(
            &pixels, width: width, height: height, outside: outside,
            keyRed: keyR, keyGreen: keyG, keyBlue: keyB
        )

        return pixels.withUnsafeMutableBytes { raw -> CGImage? in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return context.makeImage()
        }
    }

    /// How much of a pixel is backdrop rather than artwork, from 0 to 1.
    ///
    /// The flood fill answers yes or no, and an edge is neither: a pixel where
    /// the icon meets the backdrop is a mixture of the two, and keeping it
    /// whole leaves the backdrop's colour in it. That mixture is what shows up
    /// as a rim around every plate.
    ///
    /// Measured as a difference key on chromaticity - how far the key's
    /// dominant channel leads the other two, against how far it leads them in
    /// the key itself. On chromaticity rather than raw values because the
    /// shadow an icon casts onto the green is still the green, and at a third
    /// of the brightness a raw comparison says it is not.
    static func backdropFraction(
        red: Int, green: Int, blue: Int,
        keyRed: Int, keyGreen: Int, keyBlue: Int
    ) -> Double {
        let sum = Double(red + green + blue)
        let keySum = Double(keyRed + keyGreen + keyBlue)
        // Near-black carries no useful chromaticity: the ratios are one or two
        // units of noise apart and any of the three can come out on top. The
        // floor is low because the last of a rim is very dark - a (0,24,0) is
        // still unmistakably the key, and a dozen of them read as a green line.
        guard sum > 10, keySum > 24 else { return 0 }

        let key = [Double(keyRed) / keySum, Double(keyGreen) / keySum, Double(keyBlue) / keySum]
        guard let dominant = key.indices.max(by: { key[$0] < key[$1] }) else { return 0 }
        let keyLead = key[dominant] - key.indices.filter { $0 != dominant }.map { key[$0] }.max()!
        // A grey backdrop leads by nothing, and dividing by that would call
        // every pixel in the picture backdrop.
        guard keyLead > 0.05 else { return 0 }

        let pixel = [Double(red) / sum, Double(green) / sum, Double(blue) / sum]
        let lead = pixel[dominant] - pixel.indices.filter { $0 != dominant }.map { pixel[$0] }.max()!
        return min(max(lead / keyLead, 0), 1)
    }

    /// Takes the backdrop back out of the pixels it is mixed into.
    ///
    /// Walks inwards from everything the fill cleared - and from the picture's
    /// own edge, since a cell cut tight has its icon running to it - through
    /// pixels that still carry some backdrop. Each one is recovered as what it
    /// would have been over nothing: the mixture solved for the icon's own
    /// colour, and the backdrop's share taken out of the alpha instead. That
    /// is what turns a green rim into a soft edge.
    ///
    /// Bounded to a few pixels, because the artwork on these sheets is often
    /// green itself: an unbounded walk would dissolve Spotify from its edge
    /// inwards the moment its green touched the fill.
    private static func unmix(
        _ pixels: inout [UInt8], width: Int, height: Int, outside: [Bool],
        keyRed: Int, keyGreen: Int, keyBlue: Int, reach: Int = 3
    ) {
        var depth = [Int](repeating: .max, count: width * height)
        var queue: [Int] = []
        for point in 0 ..< width * height where !outside[point] {
            let x = point % width
            let y = point / width
            let borders = x == 0 || y == 0 || x == width - 1 || y == height - 1
                || (x > 0 && outside[point - 1])
                || (x < width - 1 && outside[point + 1])
                || (y > 0 && outside[point - width])
                || (y < height - 1 && outside[point + width])
            if borders {
                depth[point] = 1
                queue.append(point)
            }
        }

        var head = 0
        while head < queue.count {
            let point = queue[head]
            head += 1
            let index = point * 4
            let fraction = backdropFraction(
                red: Int(pixels[index]), green: Int(pixels[index + 1]), blue: Int(pixels[index + 2]),
                keyRed: keyRed, keyGreen: keyGreen, keyBlue: keyBlue
            )
            // Clean artwork: nothing to take out, and nothing beyond it can be
            // contaminated either, so the walk stops here.
            guard fraction > 0.06 else { continue }

            if fraction > 0.94 {
                pixels[index] = 0
                pixels[index + 1] = 0
                pixels[index + 2] = 0
                pixels[index + 3] = 0
            } else {
                let keep = 1 - fraction
                // The mixture solved for the icon: what is left once the
                // backdrop's share of the colour is subtracted.
                let recovered = [
                    (Double(pixels[index]) - fraction * Double(keyRed)) / keep,
                    (Double(pixels[index + 1]) - fraction * Double(keyGreen)) / keep,
                    (Double(pixels[index + 2]) - fraction * Double(keyBlue)) / keep,
                ]
                for channel in 0 ..< 3 {
                    pixels[index + channel] = UInt8(min(max(recovered[channel], 0), 255))
                }
                pixels[index + 3] = UInt8(min(max(keep * Double(pixels[index + 3]), 0), 255))
            }

            guard depth[point] < reach else { continue }
            let x = point % width
            let y = point / width
            for neighbour in [
                x > 0 ? point - 1 : nil,
                x < width - 1 ? point + 1 : nil,
                y > 0 ? point - width : nil,
                y < height - 1 ? point + width : nil,
            ].compactMap({ $0 }) where !outside[neighbour] && depth[neighbour] == .max {
                depth[neighbour] = depth[point] + 1
                queue.append(neighbour)
            }
        }
    }

    /// Marks everything that is not the cell's own icon as backdrop.
    ///
    /// The icon sits in the middle of its cell, so the piece under the centre
    /// is the one to keep. A piece that touches the cell's edge belongs to the
    /// neighbour it was cut from - unless it is a fair share of the icon's own
    /// size, which is the case where the icon really does run to the edge and
    /// throwing it away would leave nothing.
    private static func discardStrays(_ outside: inout [Bool], width: Int, height: Int) {
        // Label the pieces the fill did not reach.
        var label = [Int](repeating: 0, count: width * height)
        var areas: [Int] = [0]
        var touchesEdge: [Bool] = [false]

        for start in 0 ..< width * height where !outside[start] && label[start] == 0 {
            let current = areas.count
            var area = 0
            var edge = false
            var stack = [start]
            label[start] = current
            while let point = stack.popLast() {
                area += 1
                let x = point % width
                let y = point / width
                if x == 0 || y == 0 || x == width - 1 || y == height - 1 { edge = true }
                for neighbour in [
                    x > 0 ? point - 1 : -1,
                    x < width - 1 ? point + 1 : -1,
                    y > 0 ? point - width : -1,
                    y < height - 1 ? point + width : -1,
                ] where neighbour >= 0 && !outside[neighbour] && label[neighbour] == 0 {
                    label[neighbour] = current
                    stack.append(neighbour)
                }
            }
            areas.append(area)
            touchesEdge.append(edge)
        }
        guard areas.count > 2 else { return }

        // The piece under the middle of the cell, or the biggest one when the
        // middle happens to be a hole in the artwork.
        var main = label[(height / 2) * width + width / 2]
        if main == 0 {
            main = (1 ..< areas.count).max { areas[$0] < areas[$1] } ?? 0
        }
        guard main != 0 else { return }

        for point in 0 ..< width * height where !outside[point] {
            let piece = label[point]
            guard piece != main, touchesEdge[piece] else { continue }
            // A quarter of the icon is too much to be a cut neighbour.
            guard areas[piece] * 4 < areas[main] else { continue }
            outside[point] = true
        }
    }

    /// The catalogue app a label names, matched loosely.
    ///
    /// "Apple Music", "apple music" and "AppleMusic" are the same app, and a
    /// sheet's labels are written for a person rather than for this lookup.
    static func app(named label: String) -> CatalogApp? {
        let wanted = normalised(label)
        guard !wanted.isEmpty else { return nil }
        return AppCatalog.all.first {
            normalised($0.name) == wanted || normalised($0.id) == wanted
        }
    }

    /// The id a label with no catalogue app behind it stands under.
    ///
    /// The label's own letters, which cannot collide with a catalogue id
    /// because a collision would mean the label matched one - and then this is
    /// not reached at all.
    static func categoryID(for label: String) -> String {
        normalised(label)
    }

    private static func normalised(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// A filename-safe skin name for a label.
    static func skinName(for label: String, prefix: String) -> String {
        let safe = label
            .replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .lowercased()
        return "\(prefix)-\(safe.prefix(40)).png"
    }

    struct Report {
        /// Every label that became a skin, ready to be offered as a set. A
        /// label the catalogue does not know is in here too, under its own
        /// name, so a category is as choosable on the phone as an app is.
        var entries: [SkinSet.Entry] = []
        /// Labels that name no app the catalogue knows. They are in `entries`
        /// as well; this is what the import report counts, because they are
        /// the ones that will ask the phone what they open.
        var unmatched: [String] = []
        /// Named cells the sheet had no icon in.
        var missing: [String] = []
        var skippedBlanks = 0

        var importedCount: Int { entries.count }
    }

    /// Cuts, keys and imports every named cell, returning what became what.
    ///
    /// Each cell goes through the skin library's own import - keyed, trimmed,
    /// squared and scaled - so a sheet's icons end up identical in size and
    /// treatment to one imported on its own.
    static func importSheet(
        _ image: CGImage,
        layout: Layout,
        prefix: String,
        into library: SkinLibrary
    ) throws -> Report {
        // Measured rather than divided: an even seventh of a sheet is not
        // where its icons are, and the last column paid for it.
        var cells = icons(in: image, rows: layout.rows, columns: layout.columns)
        if cells.compactMap({ $0 }).count < layout.cellCount / 2 {
            // Not a sheet of separated icons after all - fall back to cutting
            // it evenly rather than importing almost nothing.
            logger.error("only \(cells.compactMap { $0 }.count) icons found; falling back to an even cut")
            cells = slice(image, rows: layout.rows, columns: layout.columns).map { Optional($0) }
        }
        let labels = layout.flattened
        var report = Report()

        for (index, label) in labels.enumerated() {
            guard !label.isEmpty else {
                report.skippedBlanks += 1
                continue
            }
            guard index < cells.count else { break }
            guard let cut = cells[index] else {
                // Named, because a silently missing icon reads as a bad cut
                // rather than as a cell with nothing in it.
                logger.error("no icon found for \(label, privacy: .public)")
                report.missing.append(label)
                continue
            }

            let name = skinName(for: label, prefix: prefix)
            // Surround only: the icons on these sheets are frequently green
            // themselves, and a colour key would hollow them out.
            let cell = removingSurround(cut) ?? cut
            try library.importing(cell, named: name, alreadyKeyed: true)

            if let app = app(named: label) {
                report.entries.append(SkinSet.Entry(appID: app.id, skin: name))
            } else {
                // Still an entry. A sheet's last row is usually categories -
                // Games, Banking, Work - and dropping them here left their
                // artwork in the library but in no set, so the phone's picker
                // never offered them and they could only be put on a tile by
                // hand in the studio. Keyed by the label itself, which the
                // catalogue does not know: the phone recognises that and asks
                // what to call it and what it should open.
                report.entries.append(SkinSet.Entry(appID: categoryID(for: label), skin: name))
                report.unmatched.append(label)
            }
        }

        logger.info("""
        sheet \(prefix, privacy: .public): \(report.entries.count) matched, \
        \(report.unmatched.count) unmatched, \(report.skippedBlanks) blank
        """)
        return report
    }
}
