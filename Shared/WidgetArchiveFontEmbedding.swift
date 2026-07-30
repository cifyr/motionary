import Darwin
import Foundation
import SwiftUI
import WidgetKit
import os

// MARK: - Private WidgetKit symbols

// PRIVATE API. `_wantsCustomFontsEmbeddedInArchive` is a WidgetKit-only
// environment value that decides whether the view archive carries custom font
// *bytes* or merely a file URL. It is the switch behind
// `SwiftUI.ArchivedViewInput.Flags.customFontURLs` and
// `WidgetKit.ViewStatesArchiver.encodesCustomFontsAsURLs`.
//
// It has never been public. Checked against the shipped
// WidgetKit.swiftinterface for iOS 14.5, 15.6 and 26.5: absent from all three,
// while `_clockHandRotationEffect` is present and public in 14.5 and 15.6. So
// the vendored-old-SDK-xcframework trick that makes the clock-hand modifier
// callable without any linker games does *not* apply here - there is no SDK in
// which this was a public declaration. All four accessors are exported from
// WidgetKit.tbd, so the linker can reach it even though the Swift front end
// refuses `\._wantsCustomFontsEmbeddedInArchive` as a key path.
//
// DECLARED AS METHODS ON PURPOSE, and this is the whole difficulty. A property
// accessor uses Swift's method convention, which passes `self` in the dedicated
// self register. Declaring these as free functions taking `inout
// EnvironmentValues` - the obvious shape - links fine and then corrupts memory,
// because a free function passes `self` as an ordinary argument. Measured: the
// free-function version segfaults inside
// `SwiftUICore.EnvironmentValues.subscript.getter`, both on a synthetic
// `EnvironmentValues` and inside a real `transformEnvironment` during a real
// render. Worse, one call order appeared to work and round-trip `true` - both
// shims agreeing on the same wrong `self`, reading and writing a location that
// was not the environment at all. Declaring them in an extension makes the
// compiler emit the method convention and the calls become correct.
//
// A `dlsym` plus `@convention(c)` version also segfaults, for the same reason
// plus the C convention's different handling of the struct.
//
// FAILURE MODE, stated as measured. Declared this way these are *strong*
// undefined symbols bound two-level to WidgetKit: `nm -m` on the built extension
// reports "(undefined) external ... (from WidgetKit)". An OS that stopped
// exporting them would therefore kill the extension in dyld at launch rather
// than degrade, and `-Xlinker -U` does NOT change that - it permits a symbol to
// be missing at *link* time, and leaves a found symbol strongly bound. That was
// checked, not assumed.
//
// So the risk is removed by not linking them unless asked. The shim exists only
// under `FONT_EMBED_PROBE`, which the unit tests and `Tools/font-embed-shot.sh`
// set and an ordinary build does not - a shipped widget extension contains no
// reference to either accessor. `-U` is still passed so that the probe keeps
// building against a future SDK that has dropped them, and every call is gated
// on `isSymbolPresent` so a null stub is never jumped to.
#if FONT_EMBED_PROBE
extension EnvironmentValues {
    @_silgen_name("$s7SwiftUI17EnvironmentValuesV9WidgetKitE34_wantsCustomFontsEmbeddedInArchiveSbvs")
    mutating func _setWantsCustomFontsEmbeddedInArchive(_ newValue: Bool)

    @_silgen_name("$s7SwiftUI17EnvironmentValuesV9WidgetKitE34_wantsCustomFontsEmbeddedInArchiveSbvg")
    func _getWantsCustomFontsEmbeddedInArchive() -> Bool
}
#endif

/// Asks WidgetKit to archive custom font data inline instead of by reference.
///
/// MEASURED, AND IT DOES NOT WORK. Setting this flag changes nothing about a
/// Home Screen widget's archived timeline. With one runtime-registered lane font
/// in the tree, the archive is the same size with the flag off and on (12,200
/// bytes both ways) and still carries the font as
/// `file://...app-group.../MLabGroupProcess.ttf#postscript-name=...` with no
/// sfnt bytes anywhere in the extension's container. The flag was verified to be
/// `true` in the environment at the same time, at the root of the archived tree
/// and again at the font's own use site, and the detector was proved on the same
/// archive with a real 994,891-byte font appended.
/// See `Tools/font-embed-shot.sh` and `docs/widget-animation-surface.md` §6.3.
///
/// Kept as a probe, not a route. It stays off, it is compiled in only under
/// `FONT_EMBED_PROBE`, and the reason to keep it is that it is the one thing that
/// would tell us cheaply if a future iOS changed its mind.
enum WidgetArchiveFontEmbedding {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "FontEmbedding")
    private static let flagKey = "widgetArchiveFontEmbedding"

    static var isEnabled: Bool {
        get { UserDefaults(suiteName: DesignStore.appGroupIdentifier)?.bool(forKey: flagKey) ?? false }
        set {
            UserDefaults(suiteName: DesignStore.appGroupIdentifier)?.set(newValue, forKey: flagKey)
            logger.info("archive font embedding \(newValue ? "on" : "off")")
        }
    }

    /// Lets a test run switch the flag without anyone tapping a toggle, matching
    /// how the font lab is driven.
    static func launchOverride(in arguments: [String]) -> Bool? {
        if arguments.contains("-MotionaryFontEmbeddingOn") { return true }
        if arguments.contains("-MotionaryFontEmbeddingOff") { return false }
        return nil
    }

    /// Whether this build carries the private-symbol shim at all.
    ///
    /// False in a shipped build. The point of saying so out loud is that
    /// `isEnabled` being true means nothing without this being true too, and a
    /// run that flipped the flag and saw no change would otherwise be reported as
    /// evidence about WidgetKit when it was evidence about the build.
    static var isLinked: Bool {
        #if FONT_EMBED_PROBE
        true
        #else
        false
        #endif
    }

    /// Whether WidgetKit still exports the accessors the shim calls.
    ///
    /// This is the guard, not a diagnostic: the symbols are resolved at launch
    /// and a future OS that dropped them would leave a null stub behind, so every
    /// call site asks this first rather than jumping to it.
    ///
    /// Resolved once, because the answer cannot change inside a process and the
    /// question would otherwise be asked on every render.
    static let isSymbolPresent: Bool = {
        let setter = "$s7SwiftUI17EnvironmentValuesV9WidgetKitE34_wantsCustomFontsEmbeddedInArchiveSbvs"
        let getter = "$s7SwiftUI17EnvironmentValuesV9WidgetKitE34_wantsCustomFontsEmbeddedInArchiveSbvg"
        // RTLD_DEFAULT. Both, because the shim calls both and one of them being
        // present says nothing about the other.
        let handle = UnsafeMutableRawPointer(bitPattern: -2)
        return dlsym(handle, setter) != nil && dlsym(handle, getter) != nil
    }()

    /// Set and read the flag back inside a real SwiftUI environment, reporting
    /// whether the value stuck.
    ///
    /// Takes a closure-shaped detour through an actual view render because a
    /// default-constructed `EnvironmentValues` is not a safe subject: SwiftUI's
    /// storage is empty there and the accessors are not defensive about it. The
    /// only environment worth asking is one SwiftUI itself produced.
    @MainActor
    static func roundTripsInARealRender() -> Bool {
        #if FONT_EMBED_PROBE
        guard isSymbolPresent else { return false }
        var observed = false
        let probe = Color.clear.transformEnvironment(\.self) { env in
            env._setWantsCustomFontsEmbeddedInArchive(true)
            observed = env._getWantsCustomFontsEmbeddedInArchive()
        }
        let renderer = ImageRenderer(content: probe.frame(width: 4, height: 4))
        _ = renderer.uiImage
        return observed
        #else
        return false
        #endif
    }

    /// What the flag read back as, the last time the widget's own tree set it.
    ///
    /// The set is not the finding. A shim with the wrong calling convention has
    /// already round-tripped a `true` that was never in the environment, and a
    /// flag that does nothing looks exactly like a flag that was never set - so
    /// the widget reads it back from the environment it just wrote, inside the
    /// render being archived, and says so in the log.
    nonisolated(unsafe) private(set) static var lastObserved: Bool?

    /// So a test can tell "the guard held" apart from "an earlier case had
    /// already set this".
    static func resetLastObservedForTesting() { lastObserved = nil }

    /// Written to a file of its own rather than appended to the render log.
    /// `WidgetRenderLog.append` rewrites the whole file after reading it, so a
    /// line written from inside a render closure can be lost to a line written
    /// from the render around it - and "the line is missing" is exactly the
    /// finding this has to be able to report.
    static let observationFilename = "font-embed-observed.txt"

    static func note(observed: Bool) {
        lastObserved = observed
        guard let store = try? DesignStore() else { return }
        let url = store.root.deletingLastPathComponent()
            .appendingPathComponent(observationFilename)
        let text = "set=true observed=\(observed) symbol=\(isSymbolPresent) at \(Date())"
        do {
            try Data(text.utf8).write(to: url, options: DesignStore.writingOptions)
        } catch {
            logger.error("could not record the observation: \(String(describing: error), privacy: .public)")
        }
    }
}

extension View {
    /// Sets the private embedding flag on this subtree's environment.
    ///
    /// `transformEnvironment(\.self)` is the way in: the flag has no public key
    /// path, but `\.self` is a perfectly ordinary `WritableKeyPath`, and the
    /// setter can be applied to the whole `EnvironmentValues` value once we hold
    /// it `inout`.
    ///
    /// Apply it as high in the archived tree as possible - the outermost view the
    /// widget's content closure returns. The archiver resolves each node's
    /// environment while walking the tree, so a flag set below a font's use site
    /// would not be seen when that font is encoded. It is also applied directly
    /// around the font's use site, because "the flag was set too high up" and
    /// "the flag does nothing" are otherwise the same observation.
    ///
    /// A no-op outside a `FONT_EMBED_PROBE` build, which is every shipped build.
    ///
    /// `symbolPresent` is a parameter only so a test can take the absent case;
    /// nothing else should pass it.
    @ViewBuilder
    func embeddingCustomFontsInArchive(
        _ enabled: Bool = true,
        symbolPresent: Bool = WidgetArchiveFontEmbedding.isSymbolPresent
    ) -> some View {
        #if FONT_EMBED_PROBE
        // The symbol condition is not belt-and-braces. These are strong bindings
        // resolved at launch, so an OS that dropped them leaves a null stub, and
        // an unguarded call would take the whole widget extension down.
        if enabled && symbolPresent {
            transformEnvironment(\.self) { env in
                env._setWantsCustomFontsEmbeddedInArchive(true)
                WidgetArchiveFontEmbedding.note(
                    observed: env._getWantsCustomFontsEmbeddedInArchive()
                )
            }
        } else {
            self
        }
        #else
        self
        #endif
    }
}
