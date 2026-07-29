import CoreText
import Foundation
import os

/// Asks CoreText why a font the app wrote at runtime cannot be installed into
/// the user's font library.
///
/// Installing system-wide is the only documented route by which a font that was
/// not in a bundle at install time becomes visible to another process, and the
/// widget is rasterised by another process (`WidgetRenderer_Default`). Every
/// scope-`.process` route reaches the extension and stops there. So the
/// question is not "does registration succeed" but "does a persistent
/// registration cross a process boundary", and the answer wanted is a
/// `CTFontManagerError` code rather than a recollection - hence this probe.
///
/// The answer, so nobody has to re-derive it: **this route is closed**, and it
/// is closed three times over.
///
/// 1. *The gate is an entitlement.* Registering from the app's own bundle
///    fails with 302 `missingEntitlement`; `fontservicesd` logs "Application
///    does not have an entitlement to use custom fonts" and names
///    `com.apple.developer.user-fonts`, whose values are `system-installation`
///    and `app-usage` (Xcode's Fonts capability: "Install Fonts" and "Use
///    Installed Fonts"). It is self-serve, so this one is fixable.
/// 2. *But the fonts may not be ours.* Apple: "You must store installable
///    fonts in the app bundle or deliver them using On-Demand Resources,
///    because the system prohibits an app from installing arbitrary fonts."
///    WWDC19 session 227 says it again: "The OS will not let a font provider
///    application install any arbitrary fonts." A font built on the phone from
///    a user's video is the arbitrary case, and both permitted locations are
///    sealed when the app is signed. `kCTFontManagerErrorInvalidFilePath` (306)
///    is what a phone returns for it. This one is not fixable.
/// 3. *And installing would not reach the renderer anyway.* CoreText: "In iOS,
///    fonts registered with the persistent scope are not automatically
///    available to other processes. Other process may call
///    `CTFontManagerRequestFonts` to get access to these fonts." That call
///    needs the consumer's own `app-usage` entitlement and puts a dialog in
///    front of the user. The rasterising process is `WidgetRenderer_Default`,
///    a system process that will never call it. Also not fixable.
///
/// So the old measurements were right but misread. 307 was not a permissions
/// problem at all - see `Route.registerFontsForURL` - and the entitlement that
/// 302 asks for cannot buy what the widget needs.
///
/// What the simulator settled and what it did not: it settled the error codes
/// and the entitlement name, which are the same binary logic everywhere. It
/// cannot settle point 2, because it does not enforce the location rule -
/// `xctest` registers a font from a temporary directory quite happily. Any
/// success recorded here is therefore not evidence about a phone; only the
/// refusals are.
///
/// It is diagnostic only. Nothing in the shipping path calls it.
enum PersistentFontProbe {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "PersistentFontProbe")

    /// How long to wait on the block-based APIs before calling them hung. They
    /// are asynchronous and may invoke the handler more than once, so "no
    /// answer" has to be distinguishable from "refused".
    private static let handlerTimeout: TimeInterval = 20

    enum Route: String, CaseIterable, Sendable {
        /// The 2010-era API. Predates the persistent scope on iOS entirely.
        case registerFontsForURL
        /// The iOS 13 replacement, and the only URL-taking API documented to
        /// support persistent scope on iOS.
        case registerFontURLs
        /// The same scope reached through a descriptor rather than a path, in
        /// case the path is what is being rejected.
        case registerFontDescriptors
        /// The sanctioned iOS 13 path, which reads from an asset catalog
        /// rather than a path - included to show what it demands.
        case registerFontsWithAssetNames

        var detail: String {
            switch self {
            case .registerFontsForURL: "CTFontManagerRegisterFontsForURL(url, .persistent)"
            case .registerFontURLs: "CTFontManagerRegisterFontURLs([url], .persistent, enabled: true)"
            case .registerFontDescriptors: "CTFontManagerRegisterFontDescriptors([desc], .persistent, enabled: true)"
            case .registerFontsWithAssetNames: "CTFontManagerRegisterFontsWithAssetNames([name], bundle, .persistent, enabled: true)"
            }
        }
    }

    /// One font file, already written, with the name it should answer to.
    struct Candidate: Sendable {
        let url: URL
        let postScriptName: String
        /// A label for the report, e.g. "app group" or "bundle".
        let location: String
    }

    struct Attempt: Sendable, CustomStringConvertible {
        let route: Route
        let location: String
        let postScriptName: String
        let succeeded: Bool
        /// The `CTFontManagerError` raw value, when CoreText gave one.
        let errorCode: Int?
        let errorName: String
        let message: String
        /// Whether the name resolves in *this* process straight after
        /// registering. Registration reporting success is not the same as the
        /// font having arrived.
        let resolvedAfterRegister: Bool
        /// Whether it resolves after `CTFontManagerRequestFonts`, which is what
        /// CoreText documents a process must call to reach fonts another
        /// process installed persistently.
        let resolvedAfterRequest: Bool
        /// Whether the persistent registry admits to holding it.
        let listedInPersistentRegistry: Bool

        var description: String {
            let verdict = succeeded ? "accepted" : "refused"
            let code = errorCode.map { "\($0) \(errorName)" } ?? errorName
            return """
            \(route.rawValue) @ \(location): \(verdict) [\(code)] \
            resolved=\(resolvedAfterRegister) afterRequest=\(resolvedAfterRequest) \
            listed=\(listedInPersistentRegistry) - \(message)
            """
        }
    }

    /// Runs every persistent-scope route, each against a font of its own.
    ///
    /// A separate font per route is not tidiness: a route that succeeds
    /// registers a PostScript name, and every later route asked about that same
    /// name then reports it resolving whether or not that route did anything.
    /// Sharing one font makes the whole probe agree with its first success.
    static func probeAllRoutes(makeCandidate: (Route) throws -> Candidate) rethrows -> [Attempt] {
        try Route.allCases.map { route in
            let candidate = try makeCandidate(route)
            let attempt = attempt(route: route, candidate: candidate)
            logger.info("\(attempt.description, privacy: .public)")
            return attempt
        }
    }

    /// - Parameter requestingIfAbsent: whether to follow a failed resolution
    ///   with `CTFontManagerRequestFonts`. Off for anything on a launch path:
    ///   that call waits on a user dialog, and with no scene on screen yet it
    ///   never completes at all, so the app sits blocked until the launch
    ///   watchdog kills it.
    static func attempt(route: Route, candidate: Candidate, requestingIfAbsent: Bool = true) -> Attempt {
        let (succeeded, error, note): (Bool, CFError?, String)
        switch route {
        case .registerFontsForURL:
            (succeeded, error, note) = registerFontsForURL(candidate.url)
        case .registerFontURLs:
            (succeeded, error, note) = registerFontURLs(candidate.url)
        case .registerFontDescriptors:
            (succeeded, error, note) = registerFontDescriptors(candidate.url)
        case .registerFontsWithAssetNames:
            (succeeded, error, note) = registerFontsWithAssetNames(candidate.postScriptName)
        }

        let code = error.map { ($0 as Error as NSError).code }
        let resolvedAfterRegister = resolves(candidate.postScriptName)
        return Attempt(
            route: route,
            location: candidate.location,
            postScriptName: candidate.postScriptName,
            succeeded: succeeded,
            errorCode: code,
            errorName: code.map(name(for:)) ?? (succeeded ? "none" : "no error reported"),
            message: error.map { CFErrorCopyDescription($0) as String } ?? note,
            resolvedAfterRegister: resolvedAfterRegister,
            resolvedAfterRequest: resolvedAfterRegister
                || (requestingIfAbsent && requestFonts(named: candidate.postScriptName)),
            listedInPersistentRegistry: persistentlyRegisteredNames().contains(candidate.postScriptName)
        )
    }

    // MARK: - Routes

    private static func registerFontsForURL(_ url: URL) -> (Bool, CFError?, String) {
        var error: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .persistent, &error)
        return (ok, error?.takeRetainedValue(), ok ? "registered" : "returned false")
    }

    private static func registerFontURLs(_ url: URL) -> (Bool, CFError?, String) {
        awaitHandler { handler in
            CTFontManagerRegisterFontURLs([url] as CFArray, .persistent, true, handler)
        }
    }

    private static func registerFontDescriptors(_ url: URL) -> (Bool, CFError?, String) {
        guard let data = try? Data(contentsOf: url) else {
            return (false, nil, "could not read \(url.lastPathComponent)")
        }
        let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData)
        guard CFArrayGetCount(descriptors) > 0 else {
            return (false, nil, "no descriptors could be made from the font data")
        }
        return awaitHandler { handler in
            CTFontManagerRegisterFontDescriptors(descriptors, .persistent, true, handler)
        }
    }

    private static func registerFontsWithAssetNames(_ assetName: String) -> (Bool, CFError?, String) {
        awaitHandler { handler in
            CTFontManagerRegisterFontsWithAssetNames([assetName] as CFArray, nil, .persistent, true, handler)
        }
    }

    // MARK: - Cross-process check

    /// The launch argument that makes the app install one of its own bundled
    /// fonts persistently, so a second process can be asked whether it sees it.
    /// Takes the resource's file name, then the PostScript name to resolve -
    /// the two differ, and assuming they matched once made this whole probe
    /// report a clean negative while installing nothing at all.
    static let installArgument = "-MotionaryPersistentInstall"

    /// What the launch-time install did, so a UI test in another process can
    /// read it back off the screen and check the install it is disproving
    /// actually happened.
    nonisolated(unsafe) private(set) static var lastInstall: Attempt?

    /// The same bytes offered from a directory the app wrote, rather than from
    /// the bundle. Two attempts differing only in the file's whereabouts is the
    /// only way to show that the whereabouts is what CoreText objects to.
    nonisolated(unsafe) private(set) static var lastCopyInstall: Attempt?

    /// Identifies the label carrying `lastInstall`, for XCUITest.
    static let resultAccessibilityIdentifier = "persistentFontProbeResult"

    /// Installs a font from the calling bundle into the persistent scope.
    ///
    /// Bundled on purpose. CoreText restricts this scope to files "in the
    /// application's bundle or an on-demand resource", so using a bundled font
    /// removes the location objection entirely and leaves only the question
    /// that matters: whether a persistent install is visible anywhere else.
    /// If it is not even for a font in the one permitted location, then getting
    /// a generated font into that location would not have helped either.
    @discardableResult
    static func installBundledFont(resource: String, postScriptName: String) -> Attempt? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "ttf")
            ?? Bundle.main.url(forResource: resource, withExtension: "otf")
        else {
            logger.error("no bundled font named \(resource, privacy: .public); nothing was installed")
            lastInstall = nil
            return nil
        }
        // The copy goes first, deliberately. Both attempts use the same
        // PostScript name, and whichever registers first owns it - so running
        // the bundle first would leave the copy reporting `alreadyRegistered`
        // or `duplicatedName` and prove nothing about its location.
        lastCopyInstall = installCopyOutsideBundle(of: url, postScriptName: postScriptName)
        let attempt = attempt(
            route: .registerFontURLs,
            candidate: Candidate(url: url, postScriptName: postScriptName, location: "app bundle"),
            requestingIfAbsent: false
        )
        logger.info("persistent install: \(attempt.description, privacy: .public)")
        lastInstall = attempt
        return attempt
    }

    /// Offers byte-identical font data from the app's Caches instead of its
    /// bundle. A font Motionary generates from a video lands somewhere like
    /// this, so whatever CoreText says here is what it would say about a real
    /// generated font - with the font itself held constant.
    private static func installCopyOutsideBundle(of url: URL, postScriptName: String) -> Attempt? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let copy = caches.appendingPathComponent("probe-copy-\(url.lastPathComponent)")
        do {
            if FileManager.default.fileExists(atPath: copy.path) {
                try FileManager.default.removeItem(at: copy)
            }
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            logger.error("could not stage a copy at \(copy.path, privacy: .public): \(error, privacy: .public)")
            return nil
        }
        let attempt = attempt(
            route: .registerFontURLs,
            candidate: Candidate(url: copy, postScriptName: postScriptName, location: "app caches"),
            requestingIfAbsent: false
        )
        logger.info("persistent install (copy): \(attempt.description, privacy: .public)")
        return attempt
    }

    /// nil when the launch arguments say nothing about it.
    @discardableResult
    static func installBundledFontIfRequested(arguments: [String]) -> Attempt? {
        guard let flag = arguments.firstIndex(of: installArgument),
              let resource = arguments[safe: flag + 1],
              let postScriptName = arguments[safe: flag + 2]
        else { return nil }
        return installBundledFont(resource: resource, postScriptName: postScriptName)
    }

    // MARK: - Reaching a font another process installed

    /// The documented way for a process to reach fonts installed persistently
    /// by a font provider app. On iOS it may put a dialog in front of the user,
    /// which is by itself the reason this cannot be part of a widget render.
    @discardableResult
    static func requestFonts(named postScriptName: String) -> Bool {
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontNameAttribute: postScriptName] as CFDictionary
        )
        let finished = DispatchSemaphore(value: 0)
        CTFontManagerRequestFonts([descriptor] as CFArray) { _ in finished.signal() }
        if finished.wait(timeout: .now() + handlerTimeout) == .timedOut {
            logger.error("CTFontManagerRequestFonts never completed for \(postScriptName, privacy: .public)")
            return false
        }
        return resolves(postScriptName)
    }

    // MARK: - Plumbing

    /// Drives one of the block-based registration APIs to completion.
    ///
    /// The handler can fire several times and only the call with `done` set
    /// ends the operation, so the first error has to be kept rather than the
    /// last, and a timeout has to be a reportable result of its own.
    private static func awaitHandler(
        _ body: (@escaping (CFArray, Bool) -> Bool) -> Void
    ) -> (Bool, CFError?, String) {
        let finished = DispatchSemaphore(value: 0)
        let lock = NSLock()
        nonisolated(unsafe) var firstError: CFError?
        nonisolated(unsafe) var sawError = false

        body { errors, done in
            if CFArrayGetCount(errors) > 0 {
                lock.lock()
                sawError = true
                if firstError == nil {
                    firstError = CFArrayGetValueAtIndex(errors, 0).map {
                        Unmanaged<CFError>.fromOpaque($0).takeUnretainedValue()
                    }
                }
                lock.unlock()
            }
            if done { finished.signal() }
            return true
        }

        if finished.wait(timeout: .now() + handlerTimeout) == .timedOut {
            return (false, nil, "handler never reported done within \(Int(handlerTimeout))s")
        }
        lock.lock()
        let error = firstError
        let failed = sawError
        lock.unlock()
        return (!failed, error, failed ? "handler reported errors" : "handler reported no errors")
    }

    static func resolves(_ postScriptName: String) -> Bool {
        let font = CTFontCreateWithName(postScriptName as CFString, 12, nil)
        return CTFontCopyPostScriptName(font) as String == postScriptName
    }

    /// What is in the persistent registry as far as this process can tell.
    ///
    /// CoreText documents that on iOS this only ever reports what the calling
    /// process registered, which is itself the answer to whether persistent
    /// scope crosses a process boundary.
    static func persistentlyRegisteredNames() -> [String] {
        let descriptors = CTFontManagerCopyRegisteredFontDescriptors(.persistent, true)
        return (0 ..< CFArrayGetCount(descriptors)).compactMap { index in
            guard let raw = CFArrayGetValueAtIndex(descriptors, index) else { return nil }
            let descriptor = Unmanaged<CTFontDescriptor>.fromOpaque(raw).takeUnretainedValue()
            return CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
        }
    }

    static func name(for code: Int) -> String {
        switch CTFontManagerError(rawValue: CFIndex(code)) {
        case .fileNotFound: "fileNotFound"
        case .insufficientPermissions: "insufficientPermissions"
        case .unrecognizedFormat: "unrecognizedFormat"
        case .invalidFontData: "invalidFontData"
        case .alreadyRegistered: "alreadyRegistered"
        case .exceededResourceLimit: "exceededResourceLimit"
        case .assetNotFound: "assetNotFound"
        case .notRegistered: "notRegistered"
        case .inUse: "inUse"
        case .systemRequired: "systemRequired"
        case .registrationFailed: "registrationFailed"
        case .missingEntitlement: "missingEntitlement"
        case .insufficientInfo: "insufficientInfo"
        case .cancelledByUser: "cancelledByUser"
        case .duplicatedName: "duplicatedName"
        case .invalidFilePath: "invalidFilePath"
        case .unsupportedScope: "unsupportedScope"
        default: "unknown(\(code))"
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
