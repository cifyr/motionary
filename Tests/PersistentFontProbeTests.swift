import CoreGraphics
import CoreText
import XCTest

/// Pins down what the persistent font scope does with a font the app generated,
/// which is the only route left that could put one in front of the widget
/// renderer process.
///
/// What the simulator can and cannot settle, stated once so no result below is
/// read for more than it is worth. The simulator has none of the device's
/// sandbox restrictions, so a font working here proves nothing about a phone.
/// The useful direction is the other one: an API that refuses *here* will
/// refuse there too, and a scope that is structurally per-process here is
/// per-process by design rather than by policy. Every assertion below is
/// written to fail if iOS ever starts being more permissive, because that - not
/// the refusals - is the event worth being told about.
final class PersistentFontProbeTests: XCTestCase {
    private var templateData: Data!
    private var scratch: URL!

    override func setUpWithError() throws {
        let bundle = Bundle(for: Self.self)
        let templateURL = try XCTUnwrap(
            bundle.url(forResource: FontSetGenerator.templateResourceName, withExtension: "ttf"),
            "shaping template missing from the test bundle"
        )
        templateData = try Data(contentsOf: templateURL)
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PersistentFontProbe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch, FileManager.default.fileExists(atPath: scratch.path) {
            try FileManager.default.removeItem(at: scratch)
        }
    }

    /// A font nothing else has ever seen, so a leftover registration cannot
    /// turn a refusal into `alreadyRegistered` or a miss into a hit.
    private func makeCandidate(in directory: URL? = nil, location: String = "container") throws -> PersistentFontProbe.Candidate {
        let builder = try LaneFontBuilder(
            templateData: templateData,
            spec: TimerFontSpec(smoothness: .standard),
            factory: SVGGlyphFactory(
                cropRect: CGRect(x: 0, y: 0, width: 200, height: 200),
                screenSize: DeviceGeometry.screenPixelSize
            )
        )
        let familyBase = "MProbe\(UInt32.random(in: 100_000 ... 999_999))"
        let data = try builder.font(
            lane: 0,
            familyBase: familyBase,
            encodedFrames: (0 ..< 4).map { Data("frame-\($0)".utf8).base64EncodedString() }
        )
        let name = LaneFontBuilder.postScriptName(family: familyBase, lane: 0)
        let url = (directory ?? scratch).appendingPathComponent("\(name).ttf")
        try data.write(to: url)
        return PersistentFontProbe.Candidate(url: url, postScriptName: name, location: location)
    }

    private func attempt(_ route: PersistentFontProbe.Route, in directory: URL? = nil, location: String = "container") throws -> PersistentFontProbe.Attempt {
        PersistentFontProbe.attempt(route: route, candidate: try makeCandidate(in: directory, location: location))
    }

    /// The generated font has to be sound, or every result below could just be
    /// CoreText rejecting bad bytes.
    func testTheProbeFontIsValidAndUsableInProcess() throws {
        let candidate = try makeCandidate()
        var error: Unmanaged<CFError>?
        XCTAssertTrue(
            CTFontManagerRegisterFontsForURL(candidate.url as CFURL, .process, &error),
            "process scope refused the probe font, so it is not a valid control: \(String(describing: error?.takeRetainedValue()))"
        )
        XCTAssertTrue(
            PersistentFontProbe.resolves(candidate.postScriptName),
            "the probe font registered but its PostScript name does not resolve"
        )
        var unregisterError: Unmanaged<CFError>?
        CTFontManagerUnregisterFontsForURL(candidate.url as CFURL, .process, &unregisterError)
    }

    /// This settles the previously unexplained CoreText error 307. It is
    /// `kCTFontManagerErrorUnsupportedScope`, and CoreText logs the reason in
    /// as many words: "kCTFontManagerScopePersistent is not supported by this
    /// function. Use API with registrationHandler block parameter."
    ///
    /// So 307 was never about an entitlement, an `Info.plist` key or a missing
    /// extension target. It was the wrong function. `CTFontManagerRegisterFontsForURL`
    /// is the 2010 API and has no persistent scope on iOS at all.
    func testLegacyURLRegistrationRejectsPersistentScopeOutright() throws {
        let attempt = try attempt(.registerFontsForURL)

        XCTAssertFalse(attempt.succeeded, "persistent scope was accepted: \(attempt)")
        XCTAssertEqual(
            attempt.errorCode,
            Int(CTFontManagerError.unsupportedScope.rawValue),
            "expected 307 unsupportedScope, got \(attempt)"
        )
        XCTAssertEqual(attempt.errorCode, 307, "the error code that has to be quoted with this finding")
        XCTAssertFalse(attempt.resolvedAfterRegister)
    }

    /// The iOS 13 API does honour the scope, and in the simulator it accepts a
    /// file the app wrote outside any bundle.
    ///
    /// That acceptance is exactly the simulator being permissive, and must not
    /// be read as the route working: CoreText documents the location rule this
    /// bypasses as `kCTFontManagerErrorInvalidFilePath` (306), "the file is not
    /// in an allowed location. It must be either in the application's bundle or
    /// an on-demand resource". Both of those are sealed at install time, so a
    /// font generated from a user's video is in neither, on a phone.
    ///
    /// This also explains the previously puzzling result that the same call
    /// "reports success and never resolves" on a phone: success here is the
    /// simulator skipping the location check, and the phone applying it while
    /// still reporting through a handler that is easy to read as a pass.
    func testModernURLRegistrationIsTheOnlyRouteThatHonoursTheScope() throws {
        let attempt = try attempt(.registerFontURLs)

        XCTAssertTrue(
            attempt.succeeded,
            "the simulator stopped accepting this; check whether the device now behaves the same: \(attempt)"
        )
        XCTAssertTrue(attempt.resolvedAfterRegister, "registration succeeded but the font did not arrive: \(attempt)")
    }

    /// Registering by descriptor cannot work at all, and the reason is
    /// mechanical rather than a permission: descriptors built from raw font
    /// data carry no file, and persistent scope needs one. 303 is
    /// `kCTFontManagerErrorInsufficientInfo`, "the font descriptor does not
    /// have information to specify a font file".
    func testDescriptorRegistrationHasNoFileToInstall() throws {
        let attempt = try attempt(.registerFontDescriptors)

        XCTAssertFalse(attempt.succeeded, "descriptor registration installed a runtime font: \(attempt)")
        XCTAssertEqual(
            attempt.errorCode,
            Int(CTFontManagerError.insufficientInfo.rawValue),
            "expected 303 insufficientInfo, got \(attempt)"
        )
        XCTAssertFalse(attempt.resolvedAfterRegister, "descriptor registration failed but the name resolved: \(attempt)")
    }

    /// The sanctioned iOS 13 route reads from an asset catalog, not a path, so
    /// there is nowhere to put bytes produced after the app was built. 107 is
    /// `kCTFontManagerErrorAssetNotFound`, "the font resource could not be
    /// found in an asset catalog".
    func testAssetNameRegistrationNeedsAnAssetCatalogEntry() throws {
        let attempt = try attempt(.registerFontsWithAssetNames)

        XCTAssertFalse(attempt.succeeded, "an asset name that was never built resolved: \(attempt)")
        XCTAssertEqual(
            attempt.errorCode,
            Int(CTFontManagerError.assetNotFound.rawValue),
            "expected 107 assetNotFound, got \(attempt)"
        )
    }

    /// The persistent registry only ever describes the process asking.
    ///
    /// CoreText documents this directly: "in the case the persistent scope is
    /// specified, only macOS can return fonts registered by any process. Other
    /// platforms can only return font descriptors registered by the
    /// application's process." So a font showing up here is this process's own
    /// bookkeeping and says nothing about sharing - which is exactly why the
    /// cross-process question has to be asked from a second process, and is, in
    /// `PersistentFontCrossProcessTests`.
    func testThePersistentRegistryOnlyDescribesTheCallingProcess() throws {
        let mine = try makeCandidate()
        let attempt = PersistentFontProbe.attempt(route: .registerFontURLs, candidate: mine)
        XCTAssertTrue(attempt.succeeded, "precondition: registration was expected to succeed here")
        XCTAssertTrue(
            PersistentFontProbe.persistentlyRegisteredNames().contains(mine.postScriptName),
            "this process's own persistent registration is not in its own registry: \(attempt)"
        )

        // Registered but never installed by anyone, so if this appeared it
        // would have to have come from elsewhere.
        let stranger = try makeCandidate()
        XCTAssertFalse(
            PersistentFontProbe.persistentlyRegisteredNames().contains(stranger.postScriptName),
            "the registry reports a font no process here installed"
        )
    }

    /// Every route at once, for the record that gets quoted.
    func testEveryPersistentRouteIsRecorded() throws {
        let attempts = try PersistentFontProbe.probeAllRoutes { _ in try makeCandidate() }

        XCTAssertEqual(attempts.count, PersistentFontProbe.Route.allCases.count)
        XCTAssertEqual(
            attempts.filter(\.succeeded).map(\.route),
            [.registerFontURLs],
            "the set of routes that honour persistent scope changed: \(attempts.map(\.description))"
        )
        for attempt in attempts {
            XCTContext.runActivity(named: attempt.route.rawValue) { activity in
                activity.add(XCTAttachment(string: attempt.description))
            }
        }
    }
}
