import CoreGraphics
import XCTest

final class GeometryAndSnapTests: XCTestCase {
    // MARK: - Widget geometry

    func testFullScreenSlotMatchesTheMeasuredCalibration() {
        let rect = DeviceGeometry.widgetRect(size: .fullScreen, slot: .topLeft)
        XCTAssertEqual(rect, CGRect(x: 66, y: 270, width: 1074, height: 1632))
    }

    func testEveryWidgetRectStaysOnScreen() {
        let screen = CGRect(origin: .zero, size: DeviceGeometry.screenPixelSize)
        for size in WidgetSizeOption.allCases {
            let grid = size.slotGrid
            for column in 0 ..< grid.columns {
                for row in 0 ..< grid.rows {
                    let rect = DeviceGeometry.widgetRect(size: size, slot: WidgetSlot(column: column, row: row))
                    XCTAssertTrue(
                        screen.contains(rect),
                        "\(size.title) slot (\(column),\(row)) at \(rect) leaves the screen"
                    )
                }
            }
        }
    }

    func testNudgeIsClampedToTheScreen() {
        let rect = DeviceGeometry.widgetRect(
            size: .small,
            slot: .topLeft,
            nudge: CGPoint(x: -10_000, y: -10_000)
        )
        XCTAssertEqual(rect.minX, 0)
        XCTAssertEqual(rect.minY, 0)
    }

    func testOutOfRangeSlotClampsRatherThanCrashing() {
        let rect = DeviceGeometry.widgetRect(size: .small, slot: WidgetSlot(column: 99, row: 99))
        let last = DeviceGeometry.widgetRect(size: .small, slot: WidgetSlot(column: 1, row: 2))
        XCTAssertEqual(rect, last)
    }

    // MARK: - Scale invariants

    /// The composition is authored in screen pixels, so one screen pixel must
    /// be one device pixel wherever the result has to line up with the real
    /// Home Screen. Deriving scale from an assumed widget width instead makes
    /// every position depend on the size table being exact.
    func testScreenPixelsMapToPointsAtDeviceScale() {
        let pointsPerPixel = 1 / DeviceGeometry.scale
        XCTAssertEqual(DeviceGeometry.screenPixelSize.width * pointsPerPixel, 402, accuracy: 0.001)
        XCTAssertEqual(DeviceGeometry.screenPixelSize.height * pointsPerPixel, 874, accuracy: 0.001)
    }

    /// Measured from a placed large widget on an iPhone 17 Pro. Apple's
    /// documented 364x382 at a 19pt margin is wrong for this device, and the
    /// 7.33pt origin error showed up as the composition sitting ~22px right.
    func testLargeWidgetMatchesTheMeasuredRect() {
        let rect = DeviceGeometry.widgetRect(size: .large, slot: .topLeft)
        XCTAssertEqual(rect.minX, 79)
        XCTAssertEqual(rect.minY, 272)
        XCTAssertEqual(rect.width, 1049)
        XCTAssertEqual(rect.height, 1090)

        XCTAssertEqual(rect.minX / DeviceGeometry.scale, 26.33, accuracy: 0.01)
        XCTAssertNotEqual(rect.minX / DeviceGeometry.scale, 19, "the documented margin is not this device's")
    }

    /// Side margins should come out symmetric; an asymmetric result means the
    /// measured width and margin disagree.
    func testStandardFamiliesAreHorizontallyCentred() {
        for size in [WidgetSizeOption.medium, .large] {
            let rect = DeviceGeometry.widgetRect(size: size, slot: .topLeft)
            let rightMargin = DeviceGeometry.screenPixelSize.width - rect.maxX
            XCTAssertEqual(rect.minX, rightMargin, accuracy: 1, "\(size.title) is not centred")
        }
    }

    /// The two small slots must mirror each other and not overlap.
    func testSmallSlotsMirrorWithoutOverlapping() {
        let left = DeviceGeometry.widgetRect(size: .small, slot: WidgetSlot(column: 0, row: 0))
        let right = DeviceGeometry.widgetRect(size: .small, slot: WidgetSlot(column: 1, row: 0))
        XCTAssertLessThan(left.maxX, right.minX)
        XCTAssertEqual(left.minX, DeviceGeometry.screenPixelSize.width - right.maxX, accuracy: 1)
    }

    /// Large spans two grid units vertically, so two stacked small slots plus
    /// the gutter must reconstruct its measured height exactly.
    func testGridUnitsReconstructTheMeasuredLargeHeight() {
        let small = DeviceGeometry.widgetRect(size: .small, slot: WidgetSlot(column: 0, row: 0))
        let secondRow = DeviceGeometry.widgetRect(size: .small, slot: WidgetSlot(column: 0, row: 1))
        let large = DeviceGeometry.widgetRect(size: .large, slot: .topLeft)
        XCTAssertEqual(secondRow.maxY - small.minY, large.height, accuracy: 0.01)
    }

    // MARK: - Crop derivation

    func testEffectiveCropIsClippedToTheWidgetFrame() {
        var design = DesignDocument.new(name: "test", sourceVideoName: "source.mov")
        design.widgetSize = .small
        design.widgetSlot = .topLeft
        design.animationCrop = CGRect(origin: .zero, size: DeviceGeometry.screenPixelSize)

        let crop = design.effectiveCrop
        XCTAssertEqual(crop, design.widgetRect.integral)
        XCTAssertLessThan(
            crop.width * crop.height,
            DeviceGeometry.screenPixelSize.width * DeviceGeometry.screenPixelSize.height,
            "a small widget must encode far fewer pixels than the whole screen"
        )
    }

    func testDisjointCropAndWidgetProduceAnEmptyCrop() {
        var design = DesignDocument.new(name: "test", sourceVideoName: "source.mov")
        design.widgetSize = .small
        design.widgetSlot = .topLeft
        design.animationCrop = CGRect(x: 0, y: 2400, width: 200, height: 200)
        XCTAssertTrue(design.effectiveCrop.isEmpty)
    }

    // MARK: - Timer spec

    func testSeamlessLoopLengthsDivideTheCycle() {
        let spec = TimerFontSpec(smoothness: .standard)
        for length in spec.seamlessLoopLengths(maximum: 64) {
            XCTAssertTrue(spec.divides(loopFrameCount: length), "\(length) should divide \(spec.totalFrames)")
        }
        XCTAssertTrue(spec.seamlessLoopLengths(maximum: 64).contains(32))
        XCTAssertFalse(spec.divides(loopFrameCount: 7))
    }

    func testFrameIndexWrapsWithinTheCycle() {
        let spec = TimerFontSpec(smoothness: .standard)
        XCTAssertEqual(spec.frame(at: 0), 0)
        XCTAssertEqual(spec.frame(at: spec.loopDuration), 0)
        XCTAssertEqual(spec.frame(at: 1), spec.framesPerSecond)
        XCTAssertTrue((0 ..< spec.totalFrames).contains(spec.frame(at: -3.5)))
    }

    func testSmoothnessOptionsAllHoldTheThirtySecondCycle() {
        for smoothness in MotionSmoothness.allCases {
            let spec = TimerFontSpec(smoothness: smoothness)
            XCTAssertEqual(spec.loopDuration, TimerFontSpec.cycleDuration, accuracy: 0.001, "\(smoothness)")
        }
    }

    // MARK: - Widget/app phase continuity

    /// The reference must land on a whole cycle, otherwise the app cannot work
    /// out what the widget is showing without being told.
    func testCycleAlignedReferenceLandsOnACycleBoundary() {
        for offset in [0.0, 7.3, 29.999, 30.0, 1_234_567.89] {
            let reference = TimerFontSpec.cycleAlignedReference(at: Date(timeIntervalSince1970: offset))
            let sinceEpoch = reference.timeIntervalSince1970 + 60
            XCTAssertEqual(
                sinceEpoch.truncatingRemainder(dividingBy: TimerFontSpec.cycleDuration), 0, accuracy: 0.0001,
                "reference for offset \(offset) is not cycle aligned"
            )
        }
    }

    /// The reference jumps a whole cycle every 30 seconds. That must not move
    /// the picture, or the animation would stutter every wrap.
    func testCrossingACycleBoundaryDoesNotChangeTheFrame() {
        let spec = TimerFontSpec(smoothness: .standard)
        // 1_000_050 is a multiple of the 30-second cycle; 1_000_030 is not.
        let boundary = 1_000_050.0
        let justBefore = Date(timeIntervalSince1970: boundary - 0.001)
        let justAfter = Date(timeIntervalSince1970: boundary + 0.001)

        let before = TimerFontSpec.cycleAlignedReference(at: justBefore)
        let after = TimerFontSpec.cycleAlignedReference(at: justAfter)
        XCTAssertEqual(
            after.timeIntervalSince1970 - before.timeIntervalSince1970,
            TimerFontSpec.cycleDuration, accuracy: 0.0001,
            "the anchor should advance exactly one cycle"
        )

        // The anchor jumped a whole cycle, so the frame must not jump with it:
        // the last frame of the cycle is adjacent to frame 0.
        XCTAssertEqual(spec.globalFrame(at: Date(timeIntervalSince1970: boundary)), 0)
        XCTAssertEqual(spec.globalFrame(at: justBefore), spec.totalFrames - 1)
    }

    func testFrameIsAPureFunctionOfWallClockTimeWithACycleLongPeriod() {
        let spec = TimerFontSpec(smoothness: .standard)
        for offset in [0.0, 3.5, 17.25, 29.9] {
            let now = Date(timeIntervalSince1970: 1_700_000_000 + offset)
            let cycleLater = now.addingTimeInterval(TimerFontSpec.cycleDuration)
            XCTAssertEqual(spec.globalFrame(at: now), spec.globalFrame(at: cycleLater), "offset \(offset)")
        }
    }

    /// The seek target has to land inside the loop, whatever the loop length.
    func testVideoTimeStaysWithinTheLoop() {
        for smoothness in MotionSmoothness.allCases {
            let spec = TimerFontSpec(smoothness: smoothness)
            for loop in spec.seamlessLoopLengths(maximum: 64) {
                let duration = Double(loop) / Double(spec.framesPerSecond)
                for step in 0 ..< 60 {
                    let now = Date(timeIntervalSince1970: Double(step) * 0.5)
                    let time = spec.videoTime(at: now, loopFrameCount: loop)
                    XCTAssertGreaterThanOrEqual(time, 0)
                    XCTAssertLessThan(time, duration, "\(smoothness) loop \(loop) step \(step)")
                }
            }
        }
    }

    func testVideoTimeIsZeroForAnEmptyLoop() {
        let spec = TimerFontSpec(smoothness: .standard)
        XCTAssertEqual(spec.videoTime(loopFrameCount: 0), 0)
    }

    // MARK: - Snapping

    private func engine() -> SnapEngine {
        SnapEngine(widgetRect: DeviceGeometry.widgetRect(size: .fullScreen, slot: .topLeft))
    }

    func testTileSnapsToTheWidgetCentreLine() {
        let widget = DeviceGeometry.widgetRect(size: .fullScreen, slot: .topLeft)
        let result = engine().snap(
            center: CGPoint(x: widget.midX + 6, y: 900),
            tileSize: 200,
            siblings: []
        )
        XCTAssertEqual(result.center.x, widget.midX, accuracy: 0.01)
        XCTAssertTrue(result.guides.contains { $0.axis == .vertical })
    }

    func testDistantTileDoesNotSnap() {
        let widget = DeviceGeometry.widgetRect(size: .fullScreen, slot: .topLeft)
        let free = CGPoint(x: widget.midX + 300, y: 907)
        let result = engine().snap(center: free, tileSize: 200, siblings: [])
        XCTAssertEqual(result.center.x, free.x, accuracy: 0.01)
    }

    func testTileSnapsToASiblingsAxis() {
        let sibling = PlacedTile(appID: "spotify", center: CGPoint(x: 400, y: 800), size: 200)
        let result = engine().snap(
            center: CGPoint(x: 405, y: 1500),
            tileSize: 200,
            siblings: [sibling]
        )
        XCTAssertEqual(result.center.x, 400, accuracy: 0.01)
        XCTAssertTrue(result.guides.contains { $0.kind == .sibling })
    }

    func testClampKeepsTilesFullyOnScreen() {
        let clamped = engine().clamp(center: CGPoint(x: -500, y: -500), tileSize: 200)
        XCTAssertEqual(clamped, CGPoint(x: 100, y: 100))
    }

    func testClampCentresATileLargerThanTheScreen() {
        // No valid range exists, so the clamp must not invert.
        let clamped = engine().clamp(center: .zero, tileSize: 9_000)
        XCTAssertEqual(clamped.x, DeviceGeometry.screenPixelSize.width / 2, accuracy: 0.01)
    }

    // MARK: - Rotation

    /// A rotated tile's footprint grows, so clamping against the plate side
    /// alone would let a corner hang off the screen.
    func testRotatedTileReportsALargerFootprint() {
        var tile = PlacedTile(appID: "spotify", center: CGPoint(x: 400, y: 400), size: 100)
        XCTAssertEqual(tile.boundingExtent, 100, accuracy: 0.01)

        tile.rotation = 45
        XCTAssertEqual(tile.boundingExtent, 100 * sqrt(2), accuracy: 0.01)

        tile.rotation = 90
        XCTAssertEqual(tile.boundingExtent, 100, accuracy: 0.01, "a quarter turn is square again")

        tile.rotation = -45
        XCTAssertEqual(tile.boundingExtent, 100 * sqrt(2), accuracy: 0.01, "direction must not matter")
    }

    func testRotationSnapsToIncrementsWhenClose() {
        let engine = engine()
        XCTAssertEqual(engine.snap(rotation: 44), 45, accuracy: 0.001)
        XCTAssertEqual(engine.snap(rotation: 2), 0, accuracy: 0.001)
        XCTAssertEqual(engine.snap(rotation: -89), -90, accuracy: 0.001)
    }

    func testRotationBetweenIncrementsIsLeftAlone() {
        // 22 is 7 degrees from both 15 and 30, outside the threshold.
        XCTAssertEqual(engine().snap(rotation: 22), 22, accuracy: 0.001)
    }

    func testRotationSnapsAcrossTheWrapPoint() {
        // 359 is one degree from zero, not 359 degrees from it.
        XCTAssertEqual(engine().snap(rotation: 359), 0, accuracy: 0.001)
        // Wrapping normalises to (-180, 180], so a half turn is +180.
        XCTAssertEqual(engine().snap(rotation: 181), 180, accuracy: 0.001)
    }

    func testAngleWrappingIsStable() {
        XCTAssertEqual(SnapEngine.wrap(0), 0, accuracy: 0.001)
        XCTAssertEqual(SnapEngine.wrap(180), 180, accuracy: 0.001)
        XCTAssertEqual(SnapEngine.wrap(-180), 180, accuracy: 0.001)
        XCTAssertEqual(SnapEngine.wrap(540), 180, accuracy: 0.001)
        XCTAssertEqual(SnapEngine.wrap(-370), -10, accuracy: 0.001)
    }

    func testAngleDifferenceTakesTheShortWayRound() {
        XCTAssertEqual(SnapEngine.difference(10, 350), 20, accuracy: 0.001)
        XCTAssertEqual(SnapEngine.difference(350, 10), -20, accuracy: 0.001)
    }

    func testRotationSurvivesEncoding() throws {
        var tile = PlacedTile(appID: "spotify", center: CGPoint(x: 1, y: 2), size: 100)
        tile.rotation = -37.5
        let decoded = try JSONDecoder().decode(PlacedTile.self, from: JSONEncoder().encode(tile))
        XCTAssertEqual(decoded.rotation, -37.5, accuracy: 0.001)
    }

    /// Designs written before rotation existed must still decode.
    func testTileWithoutRotationDecodesUpright() throws {
        let json = """
        {"id":"\(UUID().uuidString)","appID":"spotify","center":[10,20],"size":100,
         "cornerRadius":0.22,"showsLabel":true,"opacity":1}
        """
        let tile = try JSONDecoder().decode(PlacedTile.self, from: Data(json.utf8))
        XCTAssertEqual(tile.rotation, 0)
        XCTAssertEqual(tile.boundingExtent, 100, accuracy: 0.01)
    }

    // MARK: - Payload budget

    func testBudgetScalesWithLaneCount() {
        let heavy = PayloadBudget(spec: TimerFontSpec(smoothness: .standard), averageEncodedFrameBytes: 30_000)
        let light = PayloadBudget(spec: TimerFontSpec(smoothness: .light), averageEncodedFrameBytes: 30_000)
        XCTAssertGreaterThan(heavy.estimatedTotalBytes, light.estimatedTotalBytes)
        XCTAssertEqual(heavy.glyphSelections, 960)
        XCTAssertEqual(light.glyphSelections, 480)
    }

    func testOversizedPayloadIsFlagged() {
        let budget = PayloadBudget(spec: TimerFontSpec(smoothness: .standard), averageEncodedFrameBytes: 200_000)
        XCTAssertFalse(budget.isWithinRecommended)
        XCTAssertTrue(budget.exceedsHardLimit)
    }

    // MARK: - Launch links

    func testLaunchLinkRoundTrips() {
        let url = LaunchLink.url(for: "spotify")
        XCTAssertEqual(LaunchLink.appID(from: url), "spotify")
        XCTAssertNil(LaunchLink.appID(from: URL(string: "https://example.com/launch/spotify")!))
    }

    func testCatalogEntriesAreUniqueAndLaunchable() {
        let ids = AppCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "catalog ids must be unique")
        for app in AppCatalog.all {
            XCTAssertFalse(app.launchCandidates.isEmpty, "\(app.name) has no launch route")
        }
    }
}
