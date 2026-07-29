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
        learn(from: context)
        completion(DesignEntry(date: .now, designID: resolvedID()))
    }

    /// One entry, `.never`: the animation is advanced by the system's timer
    /// text, so a reload policy would spend battery without changing anything.
    /// The app reloads timelines explicitly when the selection or build changes.
    func getTimeline(in context: Context, completion: @escaping (Timeline<DesignEntry>) -> Void) {
        learn(from: context)
        completion(Timeline(
            entries: [DesignEntry(date: .now, designID: resolvedID())],
            policy: .never
        ))
    }

    /// `displaySize` is the size the system will draw at, stated rather than
    /// inferred, and `isPreview` marks the gallery, whose preview would
    /// otherwise be learned as a real size.
    ///
    /// Recorded against the size the design was cut for rather than the family
    /// enum: on iOS 27 one physical widget has reported both systemLarge and
    /// systemMedium while rendering at an identical 359x548, so the enum cannot
    /// be trusted to say which slot the user actually filled. What they chose
    /// in the editor can be.
    private func learn(from context: Context) {
        guard !context.isPreview,
              let store = try? DesignStore(),
              let design = ActiveDesign.resolve(in: store)
        else { return }
        ObservedGeometryStore.record(size: context.displaySize, for: design.widgetSize)
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
        .description("Shows your current Motionary design, cut to this widget's frame.")
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
