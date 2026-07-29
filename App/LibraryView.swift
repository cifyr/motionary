import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import os

struct LibraryView: View {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "Library")

    @EnvironmentObject private var library: DesignLibrary
    @EnvironmentObject private var router: ExternalAppRouter
    @Environment(\.dismiss) private var dismiss

    @State private var pickerItem: PhotosPickerItem?
    @State private var importing = false
    @State private var importFailure: String?
    @State private var editing: DesignDocument?
    @State private var showingFileImporter = false

    var body: some View {
        NavigationStack {
            Group {
                if let failure = library.loadFailure {
                    FailureView(title: "Storage unavailable", message: failure)
                } else if library.designs.isEmpty {
                    EmptyLibraryView(isImporting: importing)
                } else {
                    designList
                }
            }
            .navigationTitle("Designs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        PhotosPicker(
                            selection: $pickerItem,
                            matching: .any(of: [.videos, .images]),
                            photoLibrary: .shared()
                        ) {
                            Label("From Photos", systemImage: "photo.on.rectangle")
                        }
                        Button {
                            showingFileImporter = true
                        } label: {
                            Label("From Files", systemImage: "folder")
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .disabled(importing || library.loadFailure != nil)
                }
            }
            .overlay {
                if importing {
                    ProgressOverlay(caption: "Importing")
                }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.movie, .video, .gif],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task { await importFile(at: url) }
                case .failure(let error):
                    importFailure = String(describing: error)
                }
            }
            .sheet(item: $editing) { design in
                EditorView(design: design)
                    .environmentObject(library)
            }
#if DEBUG
            .sheet(item: Binding(
                get: { library.pendingPreviewDesignID.flatMap { id in library.designs.first { $0.id == id } } },
                set: { if $0 == nil { library.pendingPreviewDesignID = nil } }
            )) { design in
                if let store = library.store {
                    WidgetPreviewView(design: design, store: store)
                }
            }
#endif
            .alert("Import failed", isPresented: Binding(
                get: { importFailure != nil },
                set: { if !$0 { importFailure = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importFailure ?? "")
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task { await importPicked(item) }
            }
        }
    }

    private var designList: some View {
        List {
            Section {
                Picker("Showing", selection: Binding(
                    get: { library.activeDesign?.id },
                    set: { library.activeDesignID = $0 }
                )) {
                    ForEach(library.designs) { design in
                        Text(design.name)
                            .tag(Optional(design.id))
                    }
                }
            } header: {
                Text("Home and widget")
            } footer: {
                Text("The app and the Home Screen widget both show this design. Build a design before selecting it.")
            }

            Section {
                ForEach(library.designs) { design in
                    Button {
                        editing = design
                    } label: {
                        DesignRow(
                            design: design,
                            manifest: library.manifest(for: design),
                            isActive: library.activeDesign?.id == design.id
                        )
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .leading) {
                        Button("Show on home") {
                            library.activeDesignID = design.id
                        }
                        .tint(.accentColor)
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) {
                            library.archive(design)
                        }
                    }
                }
            } header: {
                Text("Designs")
            } footer: {
                Text("Tap a design to edit it. Swipe right to show it on the home and in the widget.")
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.shortVersion)
                LabeledContent("Designs", value: "\(library.designs.count)")
            }
        }
        .listStyle(.insetGrouped)
    }

    private func importPicked(_ item: PhotosPickerItem) async {
        importing = true
        defer {
            importing = false
            pickerItem = nil
        }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            importFailure = String(describing: ImportError.noMediaData)
            return
        }
        await ingest(data: data)
    }

    /// A file chosen in Files is security scoped, so it has to be copied while
    /// access is held rather than referenced later.
    private func importFile(at url: URL) async {
        importing = true
        defer { importing = false }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            await ingest(data: try Data(contentsOf: url), preferredName: url.lastPathComponent)
        } catch {
            importFailure = String(describing: error)
        }
    }

    private func ingest(data: Data, preferredName: String? = nil) async {
        guard let store = library.store else { return }
        do {
            // GIF and video take different decode paths, so the extension has
            // to reflect what the bytes actually are.
            let isGIF = data.starts(with: Data("GIF8".utf8))
            let filename = isGIF ? "source.gif" : "source.mov"

            var design = DesignDocument.new(
                name: preferredName.map { ($0 as NSString).deletingPathExtension }
                    ?? "Design \(library.designs.count + 1)",
                sourceVideoName: filename
            )
            try store.createFolder(for: design.id)
            let destination = store.sourceVideoURL(for: design)
            try data.write(to: destination, options: .atomic)
            Self.logger.info("imported \(data.count) bytes as \(filename, privacy: .public)")

            // Sample the head of the clip to pick a default loop and to find
            // what actually moves, so the editor opens on something usable.
            let extractor = MediaFrameExtractor(url: destination)
            let summary = try await extractor.summary()
            let spec = design.spec
            let available = max(1, min(summary.frameCount - 1, 64))
            design.loopFrameCount = spec.seamlessLoopLengths(maximum: available).last ?? 1
            design.loopStartFrame = 0

            let sample = try await extractor.composedFrames(
                startFrame: 0,
                count: min(design.loopFrameCount, 16)
            )
            let detection = MotionCropDetector().detect(frames: sample, screenSize: DeviceGeometry.screenPixelSize)
            design.animationCrop = detection.crop.isEmpty
                ? CGRect(origin: .zero, size: DeviceGeometry.screenPixelSize)
                : detection.crop

            library.save(design)
            library.reload()
            library.activeDesignID = design.id
            editing = library.designs.first { $0.id == design.id }
        } catch {
            importFailure = String(describing: error)
            Self.logger.error("import failed: \(String(describing: error), privacy: .public)")
        }
    }

    private enum ImportError: Error, CustomStringConvertible {
        case noMediaData
        var description: String {
            "The picked item did not provide any data. Choose a video or an animated GIF."
        }
    }
}

private struct DesignRow: View {
    let design: DesignDocument
    let manifest: BuildManifest?
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                Image(systemName: manifest == nil ? "hourglass" : "play.rectangle.fill")
                    .foregroundStyle(.secondary)
            }
            .frame(width: 44, height: 60)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(design.name).font(.headline)
                    if isActive {
                        Image(systemName: "house.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Shown on home")
                    }
                }
                Text("\(design.widgetSize.title) · \(design.tiles.count) app\(design.tiles.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let manifest {
                    Text("Built \(manifest.builtAt.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: Int64(manifest.totalFontBytes), countStyle: .file))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not built yet")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.caption)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct EmptyLibraryView: View {
    let isImporting: Bool

    var body: some View {
        ContentUnavailableView {
            Label("No designs yet", systemImage: "wand.and.stars")
        } description: {
            Text("Import a short looping video. Motionary composes it to your Home Screen, lets you place app shortcuts on it, and builds an animated widget.")
        }
        .opacity(isImporting ? 0.3 : 1)
    }
}

struct FailureView: View {
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text(message).font(.footnote).monospaced()
        }
    }
}

extension Bundle {
    var shortVersion: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

struct ProgressOverlay: View {
    let caption: String
    var fraction: Double?

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 12) {
                if let fraction {
                    ProgressView(value: fraction).frame(width: 180)
                } else {
                    ProgressView()
                }
                Text(caption).font(.callout)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}
