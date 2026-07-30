import SwiftUI

/// One design the app can show, from either route.
///
/// Both kinds live in one list because the phone swipes between them and should
/// not have to care which was compiled and which was not. What differs is only
/// where the animation comes from: a bundled design plays the preview video the
/// Mac baked, a runtime-frame design swaps the pictures the phone wrote.
enum HomePage: Identifiable {
    case bundled(PrebuiltDesign.Entry)
    case runtime(design: DesignDocument, manifest: BuildManifest, sequence: RuntimeFrameSequence)

    var id: UUID {
        switch self {
        case .bundled(let entry): entry.id
        case .runtime(let design, _, _): design.id
        }
    }

    var name: String {
        switch self {
        case .bundled(let entry): entry.name
        case .runtime(let design, _, _): design.name
        }
    }

    var wallpaperURL: URL? {
        switch self {
        case .bundled(let entry): entry.wallpaperURL
        case .runtime(let design, _, _): (try? DesignStore())?.wallpaperURL(for: design.id)
        }
    }
}

/// The design, full screen.
///
/// Designs used to be built on the Mac and compiled into this build, and this
/// screen was a viewer with nothing to configure. It is still that for a bundled
/// design - the only route to a loop longer than two seconds - but a design can
/// now also be made here, from a clip in Photos, with nothing to install.
struct HomeView: View {
    @EnvironmentObject private var router: ExternalAppRouter

    @State private var saving = false
    @State private var note: String?
    @State private var importing = false
    @StateObject private var icons = IconImageLoader(store: try? DesignStore())
    @StateObject private var gallery = RuntimeFrameGallery()

    @State private var selection: UUID? = ActiveDesign.identifier
    /// Bumped after an import so the store is read again. The runtime pages come
    /// off disk, and a view that never re-reads it shows the library as it was
    /// when the app launched.
    @State private var storeGeneration = 0

    /// Whatever there is to say right now, from either source.
    private var message: String? { note ?? gallery.failure ?? router.lastFailure }

    private var pages: [HomePage] {
        // Keyed off the generation so an import shows up. SwiftUI has no other
        // reason to recompute a property that reads the filesystem.
        _ = storeGeneration
        var all: [HomePage] = []
        if let store = try? DesignStore() {
            for built in RuntimeDesignImporter.builtDesigns(in: store) {
                guard let sequence = built.manifest.frameSequence else { continue }
                all.append(.runtime(design: built.design, manifest: built.manifest, sequence: sequence))
            }
        }
        all.append(contentsOf: PrebuiltDesign.entries.map(HomePage.bundled))
        return all
    }

    private var page: HomePage? {
        let all = pages
        if let selection, let match = all.first(where: { $0.id == selection }) { return match }
        return all.first
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let page {
                content(for: page).id(page.id)
            } else {
                EmptyDesignView()
            }

            if pages.count > 1 { PageDots(count: pages.count, index: index) }

            BottomControls(saving: saving, save: save, importClip: { importing = true })
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
        .statusBarHidden(page != nil)
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
        .sheet(isPresented: $importing) {
            ImportSheet { design in
                storeGeneration += 1
                selection = design.id
                note = "\(design.name) is ready. Save the wallpaper, then place the widget."
            }
        }
    }

    @ViewBuilder
    private func content(for page: HomePage) -> some View {
        switch page {
        case .bundled(let entry):
            if let manifest = entry.manifest {
                composition(entry: entry, manifest: manifest)
            } else {
                EmptyDesignView()
            }
        case .runtime(let design, let manifest, let sequence):
            runtimeComposition(design: design, manifest: manifest, sequence: sequence)
        }
    }

    private var index: Int {
        let all = pages
        guard let page, let position = all.firstIndex(where: { $0.id == page.id }) else { return 0 }
        return position
    }

    private func switchDesign(by step: Int) {
        let all = pages
        guard all.count > 1 else { return }
        let next = all[(index + step + all.count) % all.count]
        selection = next.id
        // Written where the widget reads it, and pushed, so the Home Screen
        // follows the app rather than disagreeing with it.
        ActiveDesign.identifier = next.id
        WidgetCenterBridge.reloadAll()
        note = next.name
    }

    private func runtimeComposition(
        design: DesignDocument,
        manifest: BuildManifest,
        sequence: RuntimeFrameSequence
    ) -> some View {
        RuntimeDesignView(
            manifest: manifest,
            sequence: sequence,
            frames: gallery.frames,
            wallpaper: gallery.wallpaper
        ) { tile, side in
            Button {
                router.launch(appID: tile.appID)
            } label: {
                TileView(tile: tile, side: side, iconImage: icons.image(for: tile))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(AppCatalog.app(id: tile.appID)?.name ?? tile.appID)")
        }
        .ignoresSafeArea()
        .task(id: design.id) {
            guard let store = try? DesignStore() else { return }
            gallery.load(design: design, manifest: manifest, sequence: sequence, store: store)
        }
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
        guard let url = page?.wallpaperURL, FileManager.default.fileExists(atPath: url.path) else {
            note = "This design has no wallpaper saved for it yet."
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

private struct BottomControls: View {
    let saving: Bool
    let save: () -> Void
    let importClip: () -> Void

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Spacer()
                GlassButton(systemImage: "plus", action: importClip)
                    .accessibilityLabel("Add a clip from Photos")
                GlassButton(
                    systemImage: "square.and.arrow.down",
                    isBusy: saving,
                    action: save
                )
                .accessibilityLabel("Save the wallpaper to Photos")
            }
        }
        .padding(.trailing, 20)
        .padding(.bottom, 34)
    }
}

private struct GlassButton: View {
    let systemImage: String
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isBusy {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 46, height: 46)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
        }
        .disabled(isBusy)
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
            Text("Nothing here yet. Tap + to turn a clip from Photos into a widget, or build one in Motionary Studio on the Mac for a loop longer than two seconds.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 40)
        }
    }
}
