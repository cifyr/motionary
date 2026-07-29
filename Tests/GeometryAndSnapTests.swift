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
