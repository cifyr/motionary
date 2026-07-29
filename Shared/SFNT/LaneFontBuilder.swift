import CoreGraphics
import Foundation

enum LaneFontError: Error, CustomStringConvertible {
    case glyphCountMismatch(templateGlyphs: Int, expected: Int)
    case noFrames

    var description: String {
        switch self {
        case .glyphCountMismatch(let templateGlyphs, let expected):
            "lane font: template exposes \(templateGlyphs) animation glyphs but the spec expects \(expected)"
        case .noFrames:
            "lane font: no encoded frames were supplied"
        }
    }
}

/// Builds the SVG glyph payload for one lane font.
///
/// Layout matches the reference fonts exactly: a 500-unit square canvas, the
/// frame placed as a single `<image>` at the crop's proportional position, and
/// the whole group shifted up one canvas so it lands on the glyph's em box.
struct SVGGlyphFactory {
    static let canvasSize: CGFloat = 500

    let cropRect: CGRect
    let screenSize: CGSize

    func document(glyphID: UInt16, jpegBase64: String) -> String {
        let x = cropRect.minX / screenSize.width * Self.canvasSize
        let y = cropRect.minY / screenSize.height * Self.canvasSize
        let width = cropRect.width / screenSize.width * Self.canvasSize
        let height = cropRect.height / screenSize.height * Self.canvasSize

        return """
        <svg xmlns="http://www.w3.org/2000/svg" \
        xmlns:xlink="http://www.w3.org/1999/xlink" \
        width="\(Int(Self.canvasSize))" height="\(Int(Self.canvasSize))" \
        id="glyph\(glyphID)">\
        <g transform="translate(0 -\(Int(Self.canvasSize)))">\
        <image x="\(format(x))" y="\(format(y))" \
        width="\(format(width))" height="\(format(height))" \
        preserveAspectRatio="none" \
        xlink:href="data:image/jpeg;base64,\(jpegBase64)"/>\
        </g>\
        </svg>
        """
    }

    private func format(_ value: CGFloat) -> String {
        String(format: "%.3f", value)
    }
}

/// Turns the shaping template into the numbered lane fonts the widget renders.
struct LaneFontBuilder {
    static let templateFamily = "CatFont0"

    let templateData: Data
    let spec: TimerFontSpec
    let factory: SVGGlyphFactory

    private let template: SFNTFile
    private let glyphIDs: [UInt16]

    init(templateData: Data, spec: TimerFontSpec, factory: SVGGlyphFactory) throws {
        self.templateData = templateData
        self.spec = spec
        self.factory = factory
        template = try SFNTFile(data: templateData)
        glyphIDs = try SVGTable.glyphIDs(in: template.table("SVG "))

        guard glyphIDs.count == spec.framesPerLane else {
            throw LaneFontError.glyphCountMismatch(
                templateGlyphs: glyphIDs.count,
                expected: spec.framesPerLane
            )
        }
    }

    /// `encodedFrames` holds every unique frame of the visual loop, base64'd.
    /// A lane samples them with a stride so consecutive lanes show consecutive
    /// frames, which is what makes the blink mask read as motion.
    ///
    /// `familyBase` is the design's family prefix; the lane index is appended
    /// here rather than by the caller, because all 64 fonts register into one
    /// process and a duplicated PostScript name silently resolves to whichever
    /// lane was registered first.
    func font(lane: Int, familyBase: String, encodedFrames: [String]) throws -> Data {
        guard !encodedFrames.isEmpty else { throw LaneFontError.noFrames }

        let documents = try glyphIDs.enumerated().map { sequence, glyphID -> SVGGlyphDocument in
            let globalFrame = spec.globalFrame(lane: lane, glyphSequence: sequence)
            let source = factory.document(
                glyphID: glyphID,
                jpegBase64: encodedFrames[globalFrame % encodedFrames.count]
            )
            return SVGGlyphDocument(
                glyphID: glyphID,
                compressed: try Gzip.compress(Data(source.utf8))
            )
        }

        var font = template
        font.setTable("SVG ", to: SVGTable.build(documents: documents))
        font.setTable("name", to: try NameTable.replacingFamily(
            in: template.table("name"),
            from: Self.templateFamily,
            to: "\(familyBase)\(lane)"
        ))
        return try font.serialized()
    }

    static func postScriptName(family: String, lane: Int) -> String {
        "\(family)\(lane)-Regular"
    }
}
