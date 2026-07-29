import SwiftUI
import UniformTypeIdentifiers

@main
struct MotionaryStudioApp: App {
    init() {
        // A window cannot be driven from a build script, and the pipeline is
        // the part worth checking, so it can also be run without one:
        //   MotionaryStudio.app/Contents/MacOS/MotionaryStudio --build clip.gif
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
                } else {
                    outcome = try await pipeline.build(
                        source: source,
                        loopSeconds: nil,
                        onStage: report
                    )
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

    @State private var stage: StudioPipeline.Stage?
    @State private var failure: String?
    @State private var done: String?
    @State private var log: [String] = []
    @State private var targeting = false

    @State private var projectRoot: URL? = ProjectLocator.find()

    private var isBusy: Bool { stage != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            dropTarget
            settings
            actions
            if let stage { progress(stage) }
            if let done { message(done, tint: .green) }
            if let failure { message(failure, tint: .red) }
        }
        .padding(24)
        .frame(width: 520)
        .task { refreshDevices() }
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
            Button("Build and install") { start() }
                .keyboardShortcut(.defaultAction)
                .disabled(source == nil || deviceID == nil || isBusy)
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

    private func start() {
        guard let source, let deviceID, let projectRoot else { return }
        self.done = nil
        self.failure = nil
        log = []
        stage = .preparing

        let pipeline = StudioPipeline(projectRoot: projectRoot, model: model)
        let loop = loopSeconds
        Task {
            do {
                let built = try await pipeline.run(
                    source: source,
                    loopSeconds: loop > 0 ? loop : nil,
                    deviceID: deviceID
                ) { stage in
                    Task { @MainActor in
                        self.stage = stage
                        log.append(stage.caption)
                    }
                }
                await MainActor.run {
                    self.stage = nil
                    self.done = "Installed. \(built.summary). Add the Motionary widget if it is not already on the Home Screen."
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
