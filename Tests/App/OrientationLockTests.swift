import XCTest

/// The app must never turn sideways.
///
/// A design is composed in one measured device's portrait screen pixels and
/// pinned to the view's top-left at 1:1, so a landscape window shows the wrong
/// crop rather than a relaid-out screen - and the widget it mirrors has only the
/// tall portrait family.
///
/// The declaration in `App/Info.plist` is the whole mechanism; there is no
/// runtime code holding it up. That file is fed to a generated project and
/// rewritten in place by the studio's bundling step on every design build, so
/// this is what notices when either drops the keys.
final class OrientationLockTests: XCTestCase {
    private let portraitOnly = ["UIInterfaceOrientationPortrait"]
    private let orientationKey = "UISupportedInterfaceOrientations"

    func testTheAppDeclaresPortraitAndNothingElse() throws {
        let plist = try ProjectRoot.plist(at: "App/Info.plist")
        let orientations = try XCTUnwrap(
            plist[orientationKey] as? [String],
            "App/Info.plist declares no \(orientationKey), which is why the app used to rotate"
        )
        XCTAssertEqual(orientations, portraitOnly)
    }

    /// The target's device family is 1,2 - XcodeGen's default for an iOS app -
    /// and iPadOS prefers the suffixed key, falling back to all four orientations
    /// when it is absent.
    func testTheIPadVariantSaysTheSameThing() throws {
        let plist = try ProjectRoot.plist(at: "App/Info.plist")
        let orientations = try XCTUnwrap(
            plist["\(orientationKey)~ipad"] as? [String],
            "the app ships for iPad too, so the ~ipad key has to say portrait as well"
        )
        XCTAssertEqual(orientations, portraitOnly)
    }

    /// Every variant has to agree, or one device family rotates while the rest
    /// stay put.
    func testNoOrientationKeyAdmitsLandscape() throws {
        let plist = try ProjectRoot.plist(at: "App/Info.plist")
        let keys = plist.keys.filter { $0.hasPrefix(orientationKey) }
        XCTAssertFalse(keys.isEmpty, "no orientation declaration at all")
        for key in keys {
            XCTAssertEqual(plist[key] as? [String], portraitOnly, "\(key) admits more than portrait")
        }
    }

    /// A widget has no orientation of its own: WidgetKit asks the extension for a
    /// view at a fixed family size and rasterises it elsewhere. A key here would
    /// claim otherwise and change nothing.
    func testTheWidgetDeclaresNoOrientations() throws {
        let plist = try ProjectRoot.plist(at: "Widget/Info.plist")
        XCTAssertTrue(
            plist.keys.filter { $0.hasPrefix(orientationKey) }.isEmpty,
            "the extension declares orientations it cannot honour"
        )
    }

    /// The studio rewrites `UIAppFonts` in this file on every design build, with
    /// a regex over the text rather than a re-encode, so the lock has to come
    /// out the other side intact.
    func testTheLockSurvivesTheStudiosFontRewrite() throws {
        let rewritten = try BundleWriter.replacingAppFonts(
            in: try ProjectRoot.text(at: "App/Info.plist"),
            with: ["MFontabcL0-Regular.ttf"],
            path: "App/Info.plist"
        )
        let data = try XCTUnwrap(rewritten.data(using: .utf8))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist[orientationKey] as? [String], portraitOnly)
        XCTAssertEqual(plist["\(orientationKey)~ipad"] as? [String], portraitOnly)
    }
}
