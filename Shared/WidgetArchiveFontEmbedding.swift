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
// FAILURE MODE, stated plainly: these are strong undefined symbols. If Apple
// ever stops exporting them, the widget extension fails to bind at launch and
// dies in dyld - it does not fall back to a static widget.
extension EnvironmentValues {
    @_silgen_name("$s7SwiftUI17EnvironmentValuesV9WidgetKitE34_wantsCustomFontsEmbeddedInArchiveSbvs")
    mutating func _setWantsCustomFontsEmbeddedInArchive(_ newValue: Bool)

    @_silgen_name("$s7SwiftUI17EnvironmentValuesV9WidgetKitE34_wantsCustomFontsEmbeddedInArchiveSbvg")
    func _getWantsCustomFontsEmbeddedInArchive() -> Bool
}

/// Asks WidgetKit to archive custom font data inline instead of by reference.
///
/// Every runtime font-delivery route measured so far fails in one of two places,
/// and this switch is upstream of both: `RegisterGraphicsFont` and a raw
/// `CTFont` have no URL to write and so fail while *encoding*, inside the
/// extension; an App Group URL encodes fine and then fails while *decoding*,
/// because `chronod` does not inherit the extension's App Group sandbox grant.
/// Embedding the bytes removes the reference that both failures are about.
///
/// Off by default. On device this is the only thing standing between "a design
/// must be compiled into the extension on a Mac" and "a design can be built on
/// the phone", so it is worth having; but it is private API driving the archive
/// format, and a bad archive takes the whole widget black rather than degrading.
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

    /// Whether WidgetKit still exports the accessors this file links against.
    ///
    /// Diagnostic only. By the time this can be called the process has already
    /// survived dyld, so a `false` here would mean the symbols were resolved
    /// some other way, not that the flag is safely unavailable.
    static var isSymbolPresent: Bool {
        let name = "$s7SwiftUI17EnvironmentValuesV9WidgetKitE34_wantsCustomFontsEmbeddedInArchiveSbvs"
        return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) != nil
    }

    /// Set and read the flag back inside a real SwiftUI environment, reporting
    /// whether the value stuck.
    ///
    /// Takes a closure-shaped detour through an actual view render because a
    /// default-constructed `EnvironmentValues` is not a safe subject: SwiftUI's
    /// storage is empty there and the accessors are not defensive about it. The
    /// only environment worth asking is one SwiftUI itself produced.
    @MainActor
    static func roundTripsInARealRender() -> Bool {
        var observed = false
        let probe = Color.clear.transformEnvironment(\.self) { env in
            env._setWantsCustomFontsEmbeddedInArchive(true)
            observed = env._getWantsCustomFontsEmbeddedInArchive()
        }
        let renderer = ImageRenderer(content: probe.frame(width: 4, height: 4))
        _ = renderer.uiImage
        return observed
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
    /// would not be seen when that font is encoded.
    @ViewBuilder
    func embeddingCustomFontsInArchive(_ enabled: Bool = true) -> some View {
        if enabled {
            transformEnvironment(\.self) { env in
                env._setWantsCustomFontsEmbeddedInArchive(true)
            }
        } else {
            self
        }
    }
}
