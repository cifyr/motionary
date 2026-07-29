import SwiftUI
import UniformTypeIdentifiers

@main
struct MotionaryStudioApp: App {
    init() {
        // A window cannot be driven from a build script, and the pipeline is
        // the part worth checking, so it can also be run without one:
        //   MotionaryStudio.app/Contents/MacOS/MotionaryStudio --build clip.gif
        if CommandLine.arguments.contains("--roundtrip") {
            HeadlessBuild.roundTrip()
        }
        if let source = HeadlessBuild.requested(in: CommandLine.arguments) {
            HeadlessBuild.run(source: source)
        }
    }

    var body: some Scene {
        Window("Motionary Studio", id: "studio") {
            StudioView()
        }
        .windowResizability(.contentSize)
    }
}

/// Builds a design and prints what came out, without installing anything.
enum HeadlessBuild {
    static func requested(in arguments: [String]) -> URL? {
        guard let flag = arguments.firstIndex(of: "--build"),
              arguments.index(after: flag) < arguments.endIndex
        else { return nil }
        return URL(fileURLWithPath: arguments[arguments.index(after: flag)])
    }

    /// `--device <udid>` runs the whole job rather than stopping at the build.
    static func device(in arguments: [String]) -> String? {
        guard let flag = arguments.firstIndex(of: "--device"),
              arguments.index(after: flag) < arguments.endIndex
        else { return nil }
        return arguments[arguments.index(after: flag)]
    }

    /// Exports the newest design and imports it back, printing what survived.
    ///
    /// `DesignArchive` shells out to `ditto`, and `Process` does not exist on
    /// iOS - so the unit suite, which runs on the simulator, cannot cover this.
    /// A real round trip can, and does.
    static func roundTrip() -> Never {
        guard let store = try? StudioPipeline.openStore(),
              let design = StudioPipeline.saved().first
        else {
            FileHandle.standardError.write(Data("failed: no design to export\n".utf8))
            exit(1)
        }
        let archive = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("motionary-roundtrip.zip")
        do {
            try DesignArchive.export(design, store: store, to: archive)
            let size = (try? Data(contentsOf: archive).count) ?? 0
            print("exported \(design.name) -> \(size) bytes")

            let elsewhere = try DesignStore(containerURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("motionary-roundtrip-store-\(UUID().uuidString)", isDirectory: true))
            let restored = try DesignArchive.restore(from: archive, into: elsewhere)
            let clip = FileManager.default.fileExists(atPath: elsewhere.sourceVideoURL(for: restored).path)
            print("imported \(restored.name) tiles=\(restored.tiles.count) clip=\(clip) background=\(restored.backgroundName ?? "none")")
            print(restored.id == design.id && clip ? "roundtrip ok" : "roundtrip INCOMPLETE")
            exit(restored.id == design.id && clip ? 0 : 1)
        } catch {
            FileHandle.standardError.write(Data("failed: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run(source: URL) -> Never {
        guard let root = ProjectLocator.find() else {
            FileHandle.standardError.write(Data("failed: no Motionary project found\n".utf8))
            exit(1)
        }
        let pipeline = StudioPipeline(projectRoot: root, model: .default)
        let deviceID = device(in: CommandLine.arguments)
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var status: Int32 = 0

        Task.detached {
            do {
                let report: @Sendable (StudioPipeline.Stage) -> Void = { stage in
                    FileHandle.standardError.write(Data("... \(stage.caption)\n".utf8))
                }
                let outcome: StudioPipeline.Built
                if let deviceID {
                    outcome = try await pipeline.run(
                        source: source,
                        loopSeconds: nil,
                        deviceID: deviceID,
                        onStage: report
                    )
                } else if CommandLine.arguments.contains("--bundle") {
                    // `--bundle` writes the design into the project but
                    // installs nothing, so a build can be prepared and checked
                    // in a simulator with no phone anywhere near it.
                    outcome = try await pipeline.run(
                        source: source,
                        loopSeconds: nil,
                        deviceID: nil,
                        onStage: report
                    )
                } else {
                    let prepared = try await pipeline.prepare(source: source, onStage: report)
                    outcome = try await pipeline.generate(prepared, loopSeconds: nil, onStage: report)
                }
                print("built \(outcome.summary)")
                print("folder \(outcome.folder.path)")
            } catch {
                FileHandle.standardError.write(Data("failed: \(error)\n".utf8))
                status = 1
            }
            semaphore.signal()
        }
        semaphore.wait()
        exit(status)
    }
}

/// Drop a clip, pick a phone, press the button.
///
/// Everything else this project can do - trimming, tiles, quality - is chosen
/// automatically here, because the one thing that matters is that a design
/// reaches the Home Screen, and that requires a compile. Options can come back
/// once the boring case works in one press.
struct StudioView: View {
    @State private var source: URL?
    @State private var model = DeviceModel.default
    @State private var devices: [ConnectedDevice] = []
    @State private var deviceID: String?
    @State private var loopSeconds: Double = 0

    @State private var prepared: StudioPipeline.Prepared?
    @State private var stage: StudioPipeline.Stage?
    @State private var failure: String?
    @State private var done: String?
    @State private var log: [String] = []
    @State private var wallpaper: URL?
    @State private var saved: [DesignDocument] = []
    @State private var targeting = false

    @State private var projectRoot: URL? = ProjectLocator.find()

    private var isBusy: Bool { stage != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            dropTarget
            settings
            if !saved.isEmpty { savedDesigns }
            actions
            if let stage { progress(stage) }
            if let done { message(done, tint: .green) }
            if let wallpaper {
                HStack(spacing: 12) {
                    Button("Save wallpaper...") { exportWallpaper(wallpaper) }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([wallpaper])
                    }
                }
            }
            if let failure { message(failure, tint: .red) }
        }
        .padding(24)
        .frame(width: 520)
        .task {
            refreshDevices()
            StudioPipeline.migrateLegacyDesigns()
            saved = StudioPipeline.saved()
        }
        .sheet(item: Binding(
            get: { prepared.map { EditorSheet(prepared: $0) } },
            set: { if $0 == nil { prepared = nil } }
        )) { sheet in
            EditorWindow(
                prepared: sheet.prepared,
                model: model,
                // Saved on the way out either way: closing the editor should
                // not be the thing that loses an afternoon's placement.
                onCancel: { edited in
                    try? edited.store.save(edited.design)
                    prepared = nil
                    saved = StudioPipeline.saved()
                },
                onBuild: { edited in
                    try? edited.store.save(edited.design)
                    prepared = nil
                    install(edited)
                }
            )
        }
    }

    /// Reopening keeps the placement. Deriving a design from the clip again
    /// would put every tile back in the middle of the frame.
    private var savedDesigns: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Edit an existing design").font(.caption.weight(.semibold))
                Spacer()
                Button("Import...") { importDesign() }.buttonStyle(.link)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(saved) { design in
                        Button { reopen(design) } label: {
                            HStack {
                                Text(design.name).lineLimit(1)
                                Spacer()
                                Text("\(design.tiles.count) app\(design.tiles.count == 1 ? "" : "s")")
                                    .foregroundStyle(.secondary)
                                Text(design.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.callout)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Export...") { exportDesign(design) }
                            Button("Delete", role: .destructive) { delete(design) }
                        }
                    }
                }
            }
            .frame(maxHeight: 88)
        }
        .disabled(isBusy)
    }

    private func exportDesign(_ design: DesignDocument) {
        guard let store = try? StudioPipeline.openStore() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(design.name).motionary.zip"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            try DesignArchive.export(design, store: store, to: target)
            done = "Exported \(design.name). It carries the clip, the background and the skins it uses."
            failure = nil
        } catch {
            failure = "Could not export: \(error)"
        }
    }

    private func importDesign() {
        guard let store = try? StudioPipeline.openStore() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            let design = try DesignArchive.restore(from: source, into: store)
            saved = StudioPipeline.saved()
            done = "Imported \(design.name). Open it to edit or build."
            failure = nil
        } catch {
            failure = "Could not import: \(error)"
        }
    }

    private func delete(_ design: DesignDocument) {
        // Archived rather than removed: a design is somebody's layout, and the
        // list is long enough to make a mis-click easy.
        guard let store = try? StudioPipeline.openStore() else { return }
        try? store.archive(id: design.id)
        saved = StudioPipeline.saved()
    }

    private func reopen(_ design: DesignDocument) {
        guard let projectRoot else { return }
        done = nil
        failure = nil
        stage = .preparing
        let pipeline = StudioPipeline(projectRoot: projectRoot, model: model)
        Task {
            do {
                let ready = try await pipeline.reopen(design)
                await MainActor.run {
                    stage = nil
                    prepared = ready
                }
            } catch {
                await MainActor.run {
                    stage = nil
                    failure = String(describing: error)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Motionary Studio").font(.title2.bold())
            Text("A clip becomes a Home Screen widget. The fonts have to be compiled into the app, so this builds and installs it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dropTarget: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(
                targeting ? Color.accentColor : Color.secondary.opacity(0.4),
                style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
            )
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(targeting ? Color.accentColor.opacity(0.08) : Color.clear)
            )
            .frame(height: 96)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: source == nil ? "square.and.arrow.down" : "film")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(source?.lastPathComponent ?? "Drop a video or GIF")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $targeting) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        source = url
                        done = nil
                        failure = nil
                    }
                }
                return true
            }
            .onTapGesture { chooseFile() }
            .disabled(isBusy)
    }

    private var settings: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("iPhone")
                Picker("", selection: $model) {
                    ForEach(DeviceModel.all) { Text($0.name).tag($0) }
                }
                .labelsHidden()
            }
            GridRow {
                Text("Device")
                HStack {
                    Picker("", selection: $deviceID) {
                        Text(devices.isEmpty ? "None connected" : "Choose").tag(String?.none)
                        ForEach(devices) { Text($0.name).tag(String?.some($0.id)) }
                    }
                    .labelsHidden()
                    Button("Refresh") { refreshDevices() }
                }
            }
            GridRow {
                Text("Loop")
                HStack {
                    Slider(value: $loopSeconds, in: 0 ... 6, step: 0.1)
                    Text(loopSeconds == 0 ? "As recorded" : String(format: "%.1fs", loopSeconds))
                        .monospacedDigit()
                        .frame(width: 90, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(isBusy)
    }

    private var actions: some View {
        HStack {
            Button(prepared == nil ? "Edit layout" : "Editing...") { start() }
                .keyboardShortcut(.defaultAction)
                .disabled(source == nil || isBusy)
            if projectRoot == nil {
                Button("Choose project folder") { chooseProject() }
            }
            Spacer()
            if !log.isEmpty {
                Text(log.last ?? "")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }

    private func progress(_ stage: StudioPipeline.Stage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: stage.fraction)
            Text(stage.caption).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func message(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(tint)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .gif, .quickTimeMovie, .mpeg4Movie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { source = panel.url }
    }

    /// Copies the wallpaper out rather than moving it: the built folder is
    /// scratch and gets replaced by the next build.
    private func exportWallpaper(_ source: URL) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Motionary wallpaper.png"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: source, to: target)
        } catch {
            failure = "Could not save the wallpaper: \(error)"
        }
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard ProjectLocator.isProject(url) else {
            failure = "\(url.lastPathComponent) has no project.yml in it."
            return
        }
        ProjectLocator.remember(url)
        projectRoot = url
        failure = nil
        refreshDevices()
    }

    private func refreshDevices() {
        guard let projectRoot else {
            failure = "No Motionary project found. Choose the folder holding project.yml."
            return
        }
        do {
            devices = try DeviceInstaller(projectRoot: projectRoot).connectedDevices()
            if deviceID == nil { deviceID = devices.first?.id }
        } catch {
            failure = String(describing: error)
        }
    }

    /// Reads the clip and opens the editor. Nothing is generated yet: the
    /// crop and the placement are baked into the glyphs, so they have to be
    /// settled before the fonts exist.
    private func start() {
        guard let source, let projectRoot else { return }
        done = nil
        failure = nil
        log = []
        stage = .preparing

        let pipeline = StudioPipeline(projectRoot: projectRoot, model: model)
        Task {
            do {
                let ready = try await pipeline.prepare(source: source) { stage in
                    Task { @MainActor in self.stage = stage }
                }
                await MainActor.run {
                    self.stage = nil
                    self.prepared = ready
                }
            } catch {
                await MainActor.run {
                    self.stage = nil
                    self.failure = String(describing: error)
                }
            }
        }
    }

    private func install(_ edited: StudioPipeline.Prepared) {
        guard let projectRoot else { return }
        stage = .preparing
        let pipeline = StudioPipeline(projectRoot: projectRoot, model: model)
        let loop = loopSeconds
        let device = deviceID
        Task {
            do {
                let built = try await pipeline.install(
                    edited,
                    loopSeconds: loop > 0 ? loop : nil,
                    deviceID: device
                ) { stage in
                    Task { @MainActor in
                        self.stage = stage
                        log.append(stage.caption)
                    }
                }
                await MainActor.run {
                    self.stage = nil
                    self.saved = StudioPipeline.saved()
                    self.wallpaper = FileManager.default.fileExists(atPath: built.wallpaperURL.path)
                        ? built.wallpaperURL
                        : nil
                    if let warning = built.warning {
                        self.done = "\(warning) \(built.summary)."
                    } else {
                        self.done = device == nil
                            ? "Built into the app. \(built.summary). Connect the phone and press again to install."
                            : "Installed. \(built.summary). Add the Motionary widget if it is not already on the Home Screen."
                    }
                }
            } catch {
                await MainActor.run {
                    self.stage = nil
                    self.failure = String(describing: error)
                }
            }
        }
    }
}


/// Identifiable wrapper so the editor can be presented as a sheet.
private struct EditorSheet: Identifiable {
    let prepared: StudioPipeline.Prepared
    var id: UUID { prepared.design.id }
}

private struct EditorWindow: View {
    @State var prepared: StudioPipeline.Prepared
    let model: DeviceModel
    let onCancel: (StudioPipeline.Prepared) -> Void
    let onBuild: (StudioPipeline.Prepared) -> Void

    var body: some View {
        VStack(spacing: 0) {
            LayoutEditor(
                design: $prepared.design,
                model: model,
                poster: prepared.poster,
                store: prepared.store
            )
            Divider()
            HStack {
                Button("Close") { onCancel(prepared) }
                Spacer()
                Button("Build and install") { onBuild(prepared) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(
            width: LayoutEditor.width(for: model),
            height: LayoutEditor.height(for: model) + 60
        )
    }
}
