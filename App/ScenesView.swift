import SwiftUI
import os

/// What the gallery and the detail screen both need to agree on: what is
/// published, what is already on this phone, and what is downloading.
///
/// Shared rather than held by each screen, so a download started on the detail
/// screen still shows its progress on the card after going back.
@MainActor
final class SceneLibrary: ObservableObject {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "Scenes")

    struct Note: Equatable {
        let text: String
        let isFailure: Bool
    }

    @Published private(set) var entries: [SceneCatalog.Entry] = []
    @Published private(set) var loading = true
    @Published private(set) var failure: String?
    @Published private(set) var installed: Set<String> = []
    @Published private(set) var downloading: String?
    @Published private(set) var fraction: Double = 0
    @Published var note: Note?
    /// Bumped on every successful install, for the success haptic.
    @Published private(set) var installs = 0

    func load() async {
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

    func get(_ entry: SceneCatalog.Entry) async {
        guard downloading == nil else { return }
        downloading = entry.id
        fraction = 0
        note = nil
        defer { downloading = nil }

        do {
            let file = try await SceneCatalog.download(entry) { value in
                Task { @MainActor [weak self] in self?.fraction = value }
            }
            // The same path a cable delivery or a Files import takes: unpack,
            // select the design, reload the widget.
            let outcome = DesignDelivery.receive(at: file)
            try? FileManager.default.removeItem(at: file)
            switch outcome {
            case .delivered(let name, _):
                installed.insert(entry.id)
                installs += 1
                note = Note(text: "\(name) is now your scene. Close Design options to see it.", isFailure: false)
            case .nothingToDo:
                note = Note(text: "\(entry.name) arrived but held no design.", isFailure: true)
            case .failed(let reason):
                Self.logger.error("install failed for \(entry.name, privacy: .public): \(reason, privacy: .public)")
                note = Note(text: "\(entry.name) could not be installed: \(reason)", isFailure: true)
            }
        } catch {
            Self.logger.error("download failed for \(entry.name, privacy: .public): \(String(describing: error), privacy: .public)")
            note = Note(text: "\(entry.name) could not be downloaded: \(error)", isFailure: true)
        }
    }

    /// Selects a scene that is already on the phone, without fetching it again.
    func use(_ entry: SceneCatalog.Entry) {
        guard let id = UUID(uuidString: entry.id) else { return }
        ActiveDesign.identifier = id
        WidgetCenterBridge.reloadAll()
        Self.logger.info("selected installed scene \(entry.name, privacy: .public)")
        note = Note(text: "\(entry.name) is now your scene. Close Design options to see it.", isFailure: false)
    }

    private static func installedIDs(among entries: [SceneCatalog.Entry]) -> Set<String> {
        guard let store = try? DesignStore() else { return [] }
        return Set(entries.map(\.id).filter { id in
            guard let uuid = UUID(uuidString: id) else { return false }
            return FileManager.default.fileExists(atPath: store.designURL(for: uuid).path)
        })
    }
}

/// Browses the scenes that can be downloaded into this install.
///
/// Pushed from the settings sheet, so it inherits that screen's navigation
/// stack rather than opening one of its own.
struct ScenesView: View {
    @StateObject private var library = SceneLibrary()
    @State private var focused: SceneCatalog.Entry?

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                content
            }
            .padding(.bottom, 32)
        }
        .background(Color.emberDark.ignoresSafeArea())
        .toolbarBackground(Color.emberDark, for: .navigationBar)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $focused) { entry in
            SceneDetailView(entry: entry, library: library)
        }
        .task { await library.load() }
        .refreshable { await library.load() }
        .sensoryFeedback(.success, trigger: library.installs)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scene library").emberLabel()
            // The display end of the scheme's ladder, as the empty home sets
            // its wordmark.
            Text("MORE SCENES")
                .font(.system(size: 34, weight: .black))
                .tracking(-0.7)
                .foregroundStyle(Color.emberTitle)
            Rectangle().fill(Color.emberLine).frame(height: 1)
            Text("Published since this version of Motionary. Each one plays here the way it will move on your Home Screen.")
                .font(.callout)
                .foregroundStyle(Color.emberSubtitle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 24)
    }

    @ViewBuilder
    private var content: some View {
        if library.loading {
            HStack(spacing: 12) {
                ProgressView().tint(Color.emberSubtitle)
                Text("Looking for scenes").font(.callout).foregroundStyle(Color.emberBody)
            }
            .padding(.horizontal, 20)
        } else if let failure = library.failure {
            VStack(alignment: .leading, spacing: 14) {
                SceneNoteView(note: .init(text: "The scene library could not be reached. \(failure)", isFailure: true))
                Button("Try again") { Task { await library.load() } }
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.emberAccent)
            }
            .padding(.horizontal, 20)
        } else if library.entries.isEmpty {
            Text("No scenes are published yet.")
                .font(.callout)
                .foregroundStyle(Color.emberBody)
                .padding(.horizontal, 20)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                ForEach(library.entries) { entry in
                    Button { focused = entry } label: {
                        SceneCard(entry: entry, library: library)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("scene-card-\(entry.name)")
                }
            }
            .padding(.horizontal, 20)

            if let note = library.note {
                SceneNoteView(note: note)
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
            }
        }
    }
}

private struct SceneCard: View {
    let entry: SceneCatalog.Entry
    @ObservedObject var library: SceneLibrary

    private var isInstalled: Bool { library.installed.contains(entry.id) }
    private var isDownloading: Bool { library.downloading == entry.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScenePreview(entry: entry)
                .aspectRatio(ScenePreview.aspect, contentMode: .fit)
                .emberEdge()
                .overlay(alignment: .topLeading) {
                    if isInstalled { SceneTag(text: "Installed").padding(8) }
                }
                .overlay(alignment: .bottomLeading) {
                    if isDownloading { SceneProgressBar(fraction: library.fraction) }
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.emberTitle)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.emberDesc)
                    .monospacedDigit()
            }
        }
        .contentShape(Rectangle())
    }

    private var detail: String {
        if isDownloading { return "Downloading \(Int(library.fraction * 100))%" }
        if !entry.isFree { return "Not available in this version" }
        return entry.sizeText
    }
}

/// The scene on a still of its wallpaper, with the moving preview laid over it
/// as soon as it is on disk, so a card is never an empty box while it loads.
struct ScenePreview: View {
    /// Every published scene is cut for a 1206x2622 screen.
    static let aspect: CGFloat = 1206.0 / 2622.0
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "Scenes")

    let entry: SceneCatalog.Entry
    @State private var motion: URL?

    var body: some View {
        Color.black
            .overlay {
                AsyncImage(url: entry.preview) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    }
                }
            }
            .overlay {
                if let motion {
                    LoopingVideoView(url: motion)
                        .transition(.opacity)
                }
            }
            .clipped()
            .task(id: entry.id) {
                do {
                    let local = try await SceneCatalog.cachedMotion(for: entry)
                    withAnimation(.easeOut(duration: 0.25)) { motion = local }
                } catch {
                    // The still stays up, which is a fine card on its own.
                    Self.logger.error("preview unavailable for \(entry.name, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
            .accessibilityHidden(true)
    }
}

/// One scene, large, with the one action it offers.
struct SceneDetailView: View {
    let entry: SceneCatalog.Entry
    @ObservedObject var library: SceneLibrary

    private var isInstalled: Bool { library.installed.contains(entry.id) }
    private var isDownloading: Bool { library.downloading == entry.id }

    var body: some View {
        VStack(spacing: 0) {
            ScenePreview(entry: entry)
                .aspectRatio(ScenePreview.aspect, contentMode: .fit)
                .emberEdge()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 28)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 8) {
                Text("Scene").emberLabel()
                Text(entry.name.uppercased())
                    .font(.system(size: 28, weight: .black))
                    .tracking(-0.56)
                    .foregroundStyle(Color.emberTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(Color.emberSubtitle)
                    .monospacedDigit()
                if let note = library.note {
                    SceneNoteView(note: note).padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 20)

            action
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 28)
        }
        .background(Color.emberDark.ignoresSafeArea())
        .toolbarBackground(Color.emberDark, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            // A message about this scene should not greet the next one.
            if !isDownloading { library.note = nil }
        }
    }

    private var subtitle: String {
        var parts = ["\(entry.sizeText) download"]
        if let date = Self.parsed.date(from: entry.published) {
            parts.append("published \(date.formatted(date: .abbreviated, time: .omitted))")
        }
        return parts.joined(separator: ", ")
    }

    private static let parsed: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    @ViewBuilder
    private var action: some View {
        if !entry.isFree {
            SceneButtonLabel(text: "Not available in this version", style: .quiet)
        } else if isDownloading {
            SceneButtonLabel(text: "Downloading \(Int(library.fraction * 100))%", style: .progress(library.fraction))
        } else if isInstalled {
            Button { library.use(entry) } label: {
                SceneButtonLabel(text: "Use this scene", style: .outline)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("scene-use")
        } else {
            Button { Task { await library.get(entry) } } label: {
                SceneButtonLabel(text: "Get scene", style: .primary)
            }
            .buttonStyle(.plain)
            .disabled(library.downloading != nil)
            .accessibilityIdentifier("scene-get")
        }
    }
}

/// The primary button as Onboarding draws it: full width, square, one accent.
private struct SceneButtonLabel: View {
    enum Style: Equatable {
        case primary
        case outline
        case quiet
        case progress(Double)
    }

    let text: String
    let style: Style

    var body: some View {
        Text(text)
            .font(.system(size: 17, weight: .semibold))
            .monospacedDigit()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(foreground)
            .background(alignment: .leading) { background }
            .overlay {
                if style == .outline || style == .quiet {
                    Rectangle().strokeBorder(Color.emberLine, lineWidth: 1)
                }
            }
    }

    private var foreground: Color {
        switch style {
        case .primary, .progress: .white
        case .outline: Color.emberTitle
        case .quiet: Color.emberDesc
        }
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .primary:
            Color.emberAccent
        case .progress(let fraction):
            // The button fills with the accent as the download runs, so the
            // control and its progress are the same object.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Color.emberLine
                    Color.emberAccent.frame(width: geometry.size.width * fraction)
                }
            }
        case .outline, .quiet:
            Color.clear
        }
    }
}

/// Download progress along the bottom edge of a card.
private struct SceneProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            Color.emberAccent
                .frame(width: geometry.size.width * fraction, height: 2)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .allowsHitTesting(false)
    }
}

/// A label on the picture, set like the home's toast: dark ground, hairline,
/// the accent on its edge.
private struct SceneTag: View {
    let text: String

    var body: some View {
        Text(text)
            .emberLabel(size: 10)
            .foregroundStyle(Color.emberTitle)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.emberDark.opacity(0.86))
            .emberEdge()
            .overlay(alignment: .leading) {
                Rectangle().fill(Color.emberAccent).frame(width: 2)
            }
    }
}

/// A result or a failure, in the same shape as the home's toast.
private struct SceneNoteView: View {
    let note: SceneLibrary.Note

    var body: some View {
        Text(note.text)
            .font(.footnote)
            .foregroundStyle(note.isFailure ? Color.emberSubtitle : Color.emberTitle)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.emberDark.opacity(0.86))
            .emberEdge()
            .overlay(alignment: .leading) {
                Rectangle().fill(Color.emberAccent).frame(width: 2)
            }
    }
}
