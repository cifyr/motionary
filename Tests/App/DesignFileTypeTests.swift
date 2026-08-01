import XCTest

/// Whether the phone is ever offered a design file at all.
///
/// The declaration in `App/Info.plist` is the whole mechanism - no runtime code
/// holds it up - and a design AirDropped to a phone that does not claim the type
/// simply has nowhere to go, with nothing shown to say so. That file is fed to a
/// generated project and rewritten in place by the studio's bundling step on
/// every build, so this is what notices when either drops the keys.
final class DesignFileTypeTests: XCTestCase {
    private let identifier = "com.caden.motionary.design"

    private func plist() throws -> [String: Any] {
        try ProjectRoot.plist(at: "App/Info.plist")
    }

    func testTheAppExportsItsOwnTypeForADesign() throws {
        let declarations = try XCTUnwrap(
            plist()["UTExportedTypeDeclarations"] as? [[String: Any]],
            "App/Info.plist exports no type, so a design file belongs to nothing"
        )
        let design = try XCTUnwrap(
            declarations.first { $0["UTTypeIdentifier"] as? String == identifier },
            "no declaration for \(identifier)"
        )
        XCTAssertEqual(
            design["UTTypeConformsTo"] as? [String], ["public.zip-archive"],
            "a design is a zip inside, and a type that does not say so is not recognised by content"
        )
        let tags = try XCTUnwrap(design["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(tags["public.filename-extension"] as? [String], ["motionary"])
    }

    /// Exporting the type names it; this is what says the app opens one.
    func testTheAppOpensThatTypeAndNoOtherZip() throws {
        let documents = try XCTUnwrap(
            plist()["CFBundleDocumentTypes"] as? [[String: Any]],
            "App/Info.plist opens no documents, so nothing offers Motionary in a share sheet"
        )
        let claimed = documents.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        XCTAssertEqual(claimed, [identifier])
        XCTAssertFalse(
            claimed.contains("public.zip-archive"),
            "claiming every zip on the phone is not the same feature as opening a design"
        )
    }

    /// The studio rewrites `UIAppFonts` in this file on every design build, with
    /// a regex over the text rather than a re-encode, so the declaration has to
    /// come out the other side intact.
    func testTheDeclarationSurvivesTheStudiosFontRewrite() throws {
        let rewritten = try BundleWriter.replacingAppFonts(
            in: try ProjectRoot.text(at: "App/Info.plist"),
            with: ["MFontabcL0-Regular.ttf"],
            path: "App/Info.plist"
        )
        let data = try XCTUnwrap(rewritten.data(using: .utf8))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let declarations = plist["UTExportedTypeDeclarations"] as? [[String: Any]]
        XCTAssertEqual(declarations?.first?["UTTypeIdentifier"] as? String, identifier)
        let documents = plist["CFBundleDocumentTypes"] as? [[String: Any]]
        XCTAssertEqual(documents?.first?["LSItemContentTypes"] as? [String], [identifier])
    }
}
