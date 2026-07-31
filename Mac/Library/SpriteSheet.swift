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

        // Scaled to the same 0-255 space the samples are in.
        let reach = tolerance * 255 * 1.75

        func matches(_ index: Int) -> Bool {
            let dr = Double(Int(pixels[index]) - keyR)
            let dg = Double(Int(pixels[index + 1]) - keyG)
            let db = Double(Int(pixels[index + 2]) - keyB)
            return (dr * dr + dg * dg + db * db).squareRoot() <= reach
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

        // Clear what the fill reached, and take the backdrop's colour cast out
        // of what borders it - an antialiased edge is part icon, part
        // backdrop, and left alone it reads as a coloured rim.
        for point in 0 ..< width * height {
            let index = point * 4
            if outside[point] {
                pixels[index] = 0
                pixels[index + 1] = 0
                pixels[index + 2] = 0
                pixels[index + 3] = 0
                continue
            }
            let x = point % width
            let y = point / width
            let touchesOutside =
                (x > 0 && outside[point - 1]) ||
                (x < width - 1 && outside[point + 1]) ||
                (y > 0 && outside[point - width]) ||
                (y < height - 1 && outside[point + width])
            guard touchesOutside else { continue }
            // Only where the key's dominant channel is over-represented, so a
            // genuinely green pixel of artwork is left as it is.
            let green = Int(pixels[index + 1])
            let others = max(Int(pixels[index]), Int(pixels[index + 2]))
            if keyG > keyR, keyG > keyB, green > others {
                pixels[index + 1] = UInt8(others)
            }
        }

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
        /// Labels that became a skin and matched a catalogue app, so they can
        /// be offered as a set.
        var entries: [SkinSet.Entry] = []
        /// Labels whose artwork was imported but that name no app the
        /// catalogue knows - they are usable as a tile's skin by hand.
        var unmatched: [String] = []
        var skippedBlanks = 0

        var importedCount: Int { entries.count + unmatched.count }
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
        let cells = slice(image, rows: layout.rows, columns: layout.columns)
        let labels = layout.flattened
        var report = Report()

        for (index, label) in labels.enumerated() {
            guard !label.isEmpty else {
                report.skippedBlanks += 1
                continue
            }
            guard index < cells.count else { break }

            let name = skinName(for: label, prefix: prefix)
            // Surround only: the icons on these sheets are frequently green
            // themselves, and a colour key would hollow them out.
            let cell = removingSurround(cells[index]) ?? cells[index]
            try library.importing(cell, named: name, alreadyKeyed: true)

            if let app = app(named: label) {
                report.entries.append(SkinSet.Entry(appID: app.id, skin: name))
            } else {
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
