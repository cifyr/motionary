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

    /// Reference date for the timer text, anchored to a whole cycle.
    ///
    /// The ligature table keys on the timer's seconds field, mapping `s` and
    /// `s + 30` to the same glyph, so the picture repeats every 30 seconds.
    /// Anchoring to a multiple of that period does two things: the visible
    /// frame becomes a pure function of wall-clock time, so the app can work
    /// out what the widget is showing without being told; and the anchor can
    /// advance a whole cycle without the picture moving.
    ///
    /// The 60-second lead keeps the elapsed value inside a stable `M:SS`
    /// format. A far-past anchor would widen the string and shift which glyph
    /// lands in the visible slot.
    static func cycleAlignedReference(at date: Date = Date()) -> Date {
        let seconds = date.timeIntervalSince1970
        let aligned = (seconds / cycleDuration).rounded(.down) * cycleDuration
        return Date(timeIntervalSince1970: aligned - 60)
    }

    /// Which frame of the cycle the widget intends to be showing.
    func globalFrame(at date: Date = Date()) -> Int {
        let phase = date.timeIntervalSince1970.truncatingRemainder(dividingBy: Self.cycleDuration)
        return frame(at: phase < 0 ? phase + Self.cycleDuration : phase)
    }

    /// Where to start the app's preview video so it continues from whatever the
    /// widget was showing, in seconds into the loop.
    func videoTime(at date: Date = Date(), loopFrameCount: Int) -> TimeInterval {
        guard loopFrameCount > 0 else { return 0 }
        let index = globalFrame(at: date) % loopFrameCount
        return Double(index) / Double(framesPerSecond)
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
