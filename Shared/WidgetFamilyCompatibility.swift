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

    /// Families the extension advertises. The tall portrait family is appended
    /// only where the running system has it, so older systems see the large
    /// square instead of an entry that renders blank.
    static func supportedFamilies() -> [WidgetFamily] {
        var families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge]
        if let portrait = portraitFamily() {
            families.append(portrait)
        }
        return families
    }

    /// Maps a rendered family back to the design size it should crop for.
    static func sizeOption(for family: WidgetFamily) -> WidgetSizeOption {
        if family.rawValue == portraitExtraLargeRawValue { return .fullScreen }
        switch family {
        case .systemSmall: return .small
        case .systemMedium: return .medium
        default: return .large
        }
    }

    /// Whether this build can offer the full-screen size at all. The editor
    /// greys the option out rather than letting a design be cut for a family
    /// the device will never render.
    static var supportsFullScreen: Bool { portraitFamily() != nil }
}
