import SwiftUI
import os

/// The phone app.
///
/// It was a viewer: a design had to be compiled into the widget extension's
/// bundle to draw at all, so it was built on the Mac by Motionary Studio and
/// arrived with the install. That is still the only route to a loop longer than
/// two seconds, and it still works. But a design whose animation is pictures in
/// the app group rather than fonts in a bundle needs no toolchain, so the app can
/// now make one from a clip in Photos.
@main
struct MotionaryApp: App {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "App")

    /// Applied before the first view is built. Setting it from a `.task`
    /// switched the flag but left the already-drawn home on screen, which reads
    /// as the flag having been ignored.
    init() {
        let arguments = ProcessInfo.processInfo.arguments
        // Reloaded whenever a run *asked* for a setting, not only when the value
        // moved. A measurement run deletes the archive and then waits for a new
        // one; if the flag already held the value it asked for, nothing reloaded
        // and the run timed out with no archive at all, which reads as the
        // timeline having been rejected.
        var requested = false
        if let routes = FontLab.launchRouteSelection(in: arguments) {
            FontLab.routeSelection = routes
            requested = true
        }
        if let wanted = FontLab.launchOverride(in: arguments) {
            FontLab.isEnabled = wanted
            requested = true
        }
        if let wanted = WidgetArchiveFontEmbedding.launchOverride(in: arguments) {
            WidgetArchiveFontEmbedding.isEnabled = wanted
            requested = true
        }
        if requested { WidgetCenterBridge.reloadAll() }
    }

    @StateObject private var router = ExternalAppRouter()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(router)
                .preferredColorScheme(.dark)
                // A tile tapped on the widget opens the app with a launch URL,
                // and the app forwards it to the destination.
                .onOpenURL { router.handle($0) }
                .task { await Self.runRequestedImport() }
        }
    }

    /// Runs an import asked for on the command line.
    ///
    /// The measurement this route lives or dies by is what a full-resolution
    /// design costs the widget extension, and that cannot be taken by tapping
    /// through a sheet: the number has to be read out of a render the extension
    /// makes on its own, across a sweep of frame counts and layouts. This calls
    /// the same importer the picker calls, so everything except
    /// `PHPickerViewController` handing over a URL is covered by a headless run.
    ///
    /// In a `.task` rather than `init()` because it has to await, and the app is
    /// left running long enough afterwards for the widget to be asked for a
    /// timeline.
    static func runRequestedImport() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let request = RuntimeImportRequest.parse(arguments) else { return }
        guard let source = request.resolveSource(in: .main) else {
            logger.error("""
            requested import names no readable source: \
            \(arguments.joined(separator: " "), privacy: .public)
            """)
            return
        }

        do {
            let store = try DesignStore()
            if request.replacesExisting {
                // A sweep otherwise measures whichever design an earlier run
                // left selected, which is the same shape of mistake as reading
                // a stale widget report and believing it.
                for existing in RuntimeDesignImporter.builtDesigns(in: store) {
                    try? store.archive(id: existing.design.id)
                }
            }
            let started = Date()
            let built = try await RuntimeDesignImporter(store: store).run(
                sourceAt: source,
                options: request.options
            )
            WidgetRenderLog.append("""
            app  imported \(built.design.name) in \
            \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \
            \(built.manifest.frameSequence?.summary ?? "no sequence")
            """)
            WidgetCenterBridge.reloadAll()
            logger.info("""
            requested import done: \
            \(built.manifest.frameSequence?.summary ?? "no sequence", privacy: .public)
            """)
        } catch {
            // Written where the sweep can read it as well as logged: a run that
            // produces no widget report and no error at all looks like a run
            // that silently did nothing.
            WidgetRenderLog.append("app  IMPORT FAILED \(String(describing: error))")
            logger.error("requested import failed: \(String(describing: error), privacy: .public)")
        }
    }
}
