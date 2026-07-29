import SwiftUI
import os

@main
struct MotionaryApp: App {
    @StateObject private var library = DesignLibrary()
    @StateObject private var router = ExternalAppRouter()

    /// Applied before the first view is built. Setting it from a `.task`
    /// switched the flag but left the already-drawn home on screen, which reads
    /// as the flag having been ignored.
    init() {
        let arguments = ProcessInfo.processInfo.arguments
        var changed = false
        if let routes = FontLab.launchRouteSelection(in: arguments), routes != FontLab.routeSelection {
            FontLab.routeSelection = routes
            changed = true
        }
        if let wanted = FontLab.launchOverride(in: arguments), wanted != FontLab.isEnabled {
            FontLab.isEnabled = wanted
            changed = true
        }
        if let wanted = WidgetArchiveFontEmbedding.launchOverride(in: arguments),
           wanted != WidgetArchiveFontEmbedding.isEnabled {
            WidgetArchiveFontEmbedding.isEnabled = wanted
            changed = true
        }
        if changed { WidgetCenterBridge.reloadAll() }
        PersistentFontProbe.installBundledFontIfRequested(arguments: arguments)
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(library)
                .environmentObject(router)
                .preferredColorScheme(.dark)
                // Read back by PersistentFontCrossProcessTests, which has to
                // confirm the install it is disproving actually happened.
                .overlay(alignment: .top) {
                    if let install = PersistentFontProbe.lastInstall {
                        let copy = PersistentFontProbe.lastCopyInstall
                        Text("BUNDLE \(install.description) || COPY \(copy?.description ?? "not attempted")")
                            .font(.caption2)
                            .accessibilityIdentifier(PersistentFontProbe.resultAccessibilityIdentifier)
                    }
                }
                .onOpenURL { url in
                    router.handle(url)
                }
#if DEBUG
                .task {
                    if DemoSeeder.isRequested {
                        await library.runDemoSeed()
                    }
                }
#endif
        }
    }
}

/// Observable wrapper around the on-disk store.
@MainActor
final class DesignLibrary: ObservableObject {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "Library")

    @Published private(set) var designs: [DesignDocument] = []

    /// Fatal only: the app group is missing, so nothing can be read or written.
    /// This one hides the library and disables importing, so a recoverable
    /// slip must never be reported here — a single failed save used to set it
    /// and left importing switched off for the rest of the session.
    @Published var loadFailure: String?

    /// A single operation went wrong. Worth saying, not worth disabling on.
    @Published var operationFailure: String?

    /// The one selection that drives both the app's home and the widget.
    @Published var activeDesignID: UUID? {
        didSet {
            guard activeDesignID != oldValue else { return }
            ActiveDesign.identifier = activeDesignID
            // The widget reads this at timeline time, so it needs telling.
            WidgetCenterBridge.reloadAll()
        }
    }

    private(set) var store: DesignStore?

    /// What the widget was last told to show, so a reload is pushed on a real
    /// change rather than on every save — the editor saves on each tile drag.
    ///
    /// Keyed on the build generation as well as the identity: a rebuild leaves
    /// the id alone, so keying on identity alone meant rebuilding a design
    /// pushed nothing at all.
    private var lastPublished: String?

    /// Falls back to the most recently edited built design, so the app is never
    /// blank just because nothing was explicitly chosen.
    var activeDesign: DesignDocument? {
        let built = designs.filter { hasBuild(for: $0) }
        if let activeDesignID, let match = built.first(where: { $0.id == activeDesignID }) {
            return match
        }
        return built.first ?? designs.first
    }

    func hasBuild(for design: DesignDocument) -> Bool {
        guard let store else { return false }
        return FileManager.default.fileExists(atPath: store.manifestURL(for: design.id).path)
    }

    init() {
        activeDesignID = ActiveDesign.identifier
        do {
            store = try DesignStore()
            reload()
        } catch {
            // Without the app group nothing works, and the reason is almost
            // always a missing entitlement rather than anything the user did.
            loadFailure = String(describing: error)
            Self.logger.error("store unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    func reload() {
        guard let store else { return }
        // Files written before the protection class was pinned are unreadable
        // to a render that happens while the phone is locked, which is most of
        // them. Relaxing on every load is cheap and spares a rebuild.
        let relaxed = DesignStore.relaxProtection(at: store.root)
        Self.logger.info("relaxed file protection on \(relaxed) items")

        designs = store.loadAll()
        // Designs built before the widget-sized backdrop existed would make the
        // extension decode a full-screen image; cropping one here is cheaper
        // than demanding a rebuild.
        if BackdropMigration.run(store: store, designs: designs) > 0 {
            WidgetCenterBridge.reloadAll()
        }
        let selection = activeDesignID?.uuidString ?? "none"
        let resolved = activeDesign?.name ?? "none"
        Self.logger.info("loaded \(self.designs.count) designs; selection=\(selection, privacy: .public) resolved=\(resolved, privacy: .public)")

        // A widget added before the first design holds an entry that resolved
        // to nothing, and nothing else would ever dislodge it. Pushed on a
        // change of identity rather than on every save, because the editor
        // saves on each tile drag.
        let published = activeDesign.map { "\($0.id.uuidString)#\($0.buildGeneration)" }
        if published != lastPublished {
            lastPublished = published
            WidgetCenterBridge.reloadAll()
            Self.logger.info("pushed widget reload for \(published ?? "none", privacy: .public)")
        }
    }

    func save(_ design: DesignDocument) {
        guard let store else { return }
        do {
            try store.save(design)
            reload()
        } catch {
            operationFailure = "Could not save \"\(design.name)\": \(error)"
            Self.logger.error("save failed for \(design.id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    func archive(_ design: DesignDocument) {
        guard let store else { return }
        do {
            try store.archive(id: design.id)
            reload()
        } catch {
            operationFailure = "Could not remove \"\(design.name)\": \(error)"
        }
    }

    // The bundled design is no longer copied into the store on launch. The
    // widget prefers an imported design over the bundled one, so a seeded copy
    // would outrank the version that is known to draw — and if runtime-
    // registered fonts still will not render, that trades a working widget for
    // a black one. Until something is imported, the bundle is the design.

    func manifest(for design: DesignDocument) -> BuildManifest? {
        try? store?.loadManifest(id: design.id)
    }

#if DEBUG
    /// Set by the demo seed so the preview opens without a tap, which is how
    /// the render path gets screenshotted from the command line.
    @Published var pendingPreviewDesignID: UUID?

    func runDemoSeed() async {
        guard let store else { return }
        switch await DemoSeeder.run(store: store) {
        case .success(let manifest):
            reload()
            // Show what was just seeded, rather than leaving whatever was
            // selected before in place.
            activeDesignID = manifest.designID
            pendingPreviewDesignID = manifest.designID
        case .failure(let message):
            operationFailure = message
        }
    }
#endif
}
