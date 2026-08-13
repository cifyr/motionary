import SwiftUI

/// The phone app is a viewer now.
///
/// A design has to be compiled into the widget extension's bundle to draw at
/// all, so it is built on the Mac by Motionary Studio and arrives with the
/// install. There is nothing left here to import, choose or configure.
@main
struct MotionaryApp: App {
    /// Applied before the first view is built. Setting it from a `.task`
    /// switched the flag but left the already-drawn home on screen, which reads
    /// as the flag having been ignored.
    init() {
        // Before any view, because the first view builds the player, and the
        // player is what activates the session.
        AudioSessionPolicy.configureForSilentPlayback()

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
        if let wanted = EdgeLab.launchOverride(in: arguments), wanted != EdgeLab.isEnabled {
            EdgeLab.isEnabled = wanted
            changed = true
        }
        if let wanted = MaskLab.launchPhasing(in: arguments), wanted != MaskLab.phasing {
            MaskLab.phasing = wanted
            changed = true
        }
        if let wanted = MaskLab.launchOverride(in: arguments), wanted != MaskLab.isEnabled {
            MaskLab.isEnabled = wanted
            changed = true
        }
        // Written on every launch while the lab is on, because the extension
        // can only read what the app has already put there and a card left
        // over from a previous sweep would pass for a working one.
        if MaskLab.isEnabled { MaskLab.stageCards(MaskLab.phasing) }
        // Switching designs is a swipe, which a test run cannot make without
        // driving somebody's screen. This is the same switch by argument, so
        // "does the widget follow the selection" can be answered from a script.
        if let wanted = PrebuiltDesign.launchSelection(in: arguments),
           wanted != ActiveDesign.identifier {
            ActiveDesign.identifier = wanted
            changed = true
        }
        if changed { WidgetCenterBridge.reloadAll() }
    }

    @StateObject private var router = ExternalAppRouter()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(router)
                .preferredColorScheme(.dark)
                // A tile tapped on the widget opens the app with a launch URL,
                // and the app forwards it to the destination.
                .onOpenURL { router.handle($0) }
                // Battery and the other gathered values are only as fresh as
                // the last time the app ran, so it reads them on every return
                // to the foreground - the cheapest moment that is also the most
                // likely to precede a look at the Home Screen.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        ReadoutGatherer.gatherAndPublish()
                        // On every return to the foreground rather than at
                        // launch alone: the render worth reading is usually
                        // the one that happened while the app was closed.
                        DeviceReportMirror.mirror()
                    }
                }
        }
    }
}
