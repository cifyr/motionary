import SwiftUI

/// The design, full screen.
///
/// Designs are built on the Mac and compiled into this build, so there is
/// nothing here to choose, import or configure - the app's whole job is to show
/// what the widget is showing, and to hand over the wallpaper that has to sit
/// behind it.
struct HomeView: View {
    @EnvironmentObject private var router: ExternalAppRouter

    @State private var saving = false
    @State private var note: String?
    @StateObject private var icons = IconImageLoader(store: try? DesignStore())

    @State private var selection: UUID? = ActiveDesign.identifier

    /// Whatever there is to say right now, from either source.
    private var message: String? { note ?? router.lastFailure }

    private var entries: [PrebuiltDesign.Entry] { PrebuiltDesign.entries }
    private var entry: PrebuiltDesign.Entry? { PrebuiltDesign.selected(id: selection) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let entry, let manifest = entry.manifest {
                composition(entry: entry, manifest: manifest)
                    .id(entry.id)
            } else {
                EmptyDesignView()
            }

            if entries.count > 1 { PageDots(count: entries.count, index: index) }

            SaveButton(saving: saving) { save() }
            // A tap that opens nothing has to say why. Rewriting this view
            // dropped the alert that used to report it, so a tile with no
            // launch route failed in complete silence.
            if let message { Toast(text: message).transition(.opacity) }
        }
        // Cleared on its own. A message that stays forever stops being a
        // message and becomes part of the picture.
        .task(id: message) {
            guard message != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            note = nil
            router.lastFailure = nil
        }
        .ignoresSafeArea()
        .statusBarHidden(entry != nil)
        .persistentSystemOverlays(.hidden)
        // A swipe rather than any chrome: the whole point of this screen is to
        // be the Home Screen, and a switcher on top of it would spoil that.
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    switchDesign(by: value.translation.width < 0 ? 1 : -1)
                }
        )
    }

    private var index: Int {
        guard let entry, let position = entries.firstIndex(where: { $0.id == entry.id }) else { return 0 }
        return position
    }

    private func switchDesign(by step: Int) {
        guard entries.count > 1 else { return }
        let next = entries[(index + step + entries.count) % entries.count]
        selection = next.id
        // Written where the widget reads it, and pushed, so the Home Screen
        // follows the app rather than disagreeing with it.
        ActiveDesign.identifier = next.id
        WidgetCenterBridge.reloadAll()
        note = next.name
    }

    private func composition(entry: PrebuiltDesign.Entry, manifest: BuildManifest) -> some View {
        let spec = TimerFontSpec(laneCount: manifest.laneCount, framesPerSecond: manifest.framesPerSecond)
        let loop = manifest.loopFrameCount
        return LoopingCompositionView(
            screenSize: manifest.screenSize,
            viewport: CGRect(origin: .zero, size: manifest.screenSize),
            tiles: manifest.placedTiles,
            videoURL: entry.previewURL,
            wallpaper: entry.wallpaperURL
                .flatMap { UIImage(contentsOfFile: $0.path) }
                .map { Image(uiImage: $0) },
            scaleMode: .device,
            // Both this and the widget's glyph choice are pure functions of
            // wall clock time, so opening the app continues the loop rather
            // than restarting it.
            startTime: { spec.videoTime(loopFrameCount: loop) }
        ) { tile, side in
            Button {
                router.launch(appID: tile.appID)
            } label: {
                TileView(
                    tile: tile,
                    side: side,
                    iconImage: PrebuiltDesign.iconURL(tileID: tile.id)
                        .flatMap { ImageLoader.load(at: $0, maxPixelSize: Int(side * 3)) }
                        .map { Image(decorative: $0, scale: 1) }
                        ?? icons.image(for: tile)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(AppCatalog.app(id: tile.appID)?.name ?? tile.appID)")
        }
        .ignoresSafeArea()
    }

    private func save() {
        guard let url = entry?.wallpaperURL else {
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

/// Which of the bundled designs is showing.
private struct PageDots: View {
    let count: Int
    let index: Int

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 6) {
                ForEach(0 ..< count, id: \.self) { position in
                    Circle()
                        .fill(.white.opacity(position == index ? 0.9 : 0.35))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.35), in: Capsule())
            .padding(.bottom, 44)
        }
        .allowsHitTesting(false)
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
