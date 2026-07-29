import UIKit
import XCTest

/// The slot arithmetic, checked against a model of what the bundled blink font
/// does, so the widget only has to answer the question the model cannot: does
/// the system re-render the mask often enough for the slots to be visible.
final class ImageLayerLabTests: XCTestCase {
    /// Matches what the widget uses, and is 2-second aligned because 30 is.
    private let reference = TimerFontSpec.cycleAlignedReference(
        at: Date(timeIntervalSince1970: 1_800_000_000)
    )

    private func date(offsetIntoCycle phase: TimeInterval) -> Date {
        // Somewhere inside the reference's own cycle, so the elapsed time stays
        // in the M:SS shape the ligature table is built around.
        Date(timeIntervalSince1970: 1_800_000_000 + phase)
    }

    func testASinglePulseIsOpaqueForOneSecondInTwo() {
        for step in 0 ..< 40 {
            let phase = Double(step) / 20
            let opaque = ImageLayerLab.pulseIsOpaque(
                offset: 0,
                at: date(offsetIntoCycle: phase),
                reference: reference
            )
            XCTAssertEqual(opaque, phase < 1, "phase \(phase)")
        }
    }

    func testAnOffsetPulseMovesItsEdges() {
        let offset = 0.5
        for step in 0 ..< 40 {
            let phase = Double(step) / 20
            let opaque = ImageLayerLab.pulseIsOpaque(
                offset: offset,
                at: date(offsetIntoCycle: phase),
                reference: reference
            )
            XCTAssertEqual(opaque, phase >= 0.5 && phase < 1.5, "phase \(phase)")
        }
    }

    /// The whole mechanism in one assertion: at every instant of the cycle
    /// exactly one frame is showing, and it is the frame whose slot the instant
    /// falls in.
    func testEverySlotOwnsExactlyItsShareOfTheCycle() {
        for count in [2, 4, 8, 16, 32, 64] {
            let width = ImageLayerLab.slotWidth(count: count)
            // Sampled off the boundaries: a sample landing exactly on an edge
            // is a question about floating point, not about the mask.
            for slot in 0 ..< count {
                for fraction in [0.1, 0.5, 0.9] {
                    let phase = ImageLayerLab.slotStart(index: slot, count: count) + width * fraction
                    let opaque = ImageLayerLab.opaqueSlots(
                        count: count,
                        at: date(offsetIntoCycle: phase),
                        reference: reference
                    )
                    XCTAssertEqual(opaque, [slot], "count \(count) phase \(phase)")
                }
            }
        }
    }

    func testTheCycleRepeatsEveryTwoSeconds() {
        let count = 8
        for step in 0 ..< 20 {
            let phase = Double(step) / 10
            let first = ImageLayerLab.opaqueSlots(
                count: count,
                at: date(offsetIntoCycle: phase),
                reference: reference
            )
            let later = ImageLayerLab.opaqueSlots(
                count: count,
                at: date(offsetIntoCycle: phase + ImageLayerLab.cycleDuration),
                reference: reference
            )
            XCTAssertEqual(first, later, "phase \(phase)")
        }
    }

    /// The ceiling this approach cannot get past. The blink font's ligature
    /// keys on nothing but whether the seconds count is even, so no arrangement
    /// of it can tell one two-second window from the next.
    func testNothingBuiltFromTheBlinkFontCanOutlastTwoSeconds() {
        for offset in stride(from: 0.0, to: 2.0, by: 0.25) {
            let now = date(offsetIntoCycle: 0.4)
            XCTAssertEqual(
                ImageLayerLab.pulseIsOpaque(offset: offset, at: now, reference: reference),
                ImageLayerLab.pulseIsOpaque(
                    offset: offset,
                    at: now.addingTimeInterval(ImageLayerLab.cycleDuration),
                    reference: reference
                ),
                "offset \(offset)"
            )
        }
    }

    func testTrailingOffsetStaysInsideTheCycle() {
        for count in [2, 4, 16, 64] {
            for slot in 0 ..< count {
                let start = ImageLayerLab.slotStart(index: slot, count: count)
                let trailing = ImageLayerLab.trailingOffset(
                    start: start,
                    width: ImageLayerLab.slotWidth(count: count)
                )
                XCTAssertTrue(
                    trailing >= 0 && trailing < ImageLayerLab.cycleDuration,
                    "count \(count) slot \(slot) -> \(trailing)"
                )
            }
        }
    }

    // MARK: - Configuration

    func testLaunchArgumentsSayNothingWhenTheyMentionNothing() {
        let override = ImageLayerLab.launchOverride(in: ["Motionary"])
        XCTAssertNil(override.enabled)
        XCTAssertNil(override.settings)
    }

    func testLaunchArgumentsCarryTheWholeConfiguration() {
        let override = ImageLayerLab.launchOverride(in: [
            "-MotionaryImageLabOn",
            "-MotionaryImageLabFrames", "32",
            "-MotionaryImageLabSide", "180",
            "-MotionaryImageLabMode", "sheet",
        ])
        XCTAssertEqual(override.enabled, true)
        XCTAssertEqual(override.settings?.frameCount, 32)
        XCTAssertEqual(override.settings?.tileSide, 180)
        XCTAssertEqual(override.settings?.mode, .sheet)
    }

    /// One frame cannot be masked into a two-second cycle by windows that are
    /// at most a second wide, so a nonsense count is refused rather than
    /// silently drawing a widget that is blank half the time.
    func testAnImpossibleFrameCountIsIgnored() {
        let override = ImageLayerLab.launchOverride(in: [
            "-MotionaryImageLabFrames", "1",
            "-MotionaryImageLabSide", "64",
        ])
        XCTAssertEqual(override.settings?.tileSide, 64)
        XCTAssertNotEqual(override.settings?.frameCount, 1)
    }

    // MARK: - Probe frames

    func testProbeColoursAreDistinct() {
        let count = 64
        let colours = (0 ..< count).map { ImageLayerLab.probeColour(index: $0, count: count) }
        for (index, colour) in colours.enumerated() {
            for other in colours.indices where other != index {
                XCTAssertGreaterThan(
                    distance(colour, colours[other]),
                    0.02,
                    "frames \(index) and \(other) are the same colour"
                )
            }
        }
    }

    func testProbeFramesAreWrittenOncePerConfiguration() throws {
        let store = try DesignStore(containerURL: temporaryContainer())
        var settings = ImageLayerLab.Settings()
        settings.frameCount = 4
        settings.tileSide = 32

        XCTAssertEqual(try ImageLayerLab.writeProbeFrames(settings, in: store), 4)
        for index in 0 ..< 4 {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: ImageLayerLab.frameURL(index: index, in: store).path)
            )
        }
        XCTAssertEqual(try ImageLayerLab.writeProbeFrames(settings, in: store), 0, "rewritten unnecessarily")

        settings.frameCount = 8
        XCTAssertEqual(try ImageLayerLab.writeProbeFrames(settings, in: store), 8)
    }

    func testTheSheetHoldsEveryFrameInOneFile() throws {
        let store = try DesignStore(containerURL: temporaryContainer())
        var settings = ImageLayerLab.Settings()
        settings.frameCount = 6
        settings.tileSide = 24
        settings.mode = .sheet

        XCTAssertEqual(try ImageLayerLab.writeProbeFrames(settings, in: store), 1)
        let sheet = try XCTUnwrap(
            ImageLoader.load(at: ImageLayerLab.sheetURL(in: store), maxPixelSize: 4096)
        )
        XCTAssertEqual(sheet.width, 24)
        XCTAssertEqual(sheet.height % 6, 0, "the strip does not divide into whole frames")
    }

    // MARK: - Plumbing

    private func temporaryContainer() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func distance(_ lhs: UIColor, _ rhs: UIColor) -> CGFloat {
        var lr: CGFloat = 0, lg: CGFloat = 0, lb: CGFloat = 0, la: CGFloat = 0
        var rr: CGFloat = 0, rg: CGFloat = 0, rb: CGFloat = 0, ra: CGFloat = 0
        lhs.getRed(&lr, green: &lg, blue: &lb, alpha: &la)
        rhs.getRed(&rr, green: &rg, blue: &rb, alpha: &ra)
        return abs(lr - rr) + abs(lg - rg) + abs(lb - rb)
    }
}
