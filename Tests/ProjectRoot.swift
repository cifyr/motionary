import Foundation

/// The checkout this test bundle was built from.
///
/// Found through `#filePath` because `Bundle.main` in a unit test is the runner,
/// which holds neither the sources nor the app's resources - the trap that made
/// three tests skip themselves in silence. A test asserting about a file the
/// build ships has nowhere else to look.
enum ProjectRoot {
    /// Two levels up: this file sits directly in `Tests/`, whatever subfolder the
    /// caller lives in.
    static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func text(at relativePath: String) throws -> String {
        try String(contentsOf: url.appendingPathComponent(relativePath), encoding: .utf8)
    }

    static func plist(at relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: url.appendingPathComponent(relativePath))
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dictionary = parsed as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return dictionary
    }
}
