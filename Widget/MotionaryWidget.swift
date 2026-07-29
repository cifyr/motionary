import SwiftUI
import WidgetKit

struct DesignEntry: TimelineEntry {
    let date: Date
    let designID: UUID?
}

/// The widget shows whichever design is selected as the home design, so there
/// is no per-widget configuration to keep in sync with the app.
struct DesignProvider: TimelineProvider {
    func placeholder(in context: Context) -> DesignEntry {
        DesignEntry(date: .now, designID: resolvedID())
    }

    func getSnapshot(in context: Context, completion: @escaping (DesignEntry) -> Void) {
        completion(DesignEntry(date: .now, designID: resolvedID()))
    }

    /// One entry, `.never`: the animation is advanced by the system's timer
    /// text, so a reload policy would spend battery without changing anything.
    /// The app reloads timelines explicitly when the selection or build changes.
    func getTimeline(in context: Context, completion: @escaping (Timeline<DesignEntry>) -> Void) {
        let designID = resolvedID()
        // With no design resolved, `.never` is a trap: the entry says "create a
        // design" and is then kept for good, so the widget went on saying it
        // long after a design existed because nothing ever asked again. The app
        // also pushes a reload when its library loads; this is the backstop for
        // a widget added before the first design.
        completion(Timeline(
            entries: [DesignEntry(date: .now, designID: designID)],
            policy: designID == nil ? .after(.now.addingTimeInterval(300)) : .never
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
