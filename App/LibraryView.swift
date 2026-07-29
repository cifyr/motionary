import PhotosUI
import SwiftUI
import UIKit
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
    @State private var showingPhotosPicker = false
    @State private var restartNote: String?

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
                        // A plain button and the `.photosPicker` modifier, not
                        // a `PhotosPicker` in the menu: choosing a menu item
                        // dismisses the menu, which tears down the picker's
                        // presentation before it can appear, so the tap did
                        // nothing at all.
                        Button {
                            showingPhotosPicker = true
                        } label: {
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
            // No `photoLibrary:` argument, so the picker runs out of process
            // and needs no library authorisation at all. Reading one chosen
            // item never needed access to the whole library.
            .photosPicker(
                isPresented: $showingPhotosPicker,
                selection: $pickerItem,
                matching: .any(of: [.videos, .images])
            )
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
            .alert("Something went wrong", isPresented: Binding(
                get: { library.operationFailure != nil },
                set: { if !$0 { library.operationFailure = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(library.operationFailure ?? "")
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

            Section {
                if let store = library.store, let status = WidgetStatusLog.read(store: store) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            status.headline,
                            systemImage: status.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(status.succeeded ? Color.green : Color.orange)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)

                        // Plain text so it can be copied and pasted rather than
                        // photographed and squinted at.
                        Text(status.report)
                            .font(.system(size: 10, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)

                        Button {
                            UIPasteboard.general.string = status.report
                        } label: {
                            Label("Copy report", systemImage: "doc.on.doc")
                        }
                        .font(.footnote)
                    }
                    .padding(.vertical, 2)
                } else {
                    Text("No widget has rendered yet. Add a Motionary widget to the Home Screen.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Widget status")
            } footer: {
                Text("Written by the widget itself each time the system draws it.")
            }

            Section {
                LabeledContent(
                    "Widget frame",
                    value: "\(Int(DeviceGeometry.pixelSize.width))x\(Int(DeviceGeometry.pixelSize.height)) px"
                )
                .font(.caption)
                LabeledContent(
                    "Origin",
                    value: "\(Int(DeviceGeometry.origin.x)),\(Int(DeviceGeometry.origin.y))"
                )
                .font(.caption)
            } header: {
                Text("Calibration")
            } footer: {
                Text("Measured on an iPhone 17 Pro. Designs are cut for the tall portrait widget only.")
            }

            Section {
                let history = library.store.map { WidgetRenderLog.read(store: $0) } ?? []
                if history.isEmpty {
                    Text("No renders recorded yet.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(history.reversed().joined(separator: "\n"))
                        .font(.system(size: 9, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Recent renders")
            } footer: {
                Text("Newest first. Every render the widget attempts, so a good one cannot erase the record of a bad one.")
            }

            Section {
                if let active = library.activeDesign {
                    Toggle("Animate widget", isOn: Binding(
                        get: { active.animationEnabled },
                        set: { on in
                            var updated = active
                            updated.animationEnabled = on
                            library.save(updated)
                            WidgetCenterBridge.reloadAll()
                        }
                    ))
                    Text("Off shows the still picture. If the widget is black with this on and correct with it off, the animated layer is at fault rather than the picture.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                if let store = library.store,
                   let active = library.activeDesign,
                   let manifest = library.manifest(for: active) {
                    // Rendered in the app, where nothing is memory-capped and
                    // no snapshot sits in between. If the glyph draws here but
                    // the widget is black, the font is sound and the widget's
                    // environment is not; if it is black here too, the fonts
                    // this app generates are what iOS 27 will not draw.
                    LaneGlyphProbe(store: store, manifest: manifest, design: active)
                }

                Button {
                    restartWidget()
                } label: {
                    Label("Restart widget", systemImage: "arrow.clockwise")
                }
                if let note = restartNote {
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                }
            } header: {
                Text("Troubleshooting")
            } footer: {
                Text("Re-writes the selection, clears the last report, re-registers the fonts and asks the system for fresh timelines. Use this if the widget is showing something out of date.")
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.shortVersion)
                LabeledContent("Designs", value: "\(library.designs.count)")
            }
        }
        .listStyle(.insetGrouped)
    }

    /// Puts every piece of shared state the widget reads back into a known
    /// condition, in the order the widget reads them.
    private func restartWidget() {
        guard let store = library.store else {
            restartNote = "The shared container is unavailable, so there is nothing to restart."
            return
        }
        // Written again even when unchanged: the app group's defaults are
        // cached by cfprefsd, and a re-write is what makes the extension's copy
        // agree with this one.
        let resolved = library.activeDesign?.id
        ActiveDesign.identifier = resolved
        WidgetStatusLog.clear(store: store)
        WidgetRenderLog.clear(store: store)
        library.reload()
        WidgetCenterBridge.reloadAll()

        let name = library.activeDesign?.name ?? "no design"
        restartNote = "Restarted at \(Date().formatted(date: .omitted, time: .standard)), showing \(name). "
            + "Give the Home Screen a few seconds."
        Self.logger.info("widget restarted; selection=\(resolved?.uuidString ?? "none", privacy: .public)")
    }

    private func importPicked(_ item: PhotosPickerItem) async {
        importing = true
        defer {
            importing = false
            pickerItem = nil
        }
        do {
            // A file first, then raw bytes. Photos vends a video as a file, and
            // asking for `Data` pulls the whole clip into memory, which is why
            // longer videos came back empty. The error used to be discarded by
            // `try?` and reported as "no data", which said nothing about why.
            if let picked = try await item.loadTransferable(type: PickedFile.self) {
                defer { try? FileManager.default.removeItem(at: picked.url) }
                let data = try Data(contentsOf: picked.url, options: .mappedIfSafe)
                Self.logger.info("picked \(picked.originalName, privacy: .public), \(data.count) bytes")
                await ingest(data: data, preferredName: picked.originalName)
                return
            }
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw ImportError.noMediaData(offered: item.supportedContentTypes)
            }
            await ingest(data: data)
        } catch {
            importFailure = String(describing: error)
            Self.logger.error("photos import failed: \(String(describing: error), privacy: .public)")
        }
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
            // Loop length counts frames at the design's rate, not the
            // source's, and lands on the divisor nearest the natural loop.
            design.sourceDuration = summary.duration
            let natural = max(1, Int((summary.duration * Double(spec.framesPerSecond)).rounded()))
            design.loopFrameCount = spec.seamlessLoopLength(nearest: natural, maximum: 96)
            design.loopStartFrame = 0
            design.mediaTransform = MediaTransform.suggested(
                sourceSize: summary.naturalSize,
                screenSize: DeviceGeometry.screenPixelSize
            )
            Self.logger.info(
                "source \(Int(summary.naturalSize.width))x\(Int(summary.naturalSize.height)) at \(summary.nominalFrameRate)fps; loop \(design.loopFrameCount) frames; scale \(design.mediaTransform.scale)"
            )

            let sample = try await extractor.composedFrames(
                startFrame: 0,
                count: min(design.loopFrameCount, 16),
                frameRate: spec.framesPerSecond
            )
            // The detector works across the whole screen, so the motion it
            // finds can sit entirely outside the widget frame — and only
            // pixels inside that frame are ever drawn. Storing a disjoint crop
            // built a design that could never be built ("no animated area").
            let detection = MotionCropDetector().detect(frames: sample, screenSize: DeviceGeometry.screenPixelSize)
            design.animationCrop = DesignDocument.usableCrop(detection.crop, in: design.widgetRect)
            Self.logger.info(
                "motion \(String(describing: detection.crop), privacy: .public) -> crop \(String(describing: design.animationCrop), privacy: .public)"
            )

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
        case noMediaData(offered: [UTType])

        /// Names what Photos actually offered. "No data" on its own gave no way
        /// to tell a refused item from an unsupported one.
        var description: String {
            switch self {
            case .noMediaData(let offered):
                let list = offered.isEmpty ? "nothing" : offered.map(\.identifier).joined(separator: ", ")
                return "Photos would not hand this item over. It offered: \(list). "
                    + "Choose a video or an animated GIF."
            }
        }
    }
}

/// Receives a picked item as a file rather than as bytes in memory.
///
/// The copy is needed because the URL handed to the closure is only valid for
/// the duration of the call.
private struct PickedFile: Transferable {
    let url: URL
    let originalName: String

    /// GIF is listed before `.image` deliberately: the first matching
    /// representation wins, and a GIF taken as a generic image comes back as a
    /// single flattened frame with the animation gone.
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .gif) { try copy($0) }
        FileRepresentation(importedContentType: .movie) { try copy($0) }
        FileRepresentation(importedContentType: .image) { try copy($0) }
    }

    private static func copy(_ received: ReceivedTransferredFile) throws -> PickedFile {
        let original = received.file.lastPathComponent
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-\(UUID().uuidString)-\(original)")
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: received.file, to: destination)
        } catch {
            throw NSError(
                domain: "com.caden.Motionary.import", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Could not copy \(original) out of Photos: \(error)",
                    NSUnderlyingErrorKey: error,
                ]
            )
        }
        return PickedFile(url: destination, originalName: original)
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
                    Text("Not built yet - open and tap Build widget")
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

/// Renders the widget's own composition, animated, inside the app.
///
/// Deliberately not a hand-built probe. Two of those have now pointed at the
/// wrong thing because their glyph offsets were mine rather than the real
/// ones. This is the production CompositionView with the production manifest
/// and registry, so the only difference from the Home Screen is the process it
/// runs in — which is exactly the variable worth isolating.
///
/// The widget preview elsewhere in the app plays the preview MP4 instead, so it
/// never exercised the lane fonts at all.
private struct LaneGlyphProbe: View {
    let store: DesignStore
    let manifest: BuildManifest
    var design: DesignDocument?

    @State private var report: RuntimeFontRegistry.Report?
    @State private var wallpaper: Image?

    private static let previewScale: CGFloat = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Animated composition, drawn here in the app")
                .font(.caption.weight(.semibold))

            if let report {
                let viewport = design?.widgetRect ?? manifest.widgetRect
                let points = CGSize(
                    width: viewport.width / DeviceGeometry.scale,
                    height: viewport.height / DeviceGeometry.scale
                )
                CompositionView(
                    manifest: manifest,
                    tiles: design?.tiles ?? [],
                    viewport: viewport,
                    wallpaper: wallpaper,
                    wallpaperRect: manifest.backdropRect,
                    isAnimated: report.isUsable
                ) { tile, side in
                    TileView(tile: tile, side: side, iconImage: nil)
                }
                .frame(width: points.width, height: points.height)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .scaleEffect(Self.previewScale, anchor: .topLeading)
                .frame(
                    width: points.width * Self.previewScale,
                    height: points.height * Self.previewScale,
                    alignment: .topLeading
                )
            } else {
                ProgressView().frame(height: 80)
            }

            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
        .task {
            report = RuntimeFontRegistry.register(manifest: manifest, store: store)
            loadBackdrop()
        }
    }

    private func loadBackdrop() {
        let url = manifest.backdropRect == nil
            ? store.wallpaperURL(for: manifest.designID)
            : store.widgetBackdropURL(for: manifest.designID)
        let longest = manifest.backdropRect.map { Int(max($0.width, $0.height)) }
            ?? Int(max(manifest.screenSize.width, manifest.screenSize.height))
        wallpaper = ImageLoader.load(at: url, maxPixelSize: longest)
            .map { Image(decorative: $0, scale: 1) }
    }

    private var caption: String {
        guard let report else { return "Registering…" }
        guard report.isUsable else {
            return "Fonts unusable here too: \(report.resolvable)/\(report.requested) resolvable."
        }
        return "Animating here means the fonts are sound and the widget's process is the problem. "
            + "Still or black here means the fonts are, and the widget was never the issue."
    }
}
