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
    /// Every period has to divide sixty, because the substitution keys on the
    /// timer's two seconds digits and those wrap there.
    ///
    /// It used to have to divide *ten*. The generator patched one shared
    /// ligature set - all six coverage entries, one per tens digit, pointed at
    /// it - so the pattern could only depend on the ones digit, and asking for
    /// thirty wrote the shared bytes six times over and produced a mask solid
    /// on nothing: a black widget with every report saying ok. The generator
    /// now builds six sets rather than patching one, so the tens digit can
    /// matter, which is what a thirty-second loop needs.
    func testEveryPeriodDividesSixty() {
        for period in FontSetGenerator.blinkPeriods {
            XCTAssertEqual(60 % period.seconds, 0, "\(period.resource) does not divide sixty")
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
        XCTAssertEqual(FontSetGenerator.blinkPeriod(covering: 0.3).seconds, 2)
        XCTAssertEqual(FontSetGenerator.blinkPeriod(covering: 2).seconds, 2)
        XCTAssertEqual(FontSetGenerator.blinkPeriod(covering: 2.1).seconds, 5)
        XCTAssertEqual(FontSetGenerator.blinkPeriod(covering: 9.5).seconds, 10)
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
        XCTAssertEqual(short.period, 2)
        XCTAssertEqual(short.framesPerSecond, spec.framesPerSecond, "two seconds fit at the authored rate")
        XCTAssertEqual(short.frames, 2 * spec.framesPerSecond)

        let long = FrameSetGenerator.plan(for: spec, clipSeconds: 9)
        XCTAssertEqual(long.period, 10, "a nine-second clip gets a nine-second loop, not a cut one")
        XCTAssertEqual(long.frames, long.period * long.framesPerSecond)
    }

    /// Length is paid for in smoothness, and the budget is on lanes.
    ///
    /// Every lane is a full-screen picture that the render server has to
    /// rasterise whether the mask lets it through or not, so `period x fps`
    /// is the number that has to stay bounded. It cannot be bought back by
    /// shortening the clip - that is the one thing a design cannot survive -
    /// so the frame rate gives way instead.
    func testALongClipPaysInFrameRateRatherThanLength() {
        let spec = TimerFontSpec(smoothness: .standard)   // 64 lanes, 32fps
        for seconds in [0.3, 2.0, 5.0, 9.5, 30.0] {
            let plan = FrameSetGenerator.plan(for: spec, clipSeconds: seconds)
            XCTAssertEqual(plan.frames, plan.period * plan.framesPerSecond)
            XCTAssertLessThanOrEqual(
                plan.frames, FrameSetGenerator.provenLaneCount,
                "\(seconds)s asked for \(plan.frames) lanes"
            )
            XCTAssertGreaterThanOrEqual(plan.framesPerSecond, 1)
            XCTAssertLessThanOrEqual(plan.framesPerSecond, spec.framesPerSecond)
        }

        // A clip does not lose its frame rate for being long: ten seconds runs
        // at the same rate two seconds does, and pays in resolution instead.
        XCTAssertEqual(FrameSetGenerator.plan(for: spec, clipSeconds: 2).framesPerSecond, 32)
        XCTAssertEqual(FrameSetGenerator.plan(for: spec, clipSeconds: 10).framesPerSecond, 32)
    }

    /// Both ceilings are measured, and getting them wrong puts a black widget
    /// on a Home Screen with every report still saying ok, so they are pinned.
    func testTheCeilingsAreWhatWasMeasured() {
        XCTAssertEqual(FrameSetGenerator.provenLoopSeconds, 10)
        XCTAssertEqual(FrameSetGenerator.provenLaneCount, 320)
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

        // The two-second mask is the shipped one, which the font engine uses
        // too - a design on it must not be sent looking for a file that is not
        // there.
        manifest.maskPeriod = 2
        XCTAssertEqual(manifest.maskFontResource, FontSetGenerator.blinkFontResourceName)
    }
}
