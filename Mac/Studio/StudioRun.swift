import SwiftUI

extension StudioRun {
    /// The pipeline's vocabulary, translated into this screen's. The only
    /// place the two meet.
    static func phase(of stage: StudioPipeline.Stage) -> Phase {
        switch stage {
        case .preparing: .reading
        case .generating: .rendering
        case .bundling: .bundling
        case .installing(let step): .installing(step)
        }
    }
}

/// What Install all is about to do, before it does it.
///
/// It used to fire straight from the button, on whichever phone happened to be
/// first in the list and whichever model was last set in a workspace you may
/// never have opened — so from the library there was no way to say where a
/// build was going. Both choices belong to this job, so they are asked here.
struct InstallSheet: View {
    let included: [DesignDocument]
    let skipped: [DesignDocument]
    @Binding var model: DeviceModel
    @Binding var deviceID: String?
    let devices: [ConnectedDevice]
    let onRefresh: () -> Void
    let onCancel: () -> Void
    let onInstall: () -> Void

    private var canInstall: Bool { !included.isEmpty && deviceID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Install onto a phone")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(StudioTheme.textBright)
                Text("Every starred design is compiled into one app, so they all install together and the phone switches between them.")
                    .font(StudioTheme.small)
                    .foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                field("Cut for") {
                    Picker("", selection: $model) {
                        ForEach(DeviceModel.all) { Text($0.name).tag($0) }
                    }
                    .labelsHidden()
                }
                field("Install to") {
                    HStack(spacing: 8) {
                        Picker("", selection: $deviceID) {
                            Text(devices.isEmpty ? "No phone connected" : "Choose a phone").tag(String?.none)
                            ForEach(devices) { Text($0.name).tag(String?.some($0.id)) }
                        }
                        .labelsHidden()
                        Button("Refresh", action: onRefresh)
                            .buttonStyle(.studioCompact)
                    }
                }
            }

            manifest

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.studio)
                    .keyboardShortcut(.cancelAction)
                Button("Install", action: onInstall)
                    .buttonStyle(.studioProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canInstall)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(StudioTheme.panel)
        .tint(StudioTheme.accent)
    }

    private func field(_ title: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(StudioTheme.bodyStrong)
                .foregroundStyle(StudioTheme.text)
                .frame(width: 72, alignment: .leading)
            control()
            Spacer()
        }
    }

    /// Which designs are going, and which are not and why. A count alone hides
    /// the one case that matters: a design that is starred but never built.
    private var manifest: some View {
        VStack(alignment: .leading, spacing: 6) {
            StudioTheme.eyebrow("Going on the phone")
                .foregroundStyle(StudioTheme.textSecondary)
            if included.isEmpty {
                Text("Nothing starred has been built yet. Open a design, build it, and it can come along.")
                    .font(StudioTheme.small)
                    .foregroundStyle(StudioTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(included) { design in
                    Label(design.name, systemImage: "checkmark.circle.fill")
                        .font(StudioTheme.body)
                        .foregroundStyle(StudioTheme.text)
                }
                Text("About \(included.count * 29)MB of fonts in the install.")
                    .font(StudioTheme.monoSmall)
                    .foregroundStyle(StudioTheme.textDim)
            }
            ForEach(skipped) { design in
                Label("\(design.name) — starred but never built", systemImage: "minus.circle")
                    .font(StudioTheme.small)
                    .foregroundStyle(StudioTheme.textTertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioTheme.well.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// What a run looks like while it happens, and what it leaves behind when it
/// finishes.
struct StudioRunView: View {
    let run: StudioRun
    let stage: StudioPipeline.Stage?
    let log: [String]
    let done: String?
    let failure: String?
    let wallpaper: URL?
    let onStop: () -> Void
    let onSaveWallpaper: (URL) -> Void
    let onRevealWallpaper: (URL) -> Void
    let onFinish: () -> Void

    private var isRunning: Bool { stage != nil }
    private var currentStep: Int {
        guard let stage else { return run.steps.count }
        return run.step(for: StudioRun.phase(of: stage))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                heading
                if isRunning { bar }
                steps
                if !log.isEmpty { transcript }
                if let failure { outcome(failure, symbol: "exclamationmark.triangle.fill", tint: .red) }
                if let done, failure == nil { outcome(done, symbol: "checkmark.circle.fill", tint: .green) }
                if !isRunning { footer }
            }
            .padding(28)
            .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(StudioTheme.headerEdge, lineWidth: 1)
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .padding(28)
        }
        .background(StudioTheme.libraryBackground)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            StudioTheme.eyebrow(isRunning ? "Working" : (failure == nil ? "Finished" : "Stopped"))
                .foregroundStyle(failure == nil ? StudioTheme.accentInk : .red)
            Text(run.title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(StudioTheme.textBright)
            Text(run.subtitle)
                .font(StudioTheme.body)
                .foregroundStyle(StudioTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var bar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: stage?.fraction ?? 0)
                .tint(StudioTheme.accent)
            HStack {
                Text(stage?.caption ?? "")
                    .font(StudioTheme.body)
                    .foregroundStyle(StudioTheme.text)
                Spacer()
                Button("Stop", action: onStop)
                    .buttonStyle(.studioCompact)
                    .help("Stop the run (esc)")
            }
        }
    }

    /// The steps, with the one in hand marked. A long wait is bearable when it
    /// is legible; the same wait behind a single bar is not.
    private var steps: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(run.steps.enumerated()), id: \.offset) { index, title in
                HStack(spacing: 10) {
                    marker(for: index)
                    Text(title)
                        .font(index == currentStep && isRunning ? StudioTheme.bodyStrong : StudioTheme.body)
                        .foregroundStyle(colour(for: index))
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private func marker(for index: Int) -> some View {
        if index < currentStep {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(StudioTheme.accent)
        } else if index == currentStep, isRunning {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: 15, height: 15)
        } else {
            Image(systemName: "circle")
                .foregroundStyle(StudioTheme.textDim.opacity(0.5))
        }
    }

    private func colour(for index: Int) -> Color {
        if index < currentStep { return StudioTheme.textSecondary }
        if index == currentStep, isRunning { return StudioTheme.textBright }
        return StudioTheme.textDim
    }

    /// The last few lines the tools printed. Kept short: this is reassurance
    /// that something is happening, not a build log to read.
    private var transcript: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(log.suffix(5), id: \.self) { line in
                Text(line)
                    .font(StudioTheme.monoSmall)
                    .foregroundStyle(StudioTheme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(StudioTheme.well.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func outcome(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .foregroundStyle(StudioTheme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let wallpaper {
                Button("Save wallpaper…") { onSaveWallpaper(wallpaper) }
                    .buttonStyle(.studioProminent)
                Button("Show in Finder") { onRevealWallpaper(wallpaper) }
                    .buttonStyle(.studio)
            }
            Spacer()
            Button("Back to the library", action: onFinish)
                .buttonStyle(wallpaper == nil ? .studioProminent : .studio)
                .keyboardShortcut(.defaultAction)
        }
    }
}
