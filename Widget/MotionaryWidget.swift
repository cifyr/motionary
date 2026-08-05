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

    func getTimeline(in context: Context, completion: @escaping (Timeline<DesignEntry>) -> Void) {
        WidgetRenderLog.append("""
        ask  timeline    preview=\(context.isPreview) family=\(context.family.rawValue) \
        size=\(Int(context.displaySize.width))x\(Int(context.displaySize.height)) \
        embed=\(WidgetArchiveFontEmbedding.isEnabled) \
        embedLinked=\(WidgetArchiveFontEmbedding.isLinked)
        """)
        // Archiving happens after this returns, so what this finds belongs to the
        // previous attempt. Captured here anyway: it is the only point in the
        // extension's life that reliably runs, and one reload of lag is cheaper
        // than bisecting routes to rediscover a type list WidgetKit already
        // printed.
        ArchiverErrorLog.capture()
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
            // Outermost view in the archived tree, which is where the embedding
            // flag has to go: the archiver resolves each node's environment as it
            // walks down, so a font used above the flag would still be encoded
            // by reference.
            DesignWidgetView(entry: entry)
                .embeddingCustomFontsInArchive(WidgetArchiveFontEmbedding.isEnabled)
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
