import SwiftUI
import os

/// Search and choose an icon from Iconify's open-source sets.
///
/// Results are rendered locally from the SVG bodies rather than downloaded as
/// images, so the grid needs one request per set rather than one per icon, and
/// the chosen icon can be rasterised into the shared cache for the widget.
struct IconPickerView: View {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "IconPicker")

    @Environment(\.dismiss) private var dismiss

    let cache: IconCache
    let suggestion: String
    let onSelect: (IconAsset) -> Void

    @State private var query = ""
    @State private var results: [IconAsset] = []
    @State private var previews: [String: Image] = [:]
    @State private var collections: [String: IconifyService.Collection] = [:]
    @State private var isSearching = false
    @State private var failure: String?
    @State private var searchTask: Task<Void, Never>?

    private let service = IconifyService()
    private let columns = [GridItem(.adaptive(minimum: 62), spacing: 14)]

    var body: some View {
        NavigationStack {
            Group {
                if let failure {
                    FailureView(title: "Icon search unavailable", message: failure)
                } else if results.isEmpty && !isSearching {
                    ContentUnavailableView {
                        Label("Search for an icon", systemImage: "magnifyingglass")
                    } description: {
                        Text("Icons come from Iconify's open-source sets, including Simple Icons for brands. Licences vary by set and are shown when you pick one.")
                    }
                } else {
                    grid
                }
            }
            .overlay {
                if isSearching && results.isEmpty {
                    ProgressView()
                }
            }
            .searchable(text: $query, prompt: "Search icons")
            .onSubmit(of: .search) { scheduleSearch(immediately: true) }
            .onChange(of: query) { _, _ in scheduleSearch(immediately: false) }
            .navigationTitle("Choose icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                if query.isEmpty {
                    query = suggestion
                    scheduleSearch(immediately: true)
                }
            }
            .onDisappear { searchTask?.cancel() }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(results) { icon in
                    Button {
                        choose(icon)
                    } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.secondary.opacity(0.15))
                                if let preview = previews[icon.id] {
                                    preview
                                        .resizable()
                                        .interpolation(.high)
                                        .aspectRatio(contentMode: .fit)
                                        .padding(10)
                                } else {
                                    ProgressView().controlSize(.mini)
                                }
                            }
                            .frame(width: 62, height: 62)

                            Text(icon.prefix)
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()

            if !collections.isEmpty {
                licenceNote
            }
        }
    }

    private var licenceNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sets in these results")
                .font(.caption.weight(.semibold))
            ForEach(collections.keys.sorted(), id: \.self) { prefix in
                if let collection = collections[prefix] {
                    Text("\(collection.name) — \(collection.license?.title ?? "licence unknown")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Brand marks remain the property of their owners.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.bottom, 24)
    }

    // MARK: - Search

    private func scheduleSearch(immediately: Bool) {
        searchTask?.cancel()
        let text = query
        searchTask = Task {
            // Debounce typing so a search is not fired per keystroke.
            if !immediately {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
            }
            await runSearch(text)
        }
    }

    private func runSearch(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            return
        }
        isSearching = true
        defer { isSearching = false }

        do {
            let found = try await service.search(query: text)
            guard !Task.isCancelled else { return }
            results = found
            previews = [:]
            failure = nil
            await loadPreviews(for: found)
            await loadCollections(for: found)
        } catch {
            guard !Task.isCancelled else { return }
            failure = String(describing: error)
            Self.logger.error("search failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// One request per set rather than per icon, then rasterised locally.
    private func loadPreviews(for icons: [IconAsset]) async {
        let bySet = Dictionary(grouping: icons, by: \.prefix)
        for (prefix, group) in bySet {
            guard !Task.isCancelled else { return }
            do {
                let bodies = try await service.bodies(prefix: prefix, names: group.map(\.name))
                for icon in group {
                    guard let body = bodies[icon.name] else { continue }
                    let renderer = SVGIconRenderer(
                        viewBox: body.viewBox,
                        tint: UIColor.label.cgColor
                    )
                    if let image = try? renderer.image(body: body.body, side: 128) {
                        previews[icon.id] = Image(uiImage: UIImage(cgImage: image))
                    }
                }
            } catch {
                Self.logger.error("preview load failed for \(prefix, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func loadCollections(for icons: [IconAsset]) async {
        let prefixes = Array(Set(icons.map(\.prefix))).sorted()
        collections = (try? await service.collections(prefixes: prefixes)) ?? [:]
    }

    private func choose(_ icon: IconAsset) {
        Task {
            do {
                let body = try await service.body(for: icon)
                // Tiles sit on a coloured plate, so the cached copy is white;
                // multi-colour sets keep whatever they specify explicitly.
                let renderer = SVGIconRenderer(
                    viewBox: body.viewBox,
                    tint: CGColor(red: 1, green: 1, blue: 1, alpha: 1)
                )
                let image = try renderer.image(body: body.body, side: IconCache.renderedSide)
                try cache.store(image, for: icon)
                onSelect(icon)
                dismiss()
            } catch {
                failure = String(describing: error)
                Self.logger.error("could not cache \(icon.id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }
}
