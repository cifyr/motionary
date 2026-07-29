import CoreGraphics
import XCTest

final class GeometryAndSnapTests: XCTestCase {
    // MARK: - Widget geometry

    /// The one calibration, measured on a physical iPhone 17 Pro by the
    /// Onewheel build. Everything the app renders is cut to this rect, so if it
    /// drifts the widget stops lining up with the wallpaper behind it.
    func testWidgetRectMatchesTheOnewheelCalibration() {
        XCTAssertEqual(DeviceGeometry.widgetRect, CGRect(x: 66, y: 270, width: 1074, height: 1632))
    }

    /// 1074x1632 at 3x is the tall portrait family's 358x544 points.
    func testCalibratedFrameIsTheTallPortraitFamilyInPoints() {
        let points = WidgetSizeOption.fullScreen.pointSize
        XCTAssertEqual(points.width, 358, accuracy: 0.01)
        XCTAssertEqual(points.height, 544, accuracy: 0.01)
    }

    func testWidgetRectStaysOnScreen() {
        let screen = CGRect(origin: .zero, size: DeviceGeometry.screenPixelSize)
        XCTAssertTrue(screen.contains(DeviceGeometry.widgetRect))
    }

    /// Side margins come out symmetric; an asymmetric result means the measured
    /// width and origin disagree.
    func testWidgetIsHorizontallyCentred() {
        let rect = DeviceGeometry.widgetRect
        let rightMargin = DeviceGeometry.screenPixelSize.width - rect.maxX
        XCTAssertEqual(rect.minX, rightMargin, accuracy: 1)
    }

    func testNudgeIsClampedToTheScreen() {
        let rect = DeviceGeometry.widgetRect(nudge: CGPoint(x: -10_000, y: -10_000))
        XCTAssertEqual(rect.minX, 0)
        XCTAssertEqual(rect.minY, 0)
        XCTAssertEqual(rect.size, DeviceGeometry.pixelSize, "a nudge must move the frame, not resize it")
    }

    // MARK: - Single family

    /// Only the tall portrait family is advertised. Offering several is what
    /// let a design cut for one shape be dropped into another, and on iOS 27
    /// the family enum reported two different families for one widget at an
    /// identical rendered size.
    func testOnlyTheTallPortraitFamilyIsAdvertisedOniOS27() {
        let families = WidgetFamilyCompatibility.supportedFamilies()
        XCTAssertEqual(families.count, 1)
    }

    func testThereIsExactlyOneWidgetSize() {
        XCTAssertEqual(WidgetSizeOption.allCases, [.fullScreen])
    }

    /// Designs saved when small, medium and large existed name those sizes.
    /// Decoding strictly would throw, and the store drops designs it cannot
    /// read, so they would leave the library rather than fail loudly.
    func testDesignsSavedUnderTheOldSizesStillDecode() throws {
        for legacy in ["small", "medium", "large", "fullScreen", "nonsense"] {
            let json = """
            {"name":"old","sourceVideoName":"source.mov","widgetSize":"\(legacy)",
             "widgetSlot":{"column":1,"row":2},
             "animationCrop":[[0,0],[100,100]]}
            """
            let design = try JSONDecoder().decode(DesignDocument.self, from: Data(json.utf8))
            XCTAssertEqual(design.widgetSize, .fullScreen, "\(legacy) should migrate, not throw")
            XCTAssertEqual(design.widgetRect, DeviceGeometry.widgetRect)
        }
    }

    // MARK: - Scale invariants

    /// The composition is authored in screen pixels, so one screen pixel must
    /// be one device pixel wherever the result has to line up with the real
    /// Home Screen. Deriving scale from an assumed widget width instead makes
    /// every position depend on the frame being exact.
    func testScreenPixelsMapToPointsAtDeviceScale() {
        let pointsPerPixel = 1 / DeviceGeometry.scale
        XCTAssertEqual(DeviceGeometry.screenPixelSize.width * pointsPerPixel, 402, accuracy: 0.001)
        XCTAssertEqual(DeviceGeometry.screenPixelSize.height * pointsPerPixel, 874, accuracy: 0.001)
    }

    // MARK: - Crop derivation

    func testEffectiveCropIsClippedToTheWidgetFrame() {
        var design = DesignDocument.new(name: "test", sourceVideoName: "source.mov")
        design.animationCrop = CGRect(origin: .zero, size: DeviceGeometry.screenPixelSize)

        let crop = design.effectiveCrop
        XCTAssertEqual(crop, design.widgetRect.integral)
        XCTAssertLessThan(
            crop.width * crop.height,
            DeviceGeometry.screenPixelSize.width * DeviceGeometry.screenPixelSize.height,
            "motion outside the widget frame must not be encoded"
        )
    }

    func testDisjointCropAndWidgetProduceAnEmptyCrop() {
        var design = DesignDocument.new(name: "test", sourceVideoName: "source.mov")
        design.animationCrop = CGRect(x: 0, y: 2400, width: 200, height: 200)
        XCTAssertTrue(design.effectiveCrop.isEmpty)
        XCTAssertFalse(design.hasAnimatedArea)
    }

    /// Motion detected below the widget frame used to be stored as it came,
    /// which built a design that could never be built: every attempt ended in
    /// "no animated area" with no way to put it right.
    func testMotionOutsideTheWidgetFallsBackToTheWholeFrame() {
        let widget = DeviceGeometry.widgetRect
        let belowTheWidget = CGRect(x: 0, y: 2400, width: 200, height: 200)
        XCTAssertEqual(DesignDocument.usableCrop(belowTheWidget, in: widget), widget)
    }

    func testMotionStraddlingTheWidgetEdgeIsClamped() {
        let widget = DeviceGeometry.widgetRect
        let straddling = CGRect(x: 100, y: 100, width: 400, height: 400)
        let usable = DesignDocument.usableCrop(straddling, in: widget)
        XCTAssertEqual(usable, straddling.intersection(widget).integral)
        XCTAssertTrue(widget.insetBy(dx: -1, dy: -1).contains(usable))
    }

    func testAWholeScreenCropReducesToTheWidgetFrame() {
        let widget = DeviceGeometry.widgetRect
        let screen = CGRect(origin: .zero, size: DeviceGeometry.screenPixelSize)
        XCTAssertEqual(DesignDocument.usableCrop(screen, in: widget), widget.integral)
    }

    /// A loop is measured in frames, so changing smoothness changes how long
    /// it lasts. 40 frames is 1.25s at 32fps but 2.5s at 16fps — the same clip
    /// at half speed, which is exactly what the optimiser used to produce.
    func testRetuningTheLoopKeepsTheSourceDuration() {
        var design = DesignDocument.new(name: "test", sourceVideoName: "source.gif")
        design.sourceDuration = 1.2

        design.smoothness = .standard
        design.retuneLoop()
        let smooth = design.loopDuration
        XCTAssertEqual(smooth, 1.2, accuracy: 0.2, "should track the 1.2s source")

        design.smoothness = .light
        design.retuneLoop()
        XCTAssertEqual(design.loopDuration, 1.2, accuracy: 0.2, "still 1.2s at a lower frame rate")
        XCTAssertEqual(design.loopDuration, smooth, accuracy: 0.2, "smoothness must not change the speed")
    }

    func testRetuningLeavesTheLoopAloneWithoutAKnownDuration() {
        var design = DesignDocument.new(name: "test", sourceVideoName: "source.gif")
        design.loopFrameCount = 32
        design.retuneLoop()
        XCTAssertEqual(design.loopFrameCount, 32)
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
        SnapEngine(widgetRect: DeviceGeometry.widgetRect)
    }

    func testTileSnapsToTheWidgetCentreLine() {
        let widget = DeviceGeometry.widgetRect
        let result = engine().snap(
            center: CGPoint(x: widget.midX + 6, y: 900),
            tileSize: 200,
            siblings: []
        )
        XCTAssertEqual(result.center.x, widget.midX, accuracy: 0.01)
        XCTAssertTrue(result.guides.contains { $0.axis == .vertical })
    }

    func testDistantTileDoesNotSnap() {
        let widget = DeviceGeometry.widgetRect
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

    /// Apple does not publish a URL scheme for every one of its apps, so
    /// "everything is launchable" was never true - it had simply never been
    /// tested against an entry that admitted it. The rule that does hold is
    /// narrower: an entry is launchable unless it is one of the few known not
    /// to be, and a new entry arriving with no scheme still fails here.
    private static let knownUnlaunchable: Set<String> = ["clock"]

    func testCatalogEntriesAreUniqueAndLaunchable() {
        let ids = AppCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "catalog ids must be unique")
        for app in AppCatalog.all where !Self.knownUnlaunchable.contains(app.id) {
            XCTAssertTrue(app.canLaunch, "\(app.name) has no launch route")
        }
    }

    func testUnlaunchableEntriesAdmitIt() {
        for id in Self.knownUnlaunchable {
            let app = AppCatalog.app(id: id)
            XCTAssertNotNil(app, "\(id) is listed as unlaunchable but is not in the catalogue")
            XCTAssertEqual(app?.canLaunch, false, "\(id) gained a launch route; take it off the list")
        }
    }
}
