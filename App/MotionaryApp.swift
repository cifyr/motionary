import SwiftUI
import os

@main
struct MotionaryApp: App {
    @StateObject private var library = DesignLibrary()
    @StateObject private var router = ExternalAppRouter()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .environmentObject(router)
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
    @Published var loadFailure: String?

    private(set) var store: DesignStore?

    init() {
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
        designs = store.loadAll()
        Self.logger.debug("loaded \(self.designs.count) designs")
    }

    func save(_ design: DesignDocument) {
        guard let store else { return }
        do {
            try store.save(design)
            reload()
        } catch {
            loadFailure = "Could not save \"\(design.name)\": \(error)"
            Self.logger.error("save failed for \(design.id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    func archive(_ design: DesignDocument) {
        guard let store else { return }
        do {
            try store.archive(id: design.id)
            reload()
        } catch {
            loadFailure = "Could not remove \"\(design.name)\": \(error)"
        }
    }

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
            pendingPreviewDesignID = manifest.designID
        case .failure(let message):
            loadFailure = message
        }
    }
#endif
}
