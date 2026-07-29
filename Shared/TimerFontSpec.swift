import Foundation

/// How many lane fonts a design uses, and therefore how smooth it looks and how
/// much disk it costs.
///
/// The template supplies 15 animation glyphs, and the timer cycle is fixed at
/// `lanes x 15` selections. Halving the lanes halves both the payload and the
/// requested frame rate while keeping the 30-second wrap intact.
enum MotionSmoothness: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard
    case balanced
    case light

    var id: String { rawValue }

    var laneCount: Int {
        switch self {
        case .standard: 64
        case .balanced: 48
        case .light: 32
        }
    }

    var framesPerSecond: Int { laneCount / 2 }

    var title: String {
        switch self {
        case .standard: "Smooth"
        case .balanced: "Balanced"
        case .light: "Light"
        }
    }

    var subtitle: String {
        "\(framesPerSecond) fps · \(laneCount) fonts"
    }
}

/// Frame math shared by the generator, the widget renderer, and the tests.
struct TimerFontSpec: Equatable, Sendable {
    /// Fixed by the shaping template's animation glyph count.
    static let framesPerLane = 15
    /// The wrap period the blink mask is built around.
    static let cycleDuration: TimeInterval = 30

    let laneCount: Int
    let framesPerSecond: Int

    var framesPerLane: Int { Self.framesPerLane }
    var totalFrames: Int { laneCount * Self.framesPerLane }
    var loopDuration: TimeInterval { Double(totalFrames) / Double(framesPerSecond) }

    init(smoothness: MotionSmoothness) {
        laneCount = smoothness.laneCount
        framesPerSecond = smoothness.framesPerSecond
    }

    init(laneCount: Int, framesPerSecond: Int) {
        self.laneCount = laneCount
        self.framesPerSecond = framesPerSecond
    }

    func globalFrame(lane: Int, glyphSequence: Int) -> Int {
        glyphSequence * laneCount + lane
    }

    func frame(at elapsedTime: TimeInterval) -> Int {
        let raw = Int(floor(elapsedTime * Double(framesPerSecond)))
        return ((raw % totalFrames) + totalFrames) % totalFrames
    }

    /// A visual loop only reads as seamless if it divides the timer cycle
    /// evenly; otherwise the wrap introduces a second, arbitrary cut.
    func divides(loopFrameCount: Int) -> Bool {
        loopFrameCount > 0 && totalFrames % loopFrameCount == 0
    }

    /// Loop lengths that tile the cycle cleanly, for the trim UI to snap to.
    func seamlessLoopLengths(maximum: Int) -> [Int] {
        (1 ... max(1, maximum)).filter { totalFrames % $0 == 0 }
    }
}
