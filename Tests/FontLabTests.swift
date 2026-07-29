import CoreText
import XCTest

/// The lab is only worth reading if its nine bands are genuinely nine fonts.
/// Two routes sharing a PostScript name would resolve to whichever registered
/// first, and every band would agree for the wrong reason.
final class FontLabTests: XCTestCase {
    private var templateData: Data!

    override func setUpWithError() throws {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: FontSetGenerator.templateResourceName, withExtension: "ttf"),
            "shaping template missing from the test bundle"
        )
        templateData = try Data(contentsOf: url)
    }

    func testEveryRouteHasItsOwnPostScriptName() {
        let names = FontLab.Route.allCases.map(\.postScriptName)
        XCTAssertEqual(Set(names).count, names.count, "routes share a PostScript name: \(names)")
    }

    func testLaunchArgumentsSwitchTheLab() {
        XCTAssertEqual(FontLab.launchOverride(in: ["app", "-MotionaryFontLabOn"]), true)
        XCTAssertEqual(FontLab.launchOverride(in: ["app", "-MotionaryFontLabOff"]), false)
        XCTAssertNil(FontLab.launchOverride(in: ["app"]))
    }

    func testEveryRouteIsLabelled() {
        for route in FontLab.Route.allCases {
            XCTAssertFalse(route.label.isEmpty)
            XCTAssertFalse(route.detail.isEmpty)
        }
    }

    func testRenamingProducesTheRoutesPostScriptName() throws {
        for route in FontLab.Route.allCases where route != .bundled {
            let renamed = try FontLab.rename(
                templateData,
                from: LaneFontBuilder.templateFamily,
                to: route.family
            )
            let name = try XCTUnwrap(
                NameTable.value(forNameID: 6, in: try SFNTFile(data: renamed).table("name")),
                "\(route.rawValue) lost its PostScript name record"
            )
            XCTAssertEqual(name, route.postScriptName)
        }
    }

    func testRenamedFontKeepsItsGlyphPayload() throws {
        let original = try SFNTFile(data: templateData)
        let renamed = try SFNTFile(data: FontLab.rename(
            templateData,
            from: LaneFontBuilder.templateFamily,
            to: FontLab.Route.groupProcess.family
        ))

        XCTAssertEqual(Set(original.tags), Set(renamed.tags))
        XCTAssertEqual(try original.table("SVG "), try renamed.table("SVG "))
        XCTAssertEqual(try original.table("GSUB"), try renamed.table("GSUB"))
    }

    /// The one route that needs no registry at all: if CoreText will build a
    /// font from the bytes in memory, the lab has something to draw with even
    /// when every registration route is refused.
    func testDataAloneYieldsAUsableFont() throws {
        let renamed = try FontLab.rename(
            templateData,
            from: LaneFontBuilder.templateFamily,
            to: FontLab.Route.direct.family
        )
        let descriptor = try XCTUnwrap(
            CTFontManagerCreateFontDescriptorFromData(renamed as CFData),
            "CoreText would not make a descriptor from the renamed font"
        )
        let font = CTFontCreateWithFontDescriptor(descriptor, 64, nil)
        XCTAssertEqual(CTFontCopyPostScriptName(font) as String, FontLab.Route.direct.postScriptName)
    }
}
