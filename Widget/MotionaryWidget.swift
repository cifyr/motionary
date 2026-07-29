import SwiftUI
import WidgetKit

struct DesignEntry: TimelineEntry {
    let date: Date
    let designID: UUID?
    /// Carried from the provider so a render can say whether it was for the
    /// widget gallery or for a widget actually sitting on the Home Screen.
    /// Those look identical afterwards — same family, same size — and telling
    /// them apart decides whether the placed widget is being asked to draw at
    /// all.
    var isPreview = false
}

/// The widget shows whichever design is selected as the home design, so there
/// is no per-widget configuration to keep in sync with the app.
struct DesignProvider: TimelineProvider {
    func placeholder(in context: Context) -> DesignEntry {
        WidgetRenderLog.append("ask  placeholder preview=\(context.isPreview) family=\(context.family.rawValue)")
        return DesignEntry(date: .now, designID: resolvedID(), isPreview: context.isPreview)
    }

    func getSnapshot(in context: Context, completion: @escaping (DesignEntry) -> Void) {
        WidgetRenderLog.append("ask  snapshot    preview=\(context.isPreview) family=\(context.family.rawValue)")
        completion(DesignEntry(date: .now, designID: resolvedID(), isPreview: context.isPreview))
    }

    /// One entry. The animation is advanced by the system's timer text, so a
    /// working widget needs no reloads at all.
    ///
    /// Never `.never`, though: a timeline that cannot expire cannot correct
    /// itself, and one built before a design existed left the widget saying
    /// "create a design" for good.
    ///
    /// The hour is reserved for a design that can actually be drawn. Anything
    /// else — no design, or one still mid-build — is a state worth asking
    /// about again shortly. A design being built resolves perfectly well and
    /// then fails to render, so it used to receive the hour and sat on "has
    /// not been built yet" long after the build had finished.
    func getTimeline(in context: Context, completion: @escaping (Timeline<DesignEntry>) -> Void) {
        let current = resolved()
        let designID = current?.id
        let retry: TimeInterval = current?.isBuilt == true ? 3600 : 60
        WidgetRenderLog.append("""
        ask  timeline    preview=\(context.isPreview) family=\(context.family.rawValue) \
        size=\(Int(context.displaySize.width))x\(Int(context.displaySize.height)) \
        design=\(designID.map { String($0.uuidString.prefix(8)) } ?? "nil")
        """)
        completion(Timeline(
            entries: [DesignEntry(date: .now, designID: designID, isPreview: context.isPreview)],
            policy: .after(.now.addingTimeInterval(retry))
        ))
    }

    private func resolvedID() -> UUID? { resolved()?.id }

    /// Whether the design can actually be drawn, not just whether one exists.
    ///
    /// A design that is still being built resolves perfectly well and then
    /// fails to render, and it used to be given the hour-long refresh reserved
    /// for a working widget — so a widget drawn during a build stayed on
    /// "has not been built yet" for an hour after the build finished.
    private func resolved() -> (id: UUID, isBuilt: Bool)? {
        guard let store = try? DesignStore(),
              let design = ActiveDesign.resolve(in: store)
        else { return nil }
        let isBuilt = FileManager.default.fileExists(atPath: store.manifestURL(for: design.id).path)
        return (design.id, isBuilt)
    }
}

struct MotionaryWidget: Widget {
    let kind = "MotionaryDesignWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DesignProvider()) { entry in
            DesignWidgetView(entry: entry)
        }
        .configurationDisplayName("Motionary")
        .description("Shows your current Motionary design, cut to the tall portrait frame.")
        .supportedFamilies(WidgetFamilyCompatibility.supportedFamilies())
        .contentMarginsDisabled()
        .containerBackgroundRemovable(false)
    }
}

@main
struct MotionaryWidgetBundle: WidgetBundle {
    var body: some Widget {
        MotionaryWidget()
    }
}
