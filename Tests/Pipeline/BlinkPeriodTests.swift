import XCTest

/// How long a picture-built design is allowed to be.
///
/// The mask that picks which lane is visible substitutes on the timer's seconds
/// digits, and the shipped one is solid on even seconds - so it repeats every
/// two, and that was the entire loop a delivered design could have. The longer
/// masks are the same font with the substitution rewritten. What is testable
/// here is the choice: which mask a clip gets, and how many pictures that
/// costs.
final class BlinkPeriodTests: XCTestCase {
    /// Every period has to divide 60, because the substitution keys on the
    /// seconds digits and they wrap there. A period that does not divide would
    /// put the solid second in a different place on each pass through the
    /// minute, which is a loop that never repeats the same way twice.
    func testEveryPeriodDividesTheMinute() {
        for period in FontSetGenerator.blinkPeriods {
            XCTAssertEqual(60 % period.seconds, 0, "\(period.resource) does not divide 60")
            XCTAssertGreaterThanOrEqual(period.seconds, 2)
        }
        XCTAssertEqual(
            FontSetGenerator.blinkPeriods.map(\.seconds).sorted(),
            FontSetGenerator.blinkPeriods.map(\.seconds),
            "the shortest that fits is chosen by scanning in order, so they have to be sorted"
        )
    }

    /// The shortest mask that covers the clip. Every second of period costs
    /// `framesPerSecond` more pictures whether the clip fills them or not,
    /// because the stack has to cover the whole cycle - a second nothing was
    /// drawn into is a second of black once per loop.
    func testAClipGetsTheShortestMaskThatCoversIt() {
        XCTAssertEqual(FontSetGenerator.blinkPeriod(covering: 0.3).seconds, 4)
        XCTAssertEqual(FontSetGenerator.blinkPeriod(covering: 4).seconds, 4)
        XCTAssertEqual(FontSetGenerator.blinkPeriod(covering: 4.1).seconds, 6)
        XCTAssertEqual(FontSetGenerator.blinkPeriod(covering: 9.5).seconds, 10)
        XCTAssertEqual(FontSetGenerator.blinkPeriod(covering: 25).seconds, 30)
    }

    /// A clip longer than the longest mask is not refused - it gets the longest
    /// one and plays its first thirty seconds, which is a design that works
    /// rather than a build that stops.
    func testAClipLongerThanTheLongestMaskGetsTheLongestMask() {
        let longest = FontSetGenerator.blinkPeriods.last!
        XCTAssertEqual(FontSetGenerator.blinkPeriod(covering: 120).seconds, longest.seconds)
        XCTAssertEqual(FontSetGenerator.blinkPeriod(covering: .infinity).resource, longest.resource)
    }

    /// The stack is the loop: one picture per mask phase, and the phases are
    /// the period's seconds times the frame rate.
    func testTheStackCoversTheWholeCycle() {
        let spec = TimerFontSpec(smoothness: .light)   // 32 lanes, 16fps
        let short = FrameSetGenerator.plan(for: spec, clipSeconds: 1)
        XCTAssertEqual(short.period, 4)
        XCTAssertEqual(short.frames, 4 * spec.framesPerSecond)

        let long = FrameSetGenerator.plan(for: spec, clipSeconds: 9)
        XCTAssertEqual(long.period, 10)
        XCTAssertEqual(long.frames, 10 * spec.framesPerSecond)
        XCTAssertGreaterThan(long.frames, short.frames)
    }

    /// A manifest from before longer masks existed has no period, and has to go
    /// on playing the two-second loop it was built for rather than being
    /// stretched across a mask it was never cut to.
    func testAManifestWithoutAPeriodKeepsTheOldLoop() {
        var manifest = BuildManifest(
            designID: UUID(),
            buildGeneration: 1,
            fontFamilyBase: "MFontTest",
            laneCount: 32,
            framesPerSecond: 16,
            loopFrameCount: 32,
            animationCrop: CGRect(x: 0, y: 0, width: 10, height: 10),
            widgetRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            screenSize: CGSize(width: 20, height: 40),
            wallpaperName: "wallpaper.png",
            totalFontBytes: 0,
            builtAt: Date()
        )
        manifest.frameCount = 32
        XCTAssertEqual(manifest.maskPeriodSeconds, 2)
        XCTAssertEqual(manifest.maskFontResource, FontSetGenerator.blinkFontResourceName)
        XCTAssertEqual(manifest.frameLaneCount, 32)

        manifest.maskPeriod = 10
        XCTAssertEqual(manifest.maskPeriodSeconds, 10)
        XCTAssertEqual(manifest.maskFontResource, "Blnk10-Regular")
        XCTAssertEqual(manifest.frameLaneCount, 160)
    }
}
