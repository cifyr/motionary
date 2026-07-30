import CoreText
import UIKit
import XCTest

/// Does a generated lane font actually put pixels on a canvas?
///
/// Until now the only way to answer that was to look at a phone, which is a
/// slow way to discover that a probe was wrong - and twice the probe was what
/// was wrong. CoreText will rasterise these colour glyphs in any process, so
/// the font can be checked here in a second.
///
/// Note what this does *not* cover: SwiftUI draws nothing at all for these
/// fonts outside a widget, in `ImageRenderer` and on screen alike. So a green
/// run here means the font is sound, not that the widget will show it. Only a
/// rendered widget answers that.
final class GlyphRenderingTests: XCTestCase {
    private var laneFontName: String!

    override func setUpWithError() throws {
        let bundle = Bundle(for: Self.self)
        let fonts = bundle.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        // Skipped, not failed, when no design has been built. Lane fonts are
        // build output and are not committed, so a fresh clone has none and a new
        // contributor's first test run would otherwise open on three red tests
        // that say nothing about their checkout.
        guard let lane = fonts.first(where: {
            $0.lastPathComponent.hasPrefix("MFont") && $0.lastPathComponent.contains("L0-")
        }) else {
            throw XCTSkip("no lane font is bundled; build a design in Motionary Studio to cover this")
        }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(lane as CFURL, .process, &error) {
            let failure = error?.takeRetainedValue()
            let code = (failure as Error?).map { ($0 as NSError).code } ?? -1
            XCTAssertEqual(
                code,
                Int(CTFontManagerError.alreadyRegistered.rawValue),
                "could not register \(lane.lastPathComponent): \(String(describing: failure))"
            )
        }
        laneFontName = lane.deletingPathExtension().lastPathComponent
    }

    private func litPixels(side: Int = 400, _ draw: (CGContext) -> Void) throws -> Int {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        draw(context)
        return stride(from: 0, to: pixels.count, by: 4).count { pixels[$0 + 3] > 16 }
    }

    private func line(_ string: String, _ font: CTFont) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font]))
    }

    func testLaneFontResolvesByPostScriptName() {
        XCTAssertEqual(
            CTFontCopyPostScriptName(CTFontCreateWithName(laneFontName as CFString, 12, nil)) as String,
            laneFontName
        )
    }

    /// Apple's colour emoji as the control: it isolates "this font's colour
    /// glyphs do not draw" from "colour glyphs do not draw in this context".
    func testColourGlyphsDrawAtAll() throws {
        let emoji = CTFontCreateWithName("AppleColorEmoji" as CFString, 200, nil)
        let drawn = try litPixels { context in
            context.textPosition = CGPoint(x: 10, y: 100)
            CTLineDraw(line("\u{1F600}", emoji), context)
        }
        XCTAssertGreaterThan(drawn, 1000, "colour glyphs do not rasterise here at all")
    }

    /// The ligature is what turns timer digits into a frame, so this covers the
    /// shaping and the SVG payload together: `10` has to become one animation
    /// glyph, and that glyph has to be a picture.
    func testTimerDigitsLigateIntoAPictureGlyph() throws {
        let font = CTFontCreateWithName(laneFontName as CFString, 400, nil)
        let ctLine = line("10:00", font)
        let runs = (CTLineGetGlyphRuns(ctLine) as? [CTRun]) ?? []
        var glyphs: [CGGlyph] = []
        for run in runs {
            var buffer = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &buffer)
            glyphs += buffer
        }
        XCTAssertLessThan(glyphs.count, 5, "\"10\" did not ligate into a single glyph: \(glyphs)")

        let svgGlyphs = try SVGTable.glyphIDs(in: try SFNTFile(
            data: Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: laneFontName, withExtension: "ttf")))
        ).table("SVG "))
        XCTAssertTrue(
            glyphs.contains { svgGlyphs.contains(UInt16($0)) },
            "none of \(glyphs) is one of the font's \(svgGlyphs.count) picture glyphs"
        )

        let drawn = try litPixels { context in
            context.textPosition = CGPoint(x: 0, y: 80)
            CTLineDraw(ctLine, context)
        }
        XCTAssertGreaterThan(drawn, 1000, "the animation glyph drew nothing")
    }
}
