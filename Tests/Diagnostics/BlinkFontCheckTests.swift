import XCTest

/// Reads the shipped masks' own substitution tables and checks they say what
/// the generator claims. The masks are one file with sixty bytes changed, so
/// nothing about a wrong one looks wrong - it resolves, it draws, and the
/// widget is black because the groups gated to each second never come up.
final class BlinkFontCheckTests: XCTestCase {
    /// The GSUB table's bytes, sliced out of the font file the way
    /// `CTFontCopyTable` hands them over.
    private func gsub(of resource: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: resource, withExtension: "otf"))
        let data = try Data(contentsOf: url)
        let count = Int(data[4]) << 8 | Int(data[5])
        for i in 0 ..< count {
            let entry = 12 + i * 16
            guard data[entry ..< entry + 4].elementsEqual(Data("GSUB".utf8)) else { continue }
            let offset = data[(entry + 8) ..< (entry + 12)].reduce(0) { $0 << 8 | Int($1) }
            let length = data[(entry + 12) ..< (entry + 16)].reduce(0) { $0 << 8 | Int($1) }
            return data.subdata(in: offset ..< (offset + length))
        }
        throw XCTSkip("no GSUB in \(resource)")
    }

    func testEveryShippedMaskIsSolidOnItsOwnPeriod() throws {
        for period in FontSetGenerator.blinkPeriods {
            let solid = BlinkFontCheck.solidSeconds(in: try gsub(of: period.resource))
            let expected = stride(from: 0, to: 60, by: period.seconds).map { $0 }
            XCTAssertEqual(
                solid, expected,
                "\(period.resource) is solid on \(solid), not every \(period.seconds)s"
            )
        }
    }

    /// The original mask, which the font engine still uses: solid on every even
    /// second, which is the two-second loop everything started from.
    func testTheShippedMaskIsSolidOnEverySecondSecond() throws {
        let solid = BlinkFontCheck.solidSeconds(in: try gsub(of: FontSetGenerator.blinkFontResourceName))
        XCTAssertEqual(solid, stride(from: 0, to: 60, by: 2).map { $0 })
    }
}
