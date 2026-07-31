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
        let cellWidth = CGFloat(image.width) / CGFloat(columns)
        let cellHeight = CGFloat(image.height) / CGFloat(rows)
        var cells: [CGImage] = []
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                let rect = CGRect(
                    x: CGFloat(column) * cellWidth,
                    y: CGFloat(row) * cellHeight,
                    width: cellWidth,
                    height: cellHeight
                ).integral
                guard let cell = image.cropping(to: rect) else { continue }
                cells.append(cell)
            }
        }
        return cells
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
            try library.importing(cells[index], named: name)

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
