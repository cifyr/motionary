import XCTest

/// The store-facing settings that a project regeneration or a plist rewrite can
/// drop without any build noticing: the archive still comes out, and the
/// difference is only visible on a reviewer's iPad or in the first frame after
/// the icon is tapped.
final class StoreReadinessTests: XCTestCase {
    /// An empty `UILaunchScreen` is a white flash before an app that is dark
    /// everywhere. The colour it names has to exist in the catalog the app
    /// ships, or the flash is back with nothing in the log about it.
    func testTheLaunchScreenIsDark() throws {
        let plist = try ProjectRoot.plist(at: "App/Info.plist")
        let launch = try XCTUnwrap(plist["UILaunchScreen"] as? [String: Any], "no UILaunchScreen")
        let colorName = try XCTUnwrap(launch["UIColorName"] as? String, "the launch screen names no colour")

        let colorset = ProjectRoot.url
            .appendingPathComponent("Resources/Assets.xcassets/\(colorName).colorset/Contents.json")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: colorset.path),
            "UILaunchScreen names \(colorName), which is not in Resources/Assets.xcassets"
        )

        // An asset catalog's Contents.json is JSON, not a plist, whatever the
        // rest of the catalog looks like.
        let contents = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: colorset)) as? [String: Any]
        )
        let colors = try XCTUnwrap(contents["colors"] as? [[String: Any]])
        let components = try XCTUnwrap(colors.first?["color"].flatMap { $0 as? [String: Any] }?["components"] as? [String: String])
        for channel in ["red", "green", "blue"] {
            let value = try XCTUnwrap(components[channel].flatMap { UInt8($0.dropFirst(2), radix: 16) }, channel)
            XCTAssertLessThan(value, 0x20, "the launch colour is not dark on \(channel)")
        }
    }

    /// The composition is laid out for measured iPhone screens. XcodeGen's
    /// default of "1,2" also offers the app to iPads, which is where App
    /// Review looks first and where nothing has ever been measured.
    func testTheAppIsForIPhonesOnly() throws {
        let project = try ProjectRoot.text(at: "project.yml")
        let pins = project.components(separatedBy: "TARGETED_DEVICE_FAMILY: \"1\"").count - 1
        XCTAssertGreaterThanOrEqual(pins, 2, "the app and the extension both have to pin TARGETED_DEVICE_FAMILY to iPhone")
        XCTAssertFalse(project.contains("TARGETED_DEVICE_FAMILY: \"1,2\""), "an iOS target still targets iPads")
    }

    /// Every permission the app asks for has to explain itself, or the
    /// request is refused by the system and the upload by the store. The
    /// exporter asks for add-only Photos access; the delivery receiver
    /// advertises on the local network.
    func testEveryPermissionIsExplained() throws {
        let plist = try ProjectRoot.plist(at: "App/Info.plist")
        for key in [
            "NSPhotoLibraryAddUsageDescription",
            "NSLocalNetworkUsageDescription",
            "NSCalendarsUsageDescription",
        ] {
            let text = plist[key] as? String ?? ""
            XCTAssertGreaterThan(text.count, 20, "\(key) is missing or says nothing")
        }
        XCTAssertEqual(plist["ITSAppUsesNonExemptEncryption"] as? Bool, false)
        XCTAssertEqual(plist["NSBonjourServices"] as? [String], ["_motionary._tcp"])
    }

    func testBothTargetsCarryAPrivacyManifest() throws {
        for path in ["App/PrivacyInfo.xcprivacy", "Widget/PrivacyInfo.xcprivacy"] {
            let manifest = try ProjectRoot.plist(at: path)
            XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false, path)
            XCTAssertEqual((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.count, 0, "\(path) claims to collect data")
        }
    }
}
