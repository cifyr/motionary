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
        .commands { StudioCommands() }
        // Every screen carries its own bar, so the window's was a second one
        // stacked above it. The traffic lights now sit in the screen's bar.
        .windowStyle(.hiddenTitleBar)
        // Was .contentSize, which pinned the window to a fixed-width column.
        // The split view needs to be draggable to be worth having.
        .windowResizability(.contentMinSize)
        // A first launch opens at a size the library is actually usable at.
        // Without it the window inherits whatever frame was last restored,
        // which after one bad build was 146x151 and stayed there.
        .defaultSize(width: 1280, height: 900)

        Window("Welcome to Motionary Studio", id: StudioHelp.welcomeWindow) {
            WelcomeView()
        }
        .windowResizability(.contentSize)

        Window("Motionary Studio Guide", id: StudioHelp.guideWindow) {
            GuideView()
        }
        .defaultSize(width: 820, height: 560)
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
                iconsFolder: StudioPipeline.iconsFolder(for: store),
                store: store
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
    /// The design a delete has been asked for but not yet confirmed.
    @State private var deleting: DesignDocument?
    @State private var targeting = false

    /// The job in flight, or the one that just finished and has not been
    /// dismissed. Set for every long run so one of them can never be described
    /// by whatever screen happens to be underneath it.
    @State private var run: StudioRun?
    /// Install all asks where it is going before it goes.
    @State private var choosingInstall = false

    @State private var projectRoot: URL? = ProjectLocator.find()
    /// The run in flight, kept so Escape can stop it.
    @State private var buildTask: Task<Void, Never>?

    @Environment(\.openWindow) private var openWindow
    @AppStorage(StudioHelp.seenWelcomeKey) private var hasSeenWelcome = false

    /// The card selected on the home screen. Distinct from `prepared`: picking
    /// a design is not the same as opening it, and a single click should not
    /// throw you into the editor.
    @State private var homeSelection: UUID?
    /// Held rather than remade per redraw: the home draws a card per design and
    /// each one asks the store where its picture lives.
    ///
    /// `openStore()`, not `DesignStore()`. The plain initialiser roots itself in
    /// the app group, which the studio has no entitlement for — and rather than
    /// failing it quietly creates an empty container somewhere else, so every
    /// card came back "no clip yet, not built" while the sidebar beside it
    /// listed the same designs perfectly well.
    @State private var library: DesignStore? = try? StudioPipeline.openStore()

    private var isBusy: Bool { stage != nil }

    /// The designs that ship with Studio. Held as a set because every card asks.
    private var starterIDs: Set<UUID> {
        Set(saved.filter(\.isStarter).map(\.id))
    }

    /// One screen at a time.
    ///
    /// There was a sidebar listing every design beside all of this, from when
    /// the library was a list of names. Once the library became a shelf of
    /// pictures the sidebar was the same content twice, in a worse form, taking
    /// 320pt off the thing it was duplicating — so the library is the way
    /// around now, and every screen carries one button back to it.
    var body: some View {
        Group {
            // First, so nothing in flight can fall through to a screen about
            // some other job.
            if let run {
                StudioRunView(
                    run: run,
                    stage: stage,
                    log: log,
                    done: done,
                    failure: failure,
                    wallpaper: wallpaper,
                    onStop: { stopBuild() },
                    onSaveWallpaper: { exportWallpaper($0) },
                    onRevealWallpaper: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
                    onFinish: { clearRun() }
                )
                .frame(minWidth: 480)
            } else if let ready = prepared {
                EditorWindow(
                    prepared: ready,
                    model: model,
                    // Saved on the way out either way: leaving the editor should
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
                // Keyed on the design: EditorWindow holds its working copy in
                // @State, and without this SwiftUI would reuse the view when a
                // second design is opened and go on showing the first one's.
                .id(ready.design.id)
            } else if source != nil || isBusy {
                // A clip is in hand, or a run is going: the workspace is what
                // there is to say. Otherwise the library is a better landing
                // place than an empty drop target.
                VStack(spacing: 0) {
                    workspaceBar
                    Divider()
                    ScrollView {
                        workColumn
                            .padding(24)
                            .background(
                                StudioTheme.panel,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(StudioTheme.headerEdge, lineWidth: 1)
                            }
                            // Capped, then centred. Left to fill, the controls
                            // stretched into a form the width of the window.
                            .frame(maxWidth: 620)
                            .frame(maxWidth: .infinity)
                            .padding(28)
                    }
                }
                // Not the canvas wash. This screen holds controls, not artwork,
                // and a fixed-dark well behind a light panel was the single
                // worst thing in the app to look at.
                .background(StudioTheme.libraryBackground)
                .frame(minWidth: 480)
            } else if let library {
                StudioHome(
                    designs: saved,
                    starterIDs: starterIDs,
                    store: library,
                    model: model,
                    selection: $homeSelection,
                    actions: designActions,
                    onNew: { chooseFile() },
                    onImport: { importDesign() },
                    onImportFile: { importDesign(from: $0) },
                    onInstallAll: {
                        refreshDevices()
                        choosingInstall = true
                    },
                    installAllState: installAllState
                )
                .frame(minWidth: 480)
            } else {
                ContentUnavailableView(
                    "The design library is unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Studio could not open its container in Application Support.")
                )
                .frame(minWidth: 480)
            }
        }
        .frame(minWidth: 880, minHeight: 700)
        .tint(StudioTheme.accent)
        // Escape stops a run wherever the focus happens to be.
        .onExitCommand { stopBuild() }
        .task {
            refreshDevices()
            StudioPipeline.migrateLegacyDesigns()
            StudioPipeline.markStarters()
            saved = StudioPipeline.saved()
            // A greeting, not a thing to dismiss every launch.
            if !hasSeenWelcome { openWindow(id: StudioHelp.welcomeWindow) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .studioNewDesign)) { _ in
            guard !isBusy else { return }
            chooseFile()
        }
        // Only when no editor is open. When one is, it answers this itself and
        // saves its own copy of the design on the way out.
        .onReceive(NotificationCenter.default.publisher(for: .studioGoHome)) { _ in
            guard prepared == nil, !isBusy else { return }
            source = nil
            wallpaper = nil
            done = nil
            failure = nil
        }
        .alert(item: $deleting) { design in
            Alert(
                title: Text("Delete \"\(design.name)\"?"),
                message: Text("It moves to the Archive folder rather than being erased, but it leaves the library."),
                primaryButton: .destructive(Text("Delete")) { delete(design) },
                secondaryButton: .cancel()
            )
        }
        .sheet(isPresented: $choosingInstall) {
            InstallSheet(
                included: buildableStarred.included,
                skipped: buildableStarred.skipped,
                model: $model,
                deviceID: $deviceID,
                devices: devices,
                onRefresh: { refreshDevices() },
                onCancel: { choosingInstall = false },
                onInstall: {
                    choosingInstall = false
                    installStarred()
                }
            )
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
            .foregroundStyle(StudioTheme.text)
            .background(StudioTheme.panel)
            .tint(StudioTheme.accent)
            .onAppear { renamedTo = design.name }
        }
    }

    /// The workspace's own bar, carrying the way back.
    ///
    /// Dropping a clip used to be a one-way door: the library was still in the
    /// sidebar but the detail pane never returned to it, so the only way out
    /// was to finish a build or quit.
    private var workspaceBar: some View {
        HStack(spacing: 10) {
            Button { goHome() } label: {
                Label("Library", systemImage: "chevron.left")
            }
            .buttonStyle(.studioCompact)
            .disabled(isBusy)
            .help(isBusy ? "Stop the build first" : "Back to the library")

            Text(source?.lastPathComponent ?? "New design")
                .font(StudioTheme.bodyStrong)
                .foregroundStyle(StudioTheme.textBright)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(StudioTheme.headerFill)
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
                        .buttonStyle(.studio)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([wallpaper])
                    }
                    .buttonStyle(.studio)
                }
            }
            if let failure { message(failure, tint: .red) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 620, alignment: .leading)
    }


    /// One set of verbs, shared by the library grid and its context menus.
    private var designActions: DesignActions {
        DesignActions(
            open: { reopen($0) },
            toggleStar: { toggleStar($0) },
            duplicate: { duplicate($0) },
            rename: {
                renaming = $0
                renamedTo = $0.name
            },
            export: { exportDesign($0) },
            delete: { deleting = $0 }
        )
    }

    /// Asks the detail pane to hand back to the library rather than clearing it
    /// from here — see `studioGoHome` for why reaching past the editor loses
    /// work.
    private func goHome() {
        guard !isBusy else { return }
        if run != nil {
            clearRun()
            return
        }
        NotificationCenter.default.post(name: .studioGoHome, object: nil)
    }

    /// Dismisses a finished run. Its result goes with it: a wallpaper button
    /// for a build two designs ago is worse than none.
    private func clearRun() {
        run = nil
        source = nil
        wallpaper = nil
        done = nil
        failure = nil
        log = []
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
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let source = panel.url else { return }
        importDesign(from: source)
    }

    /// The one importer. Both the panel and a file dropped on the library end
    /// up here, so an archive behaves the same however it arrived.
    private func importDesign(from source: URL) {
        guard let store = try? StudioPipeline.openStore() else { return }
        do {
            let design = try DesignArchive.restore(from: source, into: store)
            saved = StudioPipeline.saved()
            DesignThumbnail.forget(design.id)
            done = "Imported \(design.name). Open it to edit or build."
            failure = nil
        } catch {
            failure = "Could not import \(source.lastPathComponent): \(error)"
        }
    }

    /// The starred designs, split by whether they have a build to install.
    /// Starred and never built is the one case a count on its own hides.
    private var buildableStarred: (included: [DesignDocument], skipped: [DesignDocument]) {
        let store = try? StudioPipeline.openStore()
        let starred = saved.filter(\.isStarred)
        let included = starred.filter { (try? store?.loadManifest(id: $0.id)) != nil }
        let includedIDs = Set(included.map(\.id))
        return (included, starred.filter { !includedIDs.contains($0.id) })
    }

    /// What the Install all button can do right now.
    private var installAllState: StudioHome.InstallAllState {
        let starred = saved.filter(\.isStarred)
        return .init(
            starred: starred.count,
            buildable: buildableStarred.included.count,
            deviceName: devices.first { $0.id == deviceID }?.name,
            isBusy: isBusy
        )
    }

    /// Puts every starred design that has a build onto the phone.
    ///
    /// The same job `--install-starred` does, without making a new design on
    /// the way: rebuilding the phone from what is starred is its own task, and
    /// going through a fresh clip to trigger it would leave a design behind
    /// that nobody asked for.
    private func installStarred() {
        if projectRoot == nil { chooseProject() }
        guard let projectRoot else {
            failure = String(describing: StudioPipelineError.noProjectFolder)
            return
        }
        guard let store = try? StudioPipeline.openStore() else { return }

        var bundled: [BundleWriter.Bundled] = []
        var skipped: [String] = []
        for design in saved where design.isStarred {
            if let manifest = try? store.loadManifest(id: design.id) {
                bundled.append(.init(
                    name: design.name,
                    folder: store.folder(for: design.id),
                    manifest: manifest
                ))
            } else {
                skipped.append(design.name)
            }
        }
        guard !bundled.isEmpty else {
            failure = "Nothing starred has a build yet. Open a design and build it first."
            return
        }

        let device = deviceID
        done = nil
        failure = nil
        log = []
        wallpaper = nil
        run = .installing(count: bundled.count)
        stage = .bundling
        buildTask = Task {
            do {
                let writer = try BundleWriter(projectRoot: projectRoot)
                let result = try writer.install(
                    bundled,
                    iconsFolder: StudioPipeline.iconsFolder(for: store),
                    store: store
                )
                let installer = DeviceInstaller(projectRoot: projectRoot)
                // Reported rather than left on one stage for the whole run: the
                // steps are the only thing making a four-minute wait legible.
                await MainActor.run { self.stage = .installing("Regenerating the Xcode project") }
                try installer.regenerateProject { caption in
                    Task { @MainActor in log.append(caption) }
                }
                var warning: String?
                if let device {
                    await MainActor.run { self.stage = .installing("Installing on the phone") }
                    warning = try installer.installAndLaunch(deviceID: device) { caption in
                        Task { @MainActor in log.append(caption) }
                    }
                }
                await MainActor.run {
                    self.stage = nil
                    let megabytes = result.totalBytes / 1_048_576
                    var summary = "Installed \(bundled.count) design\(bundled.count == 1 ? "" : "s")"
                    summary += ", \(result.fontCount) fonts, \(megabytes)MB."
                    if !skipped.isEmpty {
                        summary += " Skipped \(skipped.joined(separator: ", ")) — starred but not built."
                    }
                    self.done = [warning, summary].compactMap { $0 }.joined(separator: " ")
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.stage = nil
                    self.done = "Install stopped. Nothing was changed on the phone."
                }
            } catch {
                await MainActor.run {
                    self.stage = nil
                    self.failure = String(describing: error)
                }
            }
            await MainActor.run { self.buildTask = nil }
        }
    }

    private func delete(_ design: DesignDocument) {
        // Archived rather than removed: a design is somebody's layout, and the
        // list is long enough to make a mis-click easy.
        guard let store = try? StudioPipeline.openStore() else { return }
        try? store.archive(id: design.id)
        saved = StudioPipeline.saved()
    }

    /// No project folder needed: opening a layout reads the design and its clip
    /// out of Application Support. This used to return here when the folder was
    /// unset, so clicking a design did nothing at all and said nothing about
    /// why. Building still needs it, and says so when it is missing.
    private func reopen(_ design: DesignDocument) {
        done = nil
        failure = nil
        run = .opening(design.name)
        stage = .preparing
        let pipeline = StudioPipeline(projectRoot: projectRoot, model: model)
        // Held, not fired and forgotten: Stop and Escape both go through
        // `buildTask`, so a run nobody kept was one nobody could get out of.
        buildTask = Task {
            do {
                let ready = try await pipeline.reopen(design)
                await MainActor.run {
                    stage = nil
                    run = nil
                    prepared = ready
                }
            } catch is CancellationError {
                await MainActor.run {
                    stage = nil
                    done = "Stopped. Nothing was changed."
                }
            } catch {
                await MainActor.run {
                    stage = nil
                    failure = String(describing: error)
                }
            }
            await MainActor.run { buildTask = nil }
        }
    }

    /// Says what this screen is for, rather than what the app is called. The
    /// window title and the workspace bar both already say that.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            StudioTheme.eyebrow(source == nil ? "New design" : "Before you build")
                .foregroundStyle(StudioTheme.accentInk)
            Text(source == nil ? "Start from a clip" : "Choose a phone, then lay it out")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(StudioTheme.textBright)
            Text(source == nil
                ? "Any short video or GIF. What lands inside the widget frame animates; the rest becomes the wallpaper behind it."
                : "The crop and the placement are baked into the fonts, so they are settled in the editor before anything is compiled.")
                .font(StudioTheme.body)
                .foregroundStyle(StudioTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The clip, shown rather than named.
    ///
    /// It was a dashed box with the filename in it, which is the one thing the
    /// bar above it already said — and a clip is a picture, so there was
    /// something truer to put here.
    private var dropTarget: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(
                targeting ? StudioTheme.accent : StudioTheme.controlEdge,
                style: StrokeStyle(lineWidth: 1.5, dash: source == nil || targeting ? [6, 4] : [])
            )
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(targeting ? StudioTheme.accent.opacity(0.1) : StudioTheme.well.opacity(0.55))
            )
            .frame(height: source == nil ? 108 : 190)
            .overlay {
                if let source, let poster = DesignThumbnail.firstFrame(of: source) {
                    Image(nsImage: poster)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .bottomLeading) { posterCaption(source) }
                        .allowsHitTesting(false)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: source == nil ? "square.and.arrow.down" : "film")
                            .font(.title2)
                            .foregroundStyle(targeting ? StudioTheme.accent : StudioTheme.textSecondary)
                        Text(source?.lastPathComponent ?? "Drop a video or GIF")
                            .font(StudioTheme.bodyStrong)
                            .foregroundStyle(StudioTheme.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if source == nil {
                            Text("or click to choose one")
                                .font(StudioTheme.monoSmall)
                                .foregroundStyle(StudioTheme.textDim)
                        }
                    }
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

    /// The clip's name over its own picture, so a dark frame does not swallow
    /// it and a bright one does not either.
    private func posterCaption(_ source: URL) -> some View {
        Text(source.lastPathComponent)
            .font(StudioTheme.monoSmall)
            .foregroundStyle(.white)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(10)
    }

    /// Three rows that each answer a different question, so each says which.
    ///
    /// They were bare nouns in a grid — "iPhone", "Device", "Loop" — two of
    /// which mean the same thing to anyone who has not read the pipeline: the
    /// phone a design is *cut for* and the phone it *installs to* are separate
    /// choices, and nothing on the screen said so.
    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingRow("Cut for", note: "Only the iPhone 17 Pro is calibrated. The wrong one shows a seam.") {
                Picker("", selection: $model) {
                    ForEach(DeviceModel.all) { Text($0.name).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }

            settingRow("Install to", note: devices.isEmpty ? "Connect an iPhone by cable, then refresh." : nil) {
                HStack(spacing: 8) {
                    Picker("", selection: $deviceID) {
                        Text(devices.isEmpty ? "No phone connected" : "Choose").tag(String?.none)
                        ForEach(devices) { Text($0.name).tag(String?.some($0.id)) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    Button("Refresh") { refreshDevices() }
                        .buttonStyle(.studioCompact)
                }
            }

            settingRow("Loop length", note: "The cycle is 30 seconds. A loop that divides it evenly is seamless.") {
                HStack(spacing: 10) {
                    Slider(value: $loopSeconds, in: 0 ... 6, step: 0.1)
                        .frame(maxWidth: 220)
                    Text(loopSeconds == 0 ? "As recorded" : String(format: "%.1fs", loopSeconds))
                        .font(StudioTheme.mono)
                        .monospacedDigit()
                        .foregroundStyle(StudioTheme.textTertiary)
                }
            }
        }
        .font(StudioTheme.body)
        .foregroundStyle(StudioTheme.text)
        .disabled(isBusy)
    }

    private func settingRow(
        _ title: String,
        note: String?,
        @ViewBuilder control: () -> some View
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title)
                .font(StudioTheme.bodyStrong)
                .foregroundStyle(StudioTheme.text)
                .frame(width: 84, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                control()
                if let note {
                    Text(note)
                        .font(StudioTheme.monoSmall)
                        .foregroundStyle(StudioTheme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var actions: some View {
        HStack {
            Button(prepared == nil ? "Edit layout" : "Editing...") { start() }
                .buttonStyle(.studioProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(source == nil || isBusy)
            if projectRoot == nil {
                Button("Choose project folder") { chooseProject() }
                    .buttonStyle(.studio)
            }
            Spacer()
            if !log.isEmpty {
                Text(log.last ?? "")
                    .font(.caption.monospaced())
                    .foregroundStyle(StudioTheme.textDim)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }

    private func progress(_ stage: StudioPipeline.Stage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: stage.fraction)
                .tint(StudioTheme.accent)
            HStack {
                Text(stage.caption).font(StudioTheme.body).foregroundStyle(StudioTheme.textSecondary)
                Spacer()
                Button("Stop") { stopBuild() }
                    .buttonStyle(.studioCompact)
                    .help("Stop the build (esc)")
            }
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
        guard let source else { return }
        done = nil
        failure = nil
        log = []
        run = .opening(source.lastPathComponent)
        stage = .preparing

        let pipeline = StudioPipeline(projectRoot: projectRoot, model: model)
        buildTask = Task {
            do {
                let ready = try await pipeline.prepare(source: source) { stage in
                    Task { @MainActor in self.stage = stage }
                }
                await MainActor.run {
                    self.stage = nil
                    self.run = nil
                    self.prepared = ready
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.stage = nil
                    self.done = "Stopped. Nothing was changed."
                }
            } catch {
                await MainActor.run {
                    self.stage = nil
                    self.failure = String(describing: error)
                }
            }
            await MainActor.run { self.buildTask = nil }
        }
    }

    private func install(_ edited: StudioPipeline.Prepared) {
        // Building is the step that genuinely needs the project folder, so a
        // missing one is asked for right here - the chooser button lives on
        // the front page, and this press usually comes from the editor, where
        // there was nothing to do about the refusal.
        if projectRoot == nil { chooseProject() }
        guard let projectRoot else {
            failure = String(describing: StudioPipelineError.noProjectFolder)
            return
        }
        done = nil
        failure = nil
        log = []
        wallpaper = nil
        run = .building(edited.design.name)
        stage = .preparing
        let pipeline = StudioPipeline(projectRoot: projectRoot, model: model)
        let loop = loopSeconds
        let device = deviceID
        buildTask = Task {
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
            } catch is CancellationError {
                // Asked for, so it is not a failure. Says so, because a run
                // that simply stopped looks exactly like one that crashed.
                await MainActor.run {
                    self.stage = nil
                    self.done = "Build stopped. Nothing was installed."
                }
            } catch {
                await MainActor.run {
                    self.stage = nil
                    self.failure = String(describing: error)
                }
            }
            await MainActor.run { self.buildTask = nil }
        }
    }

    /// Escape stops a build. A render is long enough that starting one by
    /// mistake needs a way out that is not force-quitting the studio.
    private func stopBuild() {
        guard let buildTask else { return }
        buildTask.cancel()
        self.buildTask = nil
        stage = nil
        done = "Build stopped. Nothing was installed."
    }
}


private struct EditorWindow: View {
    @State var prepared: StudioPipeline.Prepared
    let model: DeviceModel
    let onCancel: (StudioPipeline.Prepared) -> Void
    let onBuild: (StudioPipeline.Prepared) -> Void

    @Environment(\.undoManager) private var windowUndoManager
    @State private var undo = UndoCoordinator()
    /// What the autosave last wrote, so opening a design does not restamp it.
    @State private var lastSaved: DesignDocument?
    /// What the toolbar says under the name. Set by the autosave rather than
    /// timed, so it reports a write that happened instead of guessing.
    @State private var savedNote = ""

    var body: some View {
        // The editor carries its own toolbar and status bar now, and scrolls
        // the canvas itself, so the window is just a host for it.
        LayoutEditor(
            design: $prepared.design,
            model: model,
            poster: prepared.poster,
            store: prepared.store,
            documentName: prepared.design.name,
            savedNote: savedNote,
            onBuild: { onBuild(prepared) },
            // Saved on the way out: leaving the editor should not be the thing
            // that loses an afternoon's placement.
            onClose: { onCancel(prepared) }
        )
        .frame(
            minWidth: LayoutEditor.width(for: model),
            minHeight: LayoutEditor.height(for: model)
        )
        .onAppear {
            lastSaved = prepared.design
            undo.apply = { prepared.design = $0 }
            undo.current = { prepared.design }
        }
        .onChange(of: prepared.design) { old, _ in
            undo.designChanged(from: old, undoManager: windowUndoManager)
        }
        // The sidebar's Library row, answered here so the working copy this
        // view holds is the one that gets written.
        .onReceive(NotificationCenter.default.publisher(for: .studioGoHome)) { _ in
            onCancel(prepared)
        }
        // Autosave, debounced: the id restarts this on every change, so only a
        // pause in editing writes. An afternoon's placement should not depend
        // on remembering to press Done.
        .task(id: prepared.design) {
            guard prepared.design != lastSaved else { return }
            savedNote = "unsaved changes"
            guard (try? await Task.sleep(for: .milliseconds(800))) != nil else { return }
            do {
                try prepared.store.save(prepared.design)
                lastSaved = prepared.design
                savedNote = "saved just now"
            } catch {
                // Named rather than silent: an autosave that stops working
                // looks exactly like one that is working.
                savedNote = "could not save: \(error.localizedDescription)"
            }
        }
    }
}
