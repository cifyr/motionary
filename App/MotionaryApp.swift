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
        if changed { WidgetCenterBridge.reloadAll() }
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .preferredColorScheme(.dark)
        }
    }
}
