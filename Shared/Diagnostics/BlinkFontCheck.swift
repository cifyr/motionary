import Foundation

/// Reads which seconds a blink mask is solid on, out of the font the system
/// actually resolved.
///
/// The masks are one file with sixty bytes changed - the substitution that maps
/// the timer's seconds digits onto a filled square or nothing. Resolving one by
/// name proves only that something answered to the name, and a font handed back
/// with the wrong table substitutes on the wrong seconds: the groups gated to
/// each second never come up, and the widget is black rather than wrong. This
/// is how the extension can tell those two apart from inside itself.
enum BlinkFontCheck {
    /// Glyph 14 is the filled square in these fonts; 13 is empty.
    static let solidGlyph: UInt16 = 14

    static func solidSeconds(in gsub: Data) -> [Int] {
        func u16(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 1 < gsub.count else { return nil }
            return Int(gsub[gsub.startIndex + offset]) << 8 | Int(gsub[gsub.startIndex + offset + 1])
        }
        guard let lookupList = u16(8),
              let lookup = u16(lookupList + 2).map({ lookupList + $0 }),
              let subtable = u16(lookup + 6).map({ lookup + $0 }),
              let coverageOffset = u16(subtable + 2),
              let setCount = u16(subtable + 4)
        else { return [] }

        let coverage = subtable + coverageOffset
        guard let format = u16(coverage), let entries = u16(coverage + 2) else { return [] }
        var firstGlyphs: [Int] = []
        if format == 1 {
            firstGlyphs = (0 ..< entries).compactMap { u16(coverage + 4 + $0 * 2) }
        } else if format == 2 {
            for i in 0 ..< entries {
                guard let start = u16(coverage + 4 + i * 6), let end = u16(coverage + 6 + i * 6) else { continue }
                firstGlyphs += Array(start ... max(start, end))
            }
        }

        var solid: [Int] = []
        for index in 0 ..< setCount {
            guard index < firstGlyphs.count,
                  let setOffset = u16(subtable + 6 + index * 2)
            else { continue }
            let set = subtable + setOffset
            guard let count = u16(set) else { continue }
            // Glyph 2 is '0', so the first glyph identifies the tens digit.
            let tens = firstGlyphs[index] - 2
            for j in 0 ..< count {
                guard let ligOffset = u16(set + 2 + j * 2),
                      let glyph = u16(set + ligOffset)
                else { continue }
                if glyph == Int(solidGlyph) { solid.append(tens * 10 + j) }
            }
        }
        return solid.sorted()
    }
}
