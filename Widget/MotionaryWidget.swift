import AppIntents
import SwiftUI
import WidgetKit

/// A design the user can bind a placed widget to.
struct DesignChoice: AppEntity, Identifiable, Hashable {
    let id: String
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Design" }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static let defaultQuery = DesignChoiceQuery()
}

struct DesignChoiceQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [DesignChoice] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [DesignChoice] {
        guard let store = try? DesignStore() else { return [] }
        return store.loadAll().map { DesignChoice(id: $0.id.uuidString, name: $0.name) }
    }

    func defaultResult() async -> DesignChoice? {
        try? await suggestedEntities().first
    }
}

struct SelectDesignIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Choose design" }
    static var description: IntentDescription { "Pick which Motionary design this widget shows." }

    @Parameter(title: "Design")
    var design: DesignChoice?
}

struct DesignEntry: TimelineEntry {
    let date: Date
    let designID: UUID?
}

struct DesignProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> DesignEntry {
        DesignEntry(date: .now, designID: nil)
    }

    func snapshot(for configuration: SelectDesignIntent, in context: Context) async -> DesignEntry {
        DesignEntry(date: .now, designID: resolve(configuration))
    }

    /// One entry, `.never`: the animation is advanced by the system's timer
    /// text, so a reload policy would spend battery without changing anything.
    func timeline(for configuration: SelectDesignIntent, in context: Context) async -> Timeline<DesignEntry> {
        Timeline(entries: [DesignEntry(date: .now, designID: resolve(configuration))], policy: .never)
    }

    private func resolve(_ configuration: SelectDesignIntent) -> UUID? {
        if let id = configuration.design?.id, let uuid = UUID(uuidString: id) { return uuid }
        // An unconfigured widget shows the most recently edited design rather
        // than nothing at all.
        return (try? DesignStore())?.loadAll().first?.id
    }
}

struct MotionaryWidget: Widget {
    let kind = "MotionaryDesignWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectDesignIntent.self, provider: DesignProvider()) { entry in
            DesignWidgetView(entry: entry)
        }
        .configurationDisplayName("Motionary")
        .description("An animated design cut to this widget's frame.")
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
