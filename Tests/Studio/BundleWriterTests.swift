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

/// A locked phone times out after a couple of minutes and comes back as
/// "exited 70" under a wall of build settings, which reads as a broken build
/// rather than a phone that wants a thumb on it. The tool's own words say
/// which it is, so the message should too.
final class InstallerHintTests: XCTestCase {
    private let lockedOutput = """
    xcodebuild: error: Timed out waiting for all destinations matching the provided destination specifier to become available
        Available destinations for the "Motionary" scheme:
            { platform:iOS, arch:arm64, id:00008150-00042CA60C9A401C, name:iPhone Mini, \
    error:iPhone Mini may need to be unlocked to recover from previously reported preparation errors }
    """

    /// A locked phone also reports a timeout, so the order of the rules
    /// matters: being told to unlock it is more use than being told it did
    /// not answer.
    func testALockedPhoneSaysToUnlockItRatherThanThatItTimedOut() throws {
        let hint = try XCTUnwrap(InstallerHint.forOutput(lockedOutput))
        XCTAssertTrue(hint.contains("Unlock"), hint)
        XCTAssertFalse(hint.contains("did not answer"), hint)
    }

    func testATimeoutWithNoLockedDeviceStillSaysSomethingUseful() throws {
        let hint = try XCTUnwrap(
            InstallerHint.forOutput("xcodebuild: error: Timed out waiting for all destinations")
        )
        XCTAssertTrue(hint.contains("did not answer"), hint)
    }

    /// Verbatim from `devicectl`, because the only thing distinguishing this
    /// from a genuine signing failure is the wording it buries it under.
    private let stalePluginOutput = """
    ERROR: Failed to install the app on the device. (com.apple.dt.CoreDeviceError error 3002 (0xBBA))
        Unable to Install "Motionary" (IXUserPresentableErrorDomain error 1 (0x01))
        NSLocalizedRecoverySuggestion = Failed to create plugin data containers for plugin com.caden.Motionary.widget
        Failed to verify code signature of Motionary.app/PlugIns/MotionaryWidgetExtension.appex : \
    0xe8008015 (A valid provisioning profile for this executable was not found.)
    """

    func testARefusedWidgetContainerIsRecognisedSoTheInstallCanBeRetried() {
        XCTAssertTrue(InstallerHint.isStalePluginInstall(stalePluginOutput))
        XCTAssertFalse(InstallerHint.isStalePluginInstall(lockedOutput))
    }

    /// It reads as a signing failure, and being sent to Xcode to re-sign a
    /// profile that is already current is the one unhelpful answer.
    func testARefusedWidgetContainerSaysToDeleteTheAppRatherThanToReSign() throws {
        let hint = try XCTUnwrap(InstallerHint.forOutput(stalePluginOutput))
        XCTAssertTrue(hint.contains("Delete Motionary"), hint)
        XCTAssertFalse(hint.contains("Xcode"), hint)
    }

    /// The certificate is reissued weekly on a free account, so this is a
    /// recurring stop rather than a one-off setup step, and the phone is the
    /// only place it can be cleared.
    func testAnUntrustedCertificateSaysWhereOnThePhoneToTrustIt() throws {
        let hint = try XCTUnwrap(InstallerHint.forOutput("""
        Unable to launch com.caden.Motionary because it has an invalid code signature, inadequate \
        entitlements or its profile has not been explicitly trusted by the user.
        """))
        XCTAssertTrue(hint.contains("VPN & Device Management"), hint)
    }

    /// A compile error is the project's own problem and must not be dressed up
    /// as a phone that needs unlocking.
    func testAnOrdinaryBuildFailureGetsNoHint() {
        XCTAssertNil(InstallerHint.forOutput("LayoutEditor.swift:42: error: cannot find 'foo' in scope"))
        XCTAssertNil(InstallerHint.forOutput("error: linker command failed with exit code 1"))
    }
}
