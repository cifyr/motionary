import CoreGraphics
import Foundation
import os

enum SVGRenderError: Error, CustomStringConvertible {
    case malformedBody(underlying: Error?)
    case noDrawableShapes(elements: [String])
    case contextCreationFailed(size: CGSize)
    case renderProducedNothing

    var description: String {
        switch self {
        case .malformedBody(let underlying):
            "icon: could not parse the SVG body: \(underlying.map(String.init(describing:)) ?? "unknown error")"
        case .noDrawableShapes(let elements):
            "icon: body contained no shapes this renderer draws (saw \(elements.joined(separator: ", ")))"
        case .contextCreationFailed(let size):
            "icon: could not create a \(Int(size.width))x\(Int(size.height)) bitmap"
        case .renderProducedNothing:
            "icon: rasterising produced no image"
        }
    }
}

/// Rasterises an Iconify icon body.
///
/// Bodies are a fragment rather than a whole document: a handful of shapes,
/// often wrapped in a `<g>` carrying the fill and stroke. `currentColor`
/// resolves to the requested tint; explicit colours are kept so multi-colour
/// sets still look right.
struct SVGIconRenderer {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "IconRender")

    struct Style {
        var fill: CGColor?
        var stroke: CGColor?
        var strokeWidth: CGFloat = 1
        var lineCap: CGLineCap = .butt
        var lineJoin: CGLineJoin = .miter
        var usesEvenOddFill = false
        var opacity: CGFloat = 1
    }

    struct Shape {
        let path: CGPath
        let style: Style
    }

    let viewBox: CGRect
    let tint: CGColor

    /// Renders into a square of `side` points, letterboxing a non-square
    /// viewBox so the icon keeps its proportions.
    func image(body: String, side: CGFloat) throws -> CGImage {
        let shapes = try Self.shapes(in: body, tint: tint)
        guard !shapes.isEmpty else {
            throw SVGRenderError.noDrawableShapes(elements: Self.elementNames(in: body))
        }

        let pixels = Int(side.rounded())
        guard let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw SVGRenderError.contextCreationFailed(size: CGSize(width: side, height: side))
        }

        context.setAllowsAntialiasing(true)
        context.interpolationQuality = .high

        // SVG's y axis points down; CoreGraphics' points up.
        let scale = min(side / viewBox.width, side / viewBox.height)
        let drawn = CGSize(width: viewBox.width * scale, height: viewBox.height * scale)
        context.translateBy(x: (side - drawn.width) / 2, y: side - (side - drawn.height) / 2)
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -viewBox.minX, y: -viewBox.minY)

        for shape in shapes {
            context.saveGState()
            context.setAlpha(shape.style.opacity)
            if let fill = shape.style.fill {
                context.addPath(shape.path)
                context.setFillColor(fill)
                context.fillPath(using: shape.style.usesEvenOddFill ? .evenOdd : .winding)
            }
            if let stroke = shape.style.stroke, shape.style.strokeWidth > 0 {
                context.addPath(shape.path)
                context.setStrokeColor(stroke)
                context.setLineWidth(shape.style.strokeWidth)
                context.setLineCap(shape.style.lineCap)
                context.setLineJoin(shape.style.lineJoin)
                context.strokePath()
            }
            context.restoreGState()
        }

        guard let image = context.makeImage() else { throw SVGRenderError.renderProducedNothing }
        return image
    }

    // MARK: - Parsing

    static func elementNames(in body: String) -> [String] {
        var names = Set<String>()
        var scanner = body[...]
        while let open = scanner.firstIndex(of: "<") {
            let rest = scanner[scanner.index(after: open)...]
            let name = rest.prefix { $0.isLetter }
            if !name.isEmpty { names.insert(String(name)) }
            scanner = rest
        }
        return names.sorted()
    }

    static func shapes(in body: String, tint: CGColor) throws -> [Shape] {
        // Bodies are fragments, so wrap them to make a well-formed document.
        let document = "<svg>\(body)</svg>"
        let delegate = ShapeCollector(tint: tint)
        let parser = XMLParser(data: Data(document.utf8))
        parser.delegate = delegate
        guard parser.parse() else {
            throw SVGRenderError.malformedBody(underlying: parser.parserError)
        }
        return delegate.shapes
    }

    private final class ShapeCollector: NSObject, XMLParserDelegate {
        private(set) var shapes: [Shape] = []
        private var styleStack: [Style]
        private var transformStack: [CGAffineTransform] = [.identity]
        private let tint: CGColor

        init(tint: CGColor) {
            self.tint = tint
            // SVG's initial fill is black; Iconify bodies normally override it.
            styleStack = [Style(fill: tint, stroke: nil)]
            super.init()
        }

        func parser(
            _ parser: XMLParser,
            didStartElement element: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            let style = resolve(attributes: attributes, inheriting: styleStack.last ?? Style())
            let transform = (transformStack.last ?? .identity)
                .concatenating(Self.transform(from: attributes["transform"]))
            styleStack.append(style)
            transformStack.append(transform)

            guard let path = Self.path(for: element, attributes: attributes) else { return }
            var applied = transform
            let transformed = path.copy(using: &applied) ?? path
            shapes.append(Shape(path: transformed, style: style))
        }

        func parser(
            _ parser: XMLParser,
            didEndElement element: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            if styleStack.count > 1 { styleStack.removeLast() }
            if transformStack.count > 1 { transformStack.removeLast() }
        }

        private func resolve(attributes: [String: String], inheriting parent: Style) -> Style {
            var style = parent
            if let fill = attributes["fill"] { style.fill = Self.color(fill, tint: tint) }
            if let stroke = attributes["stroke"] { style.stroke = Self.color(stroke, tint: tint) }
            if let width = attributes["stroke-width"].flatMap(Double.init) { style.strokeWidth = CGFloat(width) }
            if let opacity = attributes["opacity"].flatMap(Double.init) { style.opacity = CGFloat(opacity) }
            if let rule = attributes["fill-rule"] { style.usesEvenOddFill = rule == "evenodd" }
            if let cap = attributes["stroke-linecap"] {
                style.lineCap = cap == "round" ? .round : (cap == "square" ? .square : .butt)
            }
            if let join = attributes["stroke-linejoin"] {
                style.lineJoin = join == "round" ? .round : (join == "bevel" ? .bevel : .miter)
            }
            // A stroked shape with no explicit fill must not inherit one, or
            // outline icon sets come out as solid blobs.
            if attributes["stroke"] != nil, attributes["fill"] == nil, parent.fill != nil, parent.stroke == nil {
                style.fill = nil
            }
            return style
        }

        private static func color(_ value: String, tint: CGColor) -> CGColor? {
            let trimmed = value.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed == "none" || trimmed == "transparent" { return nil }
            if trimmed == "currentcolor" { return tint }
            if trimmed.hasPrefix("#") { return hexColor(trimmed) }
            return namedColors[trimmed] ?? tint
        }

        private static func hexColor(_ value: String) -> CGColor? {
            var hex = String(value.dropFirst())
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6 || hex.count == 8, let number = UInt32(hex, radix: 16) else { return nil }
            let hasAlpha = hex.count == 8
            let r = CGFloat((number >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
            let g = CGFloat((number >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
            let b = CGFloat((number >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
            let a = hasAlpha ? CGFloat(number & 0xFF) / 255 : 1
            return CGColor(red: r, green: g, blue: b, alpha: a)
        }

        private static let namedColors: [String: CGColor] = [
            "black": CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            "white": CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            "red": CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            "green": CGColor(red: 0, green: 0.5, blue: 0, alpha: 1),
            "blue": CGColor(red: 0, green: 0, blue: 1, alpha: 1),
        ]

        private static func transform(from value: String?) -> CGAffineTransform {
            guard let value else { return .identity }
            var result = CGAffineTransform.identity
            // Only the forms Iconify actually emits; anything else is ignored
            // rather than silently mis-drawn.
            for (function, arguments) in functionCalls(in: value) {
                let numbers = arguments.split(whereSeparator: { $0 == " " || $0 == "," })
                    .compactMap { Double($0) }
                    .map { CGFloat($0) }
                switch function.lowercased() {
                case "translate" where numbers.count >= 1:
                    result = result.translatedBy(x: numbers[0], y: numbers.count > 1 ? numbers[1] : 0)
                case "scale" where numbers.count >= 1:
                    result = result.scaledBy(x: numbers[0], y: numbers.count > 1 ? numbers[1] : numbers[0])
                case "rotate" where numbers.count >= 1:
                    result = result.rotated(by: numbers[0] * .pi / 180)
                case "matrix" where numbers.count == 6:
                    result = result.concatenating(CGAffineTransform(
                        a: numbers[0], b: numbers[1], c: numbers[2],
                        d: numbers[3], tx: numbers[4], ty: numbers[5]
                    ))
                default:
                    continue
                }
            }
            return result
        }

        /// Splits `translate(4 2) scale(0.5)` into its name/argument pairs.
        private static func functionCalls(in value: String) -> [(String, Substring)] {
            var calls: [(String, Substring)] = []
            var rest = value[...]
            while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
                let name = rest[rest.startIndex ..< open]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let arguments = rest[rest.index(after: open) ..< close]
                if !name.isEmpty { calls.append((name, arguments)) }
                rest = rest[rest.index(after: close)...]
            }
            return calls
        }

        private static func path(for element: String, attributes: [String: String]) -> CGPath? {
            func number(_ key: String, default fallback: CGFloat = 0) -> CGFloat {
                guard let text = attributes[key], let value = Double(text) else { return fallback }
                return CGFloat(value)
            }

            switch element {
            case "path":
                guard let d = attributes["d"] else { return nil }
                return try? SVGPathParser.path(from: d)
            case "circle":
                let r = number("r")
                guard r > 0 else { return nil }
                return CGPath(ellipseIn: CGRect(
                    x: number("cx") - r, y: number("cy") - r, width: r * 2, height: r * 2
                ), transform: nil)
            case "ellipse":
                let rx = number("rx"), ry = number("ry")
                guard rx > 0, ry > 0 else { return nil }
                return CGPath(ellipseIn: CGRect(
                    x: number("cx") - rx, y: number("cy") - ry, width: rx * 2, height: ry * 2
                ), transform: nil)
            case "rect":
                let rect = CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height"))
                guard rect.width > 0, rect.height > 0 else { return nil }
                let rx = number("rx"), ry = number("ry", default: number("rx"))
                return rx > 0 || ry > 0
                    ? CGPath(roundedRect: rect, cornerWidth: rx, cornerHeight: ry == 0 ? rx : ry, transform: nil)
                    : CGPath(rect: rect, transform: nil)
            case "line":
                let path = CGMutablePath()
                path.move(to: CGPoint(x: number("x1"), y: number("y1")))
                path.addLine(to: CGPoint(x: number("x2"), y: number("y2")))
                return path
            case "polygon", "polyline":
                guard let points = attributes["points"] else { return nil }
                let values = points.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" })
                    .compactMap { Double($0) }
                    .map { CGFloat($0) }
                guard values.count >= 4 else { return nil }
                let path = CGMutablePath()
                path.move(to: CGPoint(x: values[0], y: values[1]))
                for index in stride(from: 2, to: values.count - 1, by: 2) {
                    path.addLine(to: CGPoint(x: values[index], y: values[index + 1]))
                }
                if element == "polygon" { path.closeSubpath() }
                return path
            default:
                return nil
            }
        }
    }
}
