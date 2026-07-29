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

    /// One entry, `.never`: the animation is advanced by the system's timer
    /// text, so a reload policy would spend battery without changing anything.
    /// The app reloads timelines explicitly when the selection or build changes.
    func getTimeline(in context: Context, completion: @escaping (Timeline<DesignEntry>) -> Void) {
        let designID = resolvedID()
        // Never `.never`. The animation needs no reloads — the timer text
        // drives it — but a timeline that never expires is also a timeline
        // that can never correct itself, and one built before a design existed
        // left the widget saying "create a design" for good. An hourly refresh
        // is roughly 24 a day against WidgetKit's budget and costs nothing to
        // serve, since the entry is just a UUID.
        let retry: TimeInterval = designID == nil ? 300 : 3600
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

    private func resolvedID() -> UUID? {
        guard let store = try? DesignStore() else { return nil }
        return ActiveDesign.resolve(in: store)?.id
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
