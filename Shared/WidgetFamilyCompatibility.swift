import Foundation
import WidgetKit

/// Bridges iOS 27's tall portrait widget family while the project is compiled
/// by Xcode 26, whose SDK declares the case but marks its iOS spelling
/// unavailable. The runtime raw representation is the same on both.
enum WidgetFamilyCompatibility {
    static let portraitExtraLargeRawValue = 4

    static func portraitFamily(
        operatingSystemMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) -> WidgetFamily? {
#if compiler(>=6.4)
        if operatingSystemMajorVersion >= 27 {
            if #available(iOS 27.0, *) {
                return .systemExtraLargePortrait
            }
        }
        return nil
#else
        guard operatingSystemMajorVersion >= 27 else { return nil }
        return WidgetFamily(rawValue: portraitExtraLargeRawValue)
#endif
    }

    /// The only family the extension advertises.
    ///
    /// Offering several meant a design cut for one shape could be dropped into
    /// another, and on iOS 27 the family enum cannot even be trusted to say
    /// which: one physical widget reported both `systemLarge` and
    /// `systemMedium` while rendering at an identical size. With a single
    /// advertised family the rendered size is known in advance and there is
    /// nothing left to mismatch.
    ///
    /// Older systems get `systemLarge`, matching the Onewheel build: a widget
    /// must advertise at least one family, and the composition scales to fit.
    static func supportedFamilies() -> [WidgetFamily] {
        guard let portrait = portraitFamily() else { return [.systemLarge] }
        return [portrait]
    }

    /// Whether this build can offer the tall portrait family at all. The editor
    /// says so plainly rather than letting a design be cut for a family the
    /// device will never render.
    static var supportsFullScreen: Bool { portraitFamily() != nil }
}
