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

/// One bundled design, so there is nothing to resolve and nothing to wait for.
struct DesignProvider: TimelineProvider {
    func placeholder(in context: Context) -> DesignEntry {
        DesignEntry(date: .now, designID: nil, isPreview: context.isPreview)
    }

    func getSnapshot(in context: Context, completion: @escaping (DesignEntry) -> Void) {
        completion(DesignEntry(date: .now, designID: nil, isPreview: context.isPreview))
    }

    /// `.never` is right again now that the design ships with the extension.
    /// It was a trap only while the widget depended on something that might
    /// arrive later; nothing here can change without a new build.
    func getTimeline(in context: Context, completion: @escaping (Timeline<DesignEntry>) -> Void) {
        WidgetRenderLog.append("""
        ask  timeline    preview=\(context.isPreview) family=\(context.family.rawValue) \
        size=\(Int(context.displaySize.width))x\(Int(context.displaySize.height))
        """)
        completion(Timeline(
            entries: [DesignEntry(date: .now, designID: nil, isPreview: context.isPreview)],
            policy: .never
        ))
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
