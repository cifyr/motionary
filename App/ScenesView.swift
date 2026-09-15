import SwiftUI
import os

/// Browses the scenes that can be downloaded into this install.
///
/// Pushed from the settings sheet, so it inherits that screen's navigation
/// stack rather than opening one of its own.
struct ScenesView: View {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "Scenes")

    @State private var entries: [SceneCatalog.Entry] = []
    @State private var loading = true
    @State private var failure: String?
    @State private var downloading: String?
    @State private var fraction: Double = 0
    @State private var note: String?
    /// Design ids already in the store, so a scene that is here says so rather
    /// than offering to fetch tens of megabytes again.
    @State private var installed: Set<String> = []

    var body: some View {
        List {
            if loading {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Looking for scenes").foregroundStyle(.secondary)
                }
            } else if let failure {
                Section {
                    Text(failure).font(.callout).foregroundStyle(.secondary)
                    Button("Try again") { Task { await load() } }
                }
            } else if entries.isEmpty {
                Text("No scenes are published yet.").foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(entries) { entry in row(for: entry) }
                } footer: {
                    Text("Scenes are added over time. A downloaded scene becomes the one on screen, and you can swipe between everything you have.")
                }
            }

            if let note {
                Section { Text(note).font(.callout) }
            }
        }
        .navigationTitle("More scenes")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func row(for entry: SceneCatalog.Entry) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: entry.preview) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary)
            }
            .frame(width: 44, height: 92)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).font(.body)
                Text(entry.sizeText).font(.caption).foregroundStyle(.secondary)
                if !entry.isFree {
                    Text("Not available in this version")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            if installed.contains(entry.id) {
                Text("Installed").font(.caption).foregroundStyle(.secondary)
            } else if downloading == entry.id {
                ProgressView(value: fraction).progressViewStyle(.circular)
            } else if entry.isFree {
                Button("Get") { Task { await get(entry) } }
                    .buttonStyle(.bordered)
                    .disabled(downloading != nil)
            }
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        loading = entries.isEmpty
        failure = nil
        do {
            let fetched = try await SceneCatalog.fetch()
            entries = fetched
            installed = Self.installedIDs(among: fetched)
        } catch {
            Self.logger.error("catalogue load failed: \(String(describing: error), privacy: .public)")
            failure = "\(error)"
        }
        loading = false
    }

    private func get(_ entry: SceneCatalog.Entry) async {
        downloading = entry.id
        fraction = 0
        note = nil
        defer { downloading = nil }

        do {
            let file = try await SceneCatalog.download(entry) { value in
                Task { @MainActor in fraction = value }
            }
            // The same path a cable delivery or a Files import takes: it
            // unpacks, selects the design and reloads the widget.
            let outcome = DesignDelivery.receive(at: file)
            try? FileManager.default.removeItem(at: file)
            switch outcome {
            case .delivered(let name, _):
                installed.insert(entry.id)
                note = "\(name) is ready. Close this to see it."
            case .nothingToDo:
                note = "\(entry.name) arrived but held no design."
            case .failed(let reason):
                Self.logger.error("install failed for \(entry.name, privacy: .public): \(reason, privacy: .public)")
                note = "\(entry.name) could not be installed: \(reason)"
            }
        } catch {
            Self.logger.error("download failed for \(entry.name, privacy: .public): \(String(describing: error), privacy: .public)")
            note = "\(entry.name) could not be downloaded: \(error)"
        }
    }

    private static func installedIDs(among entries: [SceneCatalog.Entry]) -> Set<String> {
        guard let store = try? DesignStore() else { return [] }
        return Set(entries.map(\.id).filter { id in
            guard let uuid = UUID(uuidString: id) else { return false }
            return FileManager.default.fileExists(atPath: store.designURL(for: uuid).path)
        })
    }
}
