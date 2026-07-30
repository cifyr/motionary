import PhotosUI
import SwiftUI
import os

/// Picks a clip and turns it into an animating design, on the phone.
///
/// Everything this sheet does used to require a Mac. A design reached the Home
/// Screen only by being compiled into the widget extension's bundle, because the
/// animation was drawn by generated colour-glyph fonts and a widget renderer
/// will not draw a font that was not in its bundle at install time. The
/// runtime-frame route has no fonts in it, so there is nothing to compile and
/// this sheet is the whole pipeline.
///
/// The loop length is not offered as a free choice on purpose. The mask repeats
/// every two seconds and nothing built from the bundled blink font can outlast
/// that, so the clip's own loop is played a whole number of times inside the
/// cycle and the speed absorbs the remainder. What the sheet shows is what that
/// costs, before the frames are written.
struct ImportSheet: View {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "ImportSheet")

    /// Frame rates offered. Frames tile the two-second cycle two per fps, so
    /// these are 16, 32, 48 and 64 pictures. Past that the extension is
    /// carrying more than its memory cap allows.
    static let rates = [8, 16, 24, 32]

    let onFinished: (DesignDocument) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var picked: PhotosPickerItem?
    @State private var rate = 16
    @State private var layout = RuntimeFrameSequence.Layout.separate
    @State private var stage: RuntimeFrameBuilder.Stage?
    @State private var failure: String?
    @State private var fit: BlinkCycle.LoopFit?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(
                        selection: $picked,
                        matching: .any(of: [.videos, .images]),
                        photoLibrary: .shared()
                    ) {
                        Label(
                            picked == nil ? "Choose a video or GIF" : "Chosen",
                            systemImage: "photo.on.rectangle.angled"
                        )
                    }
                    .disabled(working)
                } footer: {
                    Text("A short looping clip works best. Long clips are slowed to fit the two-second cycle.")
                }

                Section("Motion") {
                    Picker("Frame rate", selection: $rate) {
                        ForEach(Self.rates, id: \.self) { value in
                            Text("\(value) fps · \(BlinkCycle.frameCount(framesPerSecond: value)) frames")
                                .tag(value)
                        }
                    }
                    Picker("Frames on disk", selection: $layout) {
                        ForEach(RuntimeFrameSequence.Layout.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                }

                if let fit {
                    Section("What this will make") {
                        LabelledRow("Cycle", "\(Int(BlinkCycle.cycleDuration))s, repeating")
                        LabelledRow(
                            "Your loop",
                            String(format: "%.2fs played %dx", fit.playedLoop, fit.repeats)
                        )
                        LabelledRow(
                            "Speed",
                            fit.drift < 0.005
                                ? "unchanged"
                                : String(format: "%+.0f%% to land on the cycle", (fit.speed - 1) * 100)
                        )
                        LabelledRow("Frames", "\(BlinkCycle.frameCount(framesPerSecond: rate))")
                    }
                }

                if let stage {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: stage.fraction)
                            Text(stage.caption).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }

                if let failure {
                    Section("That did not work") {
                        // The reason, not "something went wrong". Every failure
                        // in this pipeline is specific and fixable if it is
                        // named: a sheet too tall to draw, a clip with no video
                        // track, a crop that misses the widget.
                        Text(failure).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add a clip")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(working)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Build") { build() }
                        .disabled(picked == nil || working)
                }
            }
            .interactiveDismissDisabled(working)
        }
        .task(id: picked) { await probe() }
    }

    /// Reads the clip's own length so the sheet can say what fitting it to the
    /// cycle will cost, before anything is written.
    private func probe() async {
        guard let picked else {
            fit = nil
            return
        }
        failure = nil
        do {
            let url = try await staged(picked)
            let summary = try await MediaFrameExtractor(url: url).summary()
            fit = BlinkCycle.fit(sourceLoop: summary.duration)
            Self.logger.info("""
            picked \(summary.kind.rawValue, privacy: .public), \
            \(summary.frameCount) frames over \(summary.duration)s
            """)
        } catch {
            fit = nil
            failure = String(describing: error)
            Self.logger.error("could not read the picked clip: \(String(describing: error), privacy: .public)")
        }
    }

    /// The picked item as a file the extractor can open.
    ///
    /// Copied into a temporary file rather than read from Photos twice: the
    /// transferable is loaded once for the probe and once for the build
    /// otherwise, and a large video is not cheap to hand over.
    private func staged(_ item: PhotosPickerItem) async throws -> URL {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw ImportSheetError.noData
        }
        let isGIF = data.starts(with: Data("GIF8".utf8))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("picked-\(UUID().uuidString).\(isGIF ? "gif" : "mov")")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func build() {
        guard let picked else { return }
        working = true
        failure = nil
        Task {
            do {
                let url = try await staged(picked)
                defer { try? FileManager.default.removeItem(at: url) }
                let store = try DesignStore()
                var options = RuntimeDesignImporter.Options()
                options.framesPerSecond = rate
                options.layout = layout

                let built = try await RuntimeDesignImporter(store: store).run(
                    sourceAt: url,
                    options: options,
                    onStage: { next in Task { @MainActor in stage = next } }
                )
                WidgetCenterBridge.reloadAll()
                Self.logger.info("""
                built \(built.design.name, privacy: .public): \
                \(built.manifest.frameSequence?.summary ?? "no sequence", privacy: .public)
                """)
                working = false
                onFinished(built.design)
                dismiss()
            } catch {
                working = false
                stage = nil
                failure = String(describing: error)
                Self.logger.error("import failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

enum ImportSheetError: Error, CustomStringConvertible {
    case noData

    var description: String {
        switch self {
        case .noData: "import: Photos handed over no data for that item"
        }
    }
}

private struct LabelledRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}
