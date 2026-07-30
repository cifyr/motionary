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
        if CommandLine.arguments.contains("--install-starred") {
            HeadlessBuild.installStarred(deviceID: HeadlessBuild.device(in: CommandLine.arguments))
        }
        if CropAnalysis.requested(in: CommandLine.arguments) {
            CropAnalysis.run()
        }
        if CommandLine.arguments.contains("--rebuild-starred") {
            HeadlessBuild.rebuildStarred(deviceID: HeadlessBuild.device(in: CommandLine.arguments))
        }
        if let source = HeadlessBuild.requested(in: CommandLine.arguments) {
            HeadlessBuild.run(source: source)
        }
    }

    var body: some Scene {
        Window("Motionary Studio", id: "studio") {
            StudioView()
        }
        // Was .contentSize, which pinned the window to a fixed-width column.
        // The split view needs to be draggable to be worth having.
        .windowResizability(.contentMinSize)
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

    /// Bundles and installs every starred design that has a build, without
    /// making a new one. Rebuilding the phone from what is starred is a job in
    /// its own right, and going through a fresh clip to trigger it would leave
    /// a design behind that nobody asked for.
    static func installStarred(deviceID: String?) -> Never {
        guard let root = ProjectLocator.find(), let store = try? StudioPipeline.openStore() else {
            FileHandle.standardError.write(Data("failed: no project or store\n".utf8))
            exit(1)
        }
        var bundled: [BundleWriter.Bundled] = []
        var skipped: [String] = []
        for design in StudioPipeline.saved() where design.isStarred {
            if let manifest = try? store.loadManifest(id: design.id) {
                bundled.append(.init(name: design.name, folder: store.folder(for: design.id), manifest: manifest))
            } else {
                skipped.append(design.name)
            }
        }
        for name in skipped {
            FileHandle.standardError.write(Data("... \(name) is starred but has no build - skipped\n".utf8))
        }
        guard !bundled.isEmpty else {
            FileHandle.standardError.write(Data("failed: nothing starred has a build\n".utf8))
            exit(1)
        }

        do {
            let writer = try BundleWriter(projectRoot: root)
            let result = try writer.install(
                bundled,
                iconsFolder: StudioPipeline.iconsFolder(for: store)
            )
            print("bundled \(bundled.count) designs, \(result.fontCount) fonts, \(result.totalBytes / 1_048_576)MB")
            for design in bundled { print("  - \(design.name)") }

            let installer = DeviceInstaller(projectRoot: root)
            try installer.regenerateProject { FileHandle.standardError.write(Data("... \($0)\n".utf8)) }
            if let deviceID {
                let warning = try installer.installAndLaunch(deviceID: deviceID) {
                    FileHandle.standardError.write(Data("... \($0)\n".utf8))
                }
                if let warning { print(warning) }
            }
            exit(0)
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
                exit(1)
            }
            exit(0)
        }
        // Parked servicing the main queue rather than blocked on a semaphore:
        // baking the tiles into the wallpaper needs the main actor, and a
        // blocked main thread would never let it run.
        dispatchMain()
    }

    /// Regenerates every starred design, then bundles them all.
    ///
    /// A design's wallpaper is written by its build, so a layout made before the
    /// tiles were baked into it needs another pass to get them. In the editor
    /// that is an open-edit-build cycle per design.
    static func rebuildStarred(deviceID: String?) -> Never {
        guard let root = ProjectLocator.find() else {
            FileHandle.standardError.write(Data("failed: no Motionary project found\n".utf8))
            exit(1)
        }
        let starred = StudioPipeline.saved().filter(\.isStarred)
        guard !starred.isEmpty else {
            FileHandle.standardError.write(Data("failed: nothing is starred\n".utf8))
            exit(1)
        }
        let pipeline = StudioPipeline(projectRoot: root, model: .default)

        Task.detached {
            let report: @Sendable (StudioPipeline.Stage) -> Void = { stage in
                FileHandle.standardError.write(Data("... \(stage.caption)\n".utf8))
            }
            for design in starred {
                do {
                    let prepared = try await pipeline.reopen(design)
                    let built = try await pipeline.generate(prepared, loopSeconds: nil, onStage: report)
                    print("rebuilt \(design.name): \(built.summary)")
                } catch {
                    FileHandle.standardError.write(Data("failed: \(design.name): \(error)\n".utf8))
                    exit(1)
                }
            }
            installStarred(deviceID: deviceID)
        }
        dispatchMain()
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
    /// The design being renamed, and the text field's working copy. Held apart
    /// from `saved` so an abandoned rename changes nothing.
    @State private var renaming: DesignDocument?
    @State private var renamedTo = ""
    @State private var designFilter = ""
    @State private var targeting = false

    @State private var projectRoot: URL? = ProjectLocator.find()

    private var isBusy: Bool { stage != nil }

    /// Library on the left, the design being worked on to the right.
    ///
    /// It was one fixed-width column with the library wedged into the middle of
    /// it, so the list competed for height with the drop target, the settings
    /// and the build controls, and every one of them lost. A split view gives
    /// the library its own resizable column and lets the work take the rest.
    var body: some View {
        NavigationSplitView {
            librarySidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        } detail: {
            ScrollView {
                workColumn.padding(24)
            }
            .frame(minWidth: 480)
        }
        .frame(minWidth: 860, minHeight: 640)
        .task {
            refreshDevices()
            StudioPipeline.migrateLegacyDesigns()
            saved = StudioPipeline.saved()
        }
        .sheet(item: $renaming) { design in
            VStack(alignment: .leading, spacing: 12) {
                Text("Rename design").font(.headline)
                TextField("Name", text: $renamedTo)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit { commitRename() }
                HStack {
                    Spacer()
                    Button("Cancel") { renaming = nil }.keyboardShortcut(.cancelAction)
                    Button("Rename") { commitRename() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(renamedTo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
            .onAppear { renamedTo = design.name }
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
    /// Everything that is about making *this* design.
    private var workColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            dropTarget
            settings
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
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    private var filteredDesigns: [DesignDocument] {
        let query = designFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return saved }
        return saved.filter { $0.name.lowercased().contains(query) }
    }

    private var librarySidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Designs").font(.headline)
                    Text("\(saved.count)")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.secondary.opacity(0.15), in: Capsule())
                    Spacer()
                    Button("Import...") { importDesign() }.buttonStyle(.link)
                }
                // Only once the list is long enough to need it: a filter field
                // over four designs is furniture.
                if saved.count > 6 {
                    TextField("Filter", text: $designFilter)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if saved.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No designs yet.").font(.callout)
                    Text("Drop a video or GIF on the right to make one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
                Spacer()
            } else {
                // Takes the column's whole height now, rather than the 190pt it
                // could spare while sharing one column with everything else.
                List {
                    ForEach(filteredDesigns) { design in
                        designRow(design)
                            .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
                    }
                }
                .listStyle(.sidebar)

                if filteredDesigns.isEmpty, !designFilter.isEmpty {
                    Text("Nothing matches \"\(designFilter)\".")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(12)
                }
            }

            Divider()
            Text("Starred designs are compiled into the app, and the phone switches between them. About 29MB each.")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(12)
        }
        .disabled(isBusy)
    }

    private func designRow(_ design: DesignDocument) -> some View {
        HStack(spacing: 8) {
            Button {
                toggleStar(design)
            } label: {
                Image(systemName: design.isStarred ? "star.fill" : "star")
                    .foregroundStyle(design.isStarred ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .help("Compile this design into the app")

            Button { reopen(design) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(design.name).lineLimit(1).font(.callout)
                    HStack(spacing: 6) {
                        Text(count(design.tiles.count, "app"))
                        if !design.assets.isEmpty {
                            Text("·")
                            Text(count(design.assets.count, "picture"))
                        }
                        Text("·")
                        Text(design.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(design.name)")

            // Visible rather than context-menu only: a right-click is not
            // where anyone looks first for renaming or deleting a project.
            Button { renaming = design } label: { Image(systemName: "pencil") }
                .buttonStyle(.plain).help("Rename")
            Button { duplicate(design) } label: { Image(systemName: "plus.square.on.square") }
                .buttonStyle(.plain).help("Duplicate")
            Button { delete(design) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).help("Delete (moved to the archive folder, not erased)")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu {
            Button(design.isStarred ? "Unstar" : "Star") { toggleStar(design) }
            Button("Rename...") { renaming = design }
            Button("Duplicate") { duplicate(design) }
            Divider()
            Button("Export...") { exportDesign(design) }
            Button("Delete", role: .destructive) { delete(design) }
        }
    }

    private func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }

    /// A copy is the safe way to try a variation: the design that already
    /// builds stays exactly as it is.
    private func duplicate(_ design: DesignDocument) {
        guard let store = try? StudioPipeline.openStore() else { return }
        do {
            let copy = try store.duplicate(design)
            saved = StudioPipeline.saved()
            done = "Duplicated as \(copy.name). It carries the clip, the background and the pictures, but not the build."
            failure = nil
        } catch {
            failure = "Could not duplicate \(design.name): \(error)"
        }
    }

    private func commitRename() {
        guard let design = renaming else { return }
        let trimmed = renamedTo.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !trimmed.isEmpty, trimmed != design.name else { return }
        guard let store = try? StudioPipeline.openStore() else { return }

        var updated = design
        updated.name = trimmed
        do {
            try store.save(updated)
            saved = StudioPipeline.saved()
        } catch {
            failure = "Could not rename \(design.name): \(error)"
        }
    }

    private func toggleStar(_ design: DesignDocument) {
        guard let store = try? StudioPipeline.openStore() else { return }
        var updated = design
        updated.isStarred.toggle()
        try? store.save(updated)
        saved = StudioPipeline.saved()
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
