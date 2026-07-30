import XCTest

/// The studio's bundling step is the only thing standing between a built
/// design and a widget that draws it, and it fails quietly: a plist whose
/// `UIAppFonts` list is stale still builds, installs, and shows a black widget.
final class BundleWriterTests: XCTestCase {
    private let lanes = ["MFontabcL0-Regular.ttf", "MFontabcL1-Regular.ttf"]

    private func plist(_ appFonts: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
          <key>CFBundleName</key>
          <string>Motionary</string>
          \(appFonts)
          <key>NSExtension</key>
          <dict/>
        </dict>
        </plist>
        """
    }

    func testListsTheBlinkFontAndEveryLane() throws {
        let rewritten = try BundleWriter.replacingAppFonts(
            in: plist("<key>UIAppFonts</key>\n  <array>\n    <string>Old-Regular.ttf</string>\n  </array>"),
            with: lanes,
            path: "test"
        )
        XCTAssertTrue(rewritten.contains("<string>\(FontSetGenerator.blinkFontResourceName).otf</string>"))
        for lane in lanes {
            XCTAssertTrue(rewritten.contains("<string>\(lane)</string>"), "\(lane) is missing")
        }
        XCTAssertFalse(rewritten.contains("Old-Regular"), "the previous design's fonts survived")
    }

    func testLeavesTheRestOfThePlistAlone() throws {
        let rewritten = try BundleWriter.replacingAppFonts(
            in: plist("<key>UIAppFonts</key><array><string>Old.ttf</string></array>"),
            with: lanes,
            path: "test"
        )
        XCTAssertTrue(rewritten.contains("<key>CFBundleName</key>"))
        XCTAssertTrue(rewritten.contains("<string>Motionary</string>"))
        XCTAssertTrue(rewritten.contains("<key>NSExtension</key>"))
    }

    /// Rewriting twice has to be the same as rewriting once, because the studio
    /// runs on a project it has already built.
    func testRewritingIsIdempotent() throws {
        let once = try BundleWriter.replacingAppFonts(
            in: plist("<key>UIAppFonts</key><array><string>Old.ttf</string></array>"),
            with: lanes,
            path: "test"
        )
        let twice = try BundleWriter.replacingAppFonts(in: once, with: lanes, path: "test")
        XCTAssertEqual(once, twice)
    }

    /// A silent no-op here is the worst outcome: the build succeeds and the
    /// widget is black because the fonts were never declared.
    func testMissingArraySaysSoRatherThanDoingNothing() {
        XCTAssertThrowsError(try BundleWriter.replacingAppFonts(
            in: plist("<key>Unrelated</key><string>x</string>"),
            with: lanes,
            path: "App/Info.plist"
        )) { error in
            XCTAssertTrue("\(error)".contains("UIAppFonts"), "unhelpful error: \(error)")
        }
    }

    /// The real files, so a reformat that breaks the rewrite fails here rather
    /// than on the phone.
    ///
    /// Read loudly: this walked one folder too few and then swallowed the miss,
    /// so it passed for weeks without opening either plist.
    func testBothShippedPlistsCanBeRewritten() throws {
        for relative in ["App/Info.plist", "Widget/Info.plist"] {
            let text = try ProjectRoot.text(at: relative)
            let rewritten = try BundleWriter.replacingAppFonts(in: text, with: lanes, path: relative)
            XCTAssertTrue(rewritten.contains(lanes[0]), "\(relative) did not take the lane list")
            XCTAssertTrue(rewritten.contains("CFBundle"), "\(relative) lost its other keys")
        }
    }
}

/// The geometry is measured, not derived, and the measurement is the whole
/// reason the composition lands where it should.
final class DeviceModelTests: XCTestCase {
    func testCalibratedPhoneMatchesTheMeasuredWidget() {
        let model = DeviceModel.iPhone17Pro
        XCTAssertEqual(model.widgetPointSize.width, 358, accuracy: 0.01)
        XCTAssertEqual(model.widgetPointSize.height, 544, accuracy: 0.01)
        XCTAssertEqual(model.widgetRect.minX / model.scale, 22, accuracy: 0.01)
    }

    func testTheWidgetFitsOnTheScreen() {
        for model in DeviceModel.all {
            let screen = CGRect(origin: .zero, size: model.screenPixelSize)
            XCTAssertTrue(
                screen.contains(model.widgetRect),
                "\(model.name)'s widget rect falls outside its screen"
            )
        }
    }

    func testEveryModelIsDistinct() {
        XCTAssertEqual(Set(DeviceModel.all.map(\.id)).count, DeviceModel.all.count)
    }

    /// The globals the iOS build compiles against have to be the model the
    /// studio cut the design for, or the widget crops the wrong region.
    func testBuildGeometryFollowsTheSelectedModel() {
        XCTAssertEqual(DeviceGeometry.widgetRect, DeviceGeometry.model.widgetRect)
        XCTAssertEqual(DeviceGeometry.screenPixelSize, DeviceGeometry.model.screenPixelSize)
    }
}
