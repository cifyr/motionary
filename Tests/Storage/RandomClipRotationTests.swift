import XCTest

final class RandomClipRotationTests: XCTestCase {
    private func manifest(
        schedule: RandomClipSchedule,
        variants: [BuildManifest.VariantBuild] = []
    ) -> BuildManifest {
        var manifest = BuildManifest(
            designID: UUID(uuidString: "A0A0A0A0-1111-2222-3333-444444444444")!,
            buildGeneration: 1,
            fontFamilyBase: "MFontabcL",
            laneCount: 64,
            framesPerSecond: 32,
            loopFrameCount: 320,
            animationCrop: .zero,
            widgetRect: DeviceGeometry.widgetRect,
            screenSize: DeviceGeometry.screenPixelSize,
            wallpaperName: "wallpaper.png",
            totalFontBytes: 1,
            builtAt: Date()
        )
        manifest.primaryClipName = "Primary"
        manifest.clipVariants = variants
        manifest.randomClipSchedule = schedule
        return manifest
    }

    private func variant(_ name: String, frames: Int = 240) -> BuildManifest.VariantBuild {
        .init(id: UUID(), name: name, fontFamilyBase: "MFont\(name)L", totalFontBytes: 1, loopFrameCount: frames)
    }

    func testOffLeavesTheManualChoiceAlone() {
        XCTAssertNil(RandomClipRotation.choice(in: manifest(schedule: .off, variants: [variant("A")]), at: .now))
        XCTAssertNil(RandomClipRotation.nextTransition(after: .now, in: manifest(schedule: .off, variants: [variant("A")])))
    }

    func testLoopBoundaryUsesACommonClipBoundary() {
        let subject = manifest(schedule: .loopBoundary, variants: [variant("A", frames: 240)])
        XCTAssertEqual(RandomClipRotation.interval(for: subject), 30, accuracy: 0.001)
    }

    func testHourlyChoiceStaysStableUntilTheNextHour() throws {
        let subject = manifest(schedule: .hour, variants: [variant("A"), variant("B")])
        let hour = Date(timeIntervalSince1970: 1_728_000_000)
        XCTAssertEqual(
            try XCTUnwrap(RandomClipRotation.choice(in: subject, at: hour)).id,
            try XCTUnwrap(RandomClipRotation.choice(in: subject, at: hour.addingTimeInterval(3_599))).id
        )
        XCTAssertEqual(
            RandomClipRotation.nextTransition(after: hour.addingTimeInterval(12), in: subject),
            hour.addingTimeInterval(3_600)
        )
    }

    func testAutomaticSequenceNeverRepeatsAtAnAdjacentBoundary() throws {
        let subject = manifest(schedule: .hour, variants: [variant("A"), variant("B"), variant("C")])
        let start = Date(timeIntervalSince1970: 1_728_000_000)
        var previous: String?
        for hour in 0 ..< 48 {
            let current = try XCTUnwrap(
                RandomClipRotation.choice(in: subject, at: start.addingTimeInterval(Double(hour * 3_600)))
            ).id
            XCTAssertNotEqual(current, previous)
            previous = current
        }
    }
}
