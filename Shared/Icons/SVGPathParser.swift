import CoreGraphics
import Foundation

enum SVGPathError: Error, CustomStringConvertible {
    case unexpectedCommand(Character, atOffset: Int)
    case missingOperands(command: Character, needed: Int, found: Int)
    case malformedNumber(String, atOffset: Int)

    var description: String {
        switch self {
        case .unexpectedCommand(let character, let offset):
            "svg path: unexpected command '\(character)' at offset \(offset)"
        case .missingOperands(let command, let needed, let found):
            "svg path: command '\(command)' needs \(needed) operands but found \(found)"
        case .malformedNumber(let text, let offset):
            "svg path: could not read a number from \"\(text)\" at offset \(offset)"
        }
    }
}

/// Turns an SVG `d` attribute into a `CGPath`.
///
/// iOS has no public SVG rasteriser, and the icons this app fetches are
/// path-based, so parsing them directly avoids both a dependency and a
/// WKWebView snapshot per icon.
enum SVGPathParser {
    static func path(from d: String) throws -> CGPath {
        let path = CGMutablePath()
        var scanner = NumberScanner(d)

        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        // Reflection points for the smooth curve commands.
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?
        var command: Character?

        while true {
            scanner.skipSeparators()
            guard !scanner.isAtEnd else { break }

            if let next = scanner.peekCommand() {
                command = next
                scanner.advance()
            } else if command == nil {
                throw SVGPathError.unexpectedCommand(scanner.peekCharacter() ?? " ", atOffset: scanner.offset)
            } else if command == "M" {
                // Extra coordinate pairs after a moveto are implicit linetos.
                command = "L"
            } else if command == "m" {
                command = "l"
            }

            guard let active = command else { break }
            let relative = active.isLowercase
            let op = Character(active.uppercased())

            func operands(_ count: Int) throws -> [CGFloat] {
                var values: [CGFloat] = []
                for _ in 0 ..< count {
                    guard let value = try scanner.nextNumber() else {
                        throw SVGPathError.missingOperands(command: active, needed: count, found: values.count)
                    }
                    values.append(value)
                }
                return values
            }

            func absolute(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }

            switch op {
            case "M":
                let v = try operands(2)
                current = absolute(v[0], v[1])
                subpathStart = current
                path.move(to: current)
                lastCubicControl = nil; lastQuadControl = nil

            case "L":
                let v = try operands(2)
                current = absolute(v[0], v[1])
                path.addLine(to: current)
                lastCubicControl = nil; lastQuadControl = nil

            case "H":
                let v = try operands(1)
                current = CGPoint(x: relative ? current.x + v[0] : v[0], y: current.y)
                path.addLine(to: current)
                lastCubicControl = nil; lastQuadControl = nil

            case "V":
                let v = try operands(1)
                current = CGPoint(x: current.x, y: relative ? current.y + v[0] : v[0])
                path.addLine(to: current)
                lastCubicControl = nil; lastQuadControl = nil

            case "C":
                let v = try operands(6)
                let c1 = absolute(v[0], v[1])
                let c2 = absolute(v[2], v[3])
                current = absolute(v[4], v[5])
                path.addCurve(to: current, control1: c1, control2: c2)
                lastCubicControl = c2; lastQuadControl = nil

            case "S":
                let v = try operands(4)
                // The first control point mirrors the previous one; with no
                // previous curve it coincides with the current point.
                let c1 = reflect(lastCubicControl, around: current)
                let c2 = absolute(v[0], v[1])
                current = absolute(v[2], v[3])
                path.addCurve(to: current, control1: c1, control2: c2)
                lastCubicControl = c2; lastQuadControl = nil

            case "Q":
                let v = try operands(4)
                let c = absolute(v[0], v[1])
                current = absolute(v[2], v[3])
                path.addQuadCurve(to: current, control: c)
                lastQuadControl = c; lastCubicControl = nil

            case "T":
                let v = try operands(2)
                let c = reflect(lastQuadControl, around: current)
                current = absolute(v[0], v[1])
                path.addQuadCurve(to: current, control: c)
                lastQuadControl = c; lastCubicControl = nil

            case "A":
                let v = try operands(7)
                let end = absolute(v[5], v[6])
                appendArc(
                    to: path,
                    from: current,
                    to: end,
                    radii: CGSize(width: abs(v[0]), height: abs(v[1])),
                    rotationDegrees: v[2],
                    largeArc: v[3] != 0,
                    sweep: v[4] != 0
                )
                current = end
                lastCubicControl = nil; lastQuadControl = nil

            case "Z":
                path.closeSubpath()
                current = subpathStart
                lastCubicControl = nil; lastQuadControl = nil

            default:
                throw SVGPathError.unexpectedCommand(active, atOffset: scanner.offset)
            }
        }

        return path
    }

    private static func reflect(_ control: CGPoint?, around point: CGPoint) -> CGPoint {
        guard let control else { return point }
        return CGPoint(x: 2 * point.x - control.x, y: 2 * point.y - control.y)
    }

    /// Endpoint-to-centre conversion from the SVG implementation notes, then
    /// emitted as an arc on a transformed unit circle.
    private static func appendArc(
        to path: CGMutablePath,
        from start: CGPoint,
        to end: CGPoint,
        radii: CGSize,
        rotationDegrees: CGFloat,
        largeArc: Bool,
        sweep: Bool
    ) {
        guard radii.width > 0, radii.height > 0 else {
            path.addLine(to: end)
            return
        }
        if start == end { return }

        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)

        let dx2 = (start.x - end.x) / 2, dy2 = (start.y - end.y) / 2
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2

        var rx = radii.width, ry = radii.height
        // Radii too small to span the endpoints are scaled up, per the spec.
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            rx *= sqrt(lambda)
            ry *= sqrt(lambda)
        }

        let numerator = max(0, rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p)
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coefficient = denominator == 0 ? 0 : sqrt(numerator / denominator)
        if largeArc == sweep { coefficient = -coefficient }

        let cxp = coefficient * rx * y1p / ry
        let cyp = -coefficient * ry * x1p / rx
        let center = CGPoint(
            x: cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2,
            y: sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2
        )

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            guard len > 0 else { return 0 }
            let value = acos(min(1, max(-1, dot / len)))
            return (ux * vy - uy * vx) < 0 ? -value : value
        }

        let startAngle = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        // CGPath has no elliptical arc, so draw on a unit circle and let the
        // transform apply the radii and rotation.
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: phi)
            .scaledBy(x: rx, y: ry)
        path.addArc(
            center: .zero,
            radius: 1,
            startAngle: startAngle,
            endAngle: startAngle + delta,
            clockwise: delta < 0,
            transform: transform
        )
    }
}

/// Scans SVG's compact number syntax, where separators are optional and a sign
/// or second decimal point can start the next number ("1.5.5" is 1.5 then 0.5).
struct NumberScanner {
    private let characters: [Character]
    private(set) var offset = 0

    init(_ text: String) {
        characters = Array(text)
    }

    var isAtEnd: Bool { offset >= characters.count }

    func peekCharacter() -> Character? {
        offset < characters.count ? characters[offset] : nil
    }

    func peekCommand() -> Character? {
        guard let character = peekCharacter(), character.isLetter, character != "e", character != "E" else {
            return nil
        }
        return character
    }

    mutating func advance() { offset += 1 }

    mutating func skipSeparators() {
        while offset < characters.count, characters[offset] == " " || characters[offset] == ","
            || characters[offset] == "\n" || characters[offset] == "\t" || characters[offset] == "\r" {
            offset += 1
        }
    }

    mutating func nextNumber() throws -> CGFloat? {
        skipSeparators()
        guard offset < characters.count else { return nil }

        let start = offset
        var seenDot = false
        var seenDigit = false

        if characters[offset] == "+" || characters[offset] == "-" { offset += 1 }
        while offset < characters.count {
            let character = characters[offset]
            if character.isNumber {
                seenDigit = true
                offset += 1
            } else if character == ".", !seenDot {
                seenDot = true
                offset += 1
            } else if (character == "e" || character == "E"), seenDigit,
                      offset + 1 < characters.count,
                      characters[offset + 1].isNumber || characters[offset + 1] == "-" || characters[offset + 1] == "+" {
                offset += 2
                while offset < characters.count, characters[offset].isNumber { offset += 1 }
                break
            } else {
                break
            }
        }

        guard seenDigit else {
            offset = start
            return nil
        }
        let text = String(characters[start ..< offset])
        guard let value = Double(text) else {
            throw SVGPathError.malformedNumber(text, atOffset: start)
        }
        return CGFloat(value)
    }
}
