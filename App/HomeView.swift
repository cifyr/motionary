import SwiftUI

/// The design, full screen.
///
/// Designs are built on the Mac and compiled into this build, so there is
/// nothing here to choose, import or configure - the app's whole job is to show
/// what the widget is showing, and to hand over the wallpaper that has to sit
/// behind it.
struct HomeView: View {
    @State private var saving = false
    @State private var note: String?

    private var manifest: BuildManifest? { PrebuiltDesign.manifest }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let manifest {
                composition(manifest: manifest)
            } else {
                EmptyDesignView()
            }

            SaveButton(saving: saving) { save() }
            if let note { Toast(text: note) }
        }
        .ignoresSafeArea()
        .statusBarHidden(manifest != nil)
        .persistentSystemOverlays(.hidden)
    }

    private func composition(manifest: BuildManifest) -> some View {
        let spec = TimerFontSpec(laneCount: manifest.laneCount, framesPerSecond: manifest.framesPerSecond)
        let loop = manifest.loopFrameCount
        return LoopingCompositionView(
            screenSize: manifest.screenSize,
            viewport: CGRect(origin: .zero, size: manifest.screenSize),
            tiles: [],
            videoURL: PrebuiltDesign.previewURL,
            wallpaper: PrebuiltDesign.wallpaperURL
                .flatMap { UIImage(contentsOfFile: $0.path) }
                .map { Image(uiImage: $0) },
            scaleMode: .device,
            // Both this and the widget's glyph choice are pure functions of
            // wall clock time, so opening the app continues the loop rather
            // than restarting it.
            startTime: { spec.videoTime(loopFrameCount: loop) }
        ) { _, _ in EmptyView() }
        .ignoresSafeArea()
    }

    private func save() {
        guard let url = PrebuiltDesign.wallpaperURL else {
            note = "This build has no wallpaper in it."
            return
        }
        saving = true
        Task {
            do {
                try await WallpaperExporter.saveToPhotos(url: url)
                await MainActor.run {
                    saving = false
                    note = "Saved to Photos. Set it as your wallpaper, then place the widget over it."
                }
            } catch {
                await MainActor.run {
                    saving = false
                    // The reason, not "something went wrong": the usual cause
                    // is a denied Photos permission, which is fixable only if
                    // it is named.
                    note = String(describing: error)
                }
            }
        }
    }
}

private struct SaveButton: View {
    let saving: Bool
    let action: () -> Void

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button(action: action) {
                    Group {
                        if saving {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 46, height: 46)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
                }
                .disabled(saving)
                .accessibilityLabel("Save the wallpaper to Photos")
            }
        }
        .padding(.trailing, 20)
        .padding(.bottom, 34)
    }
}

private struct Toast: View {
    let text: String

    var body: some View {
        VStack {
            Spacer()
            Text(text)
                .font(.footnote)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 28)
                .padding(.bottom, 96)
        }
        .transition(.opacity)
        .allowsHitTesting(false)
    }
}

private struct EmptyDesignView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 46))
                .foregroundStyle(.white.opacity(0.85))
            Text("Motionary")
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
            Text("No design is built into this app yet. Drop a clip into Motionary Studio on the Mac and install again.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 40)
        }
    }
}
