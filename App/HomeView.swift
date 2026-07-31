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
    @State private var choosingSlots = false
    /// Bumped by the slots sheet so the composition re-reads the choices; the
    /// store itself is UserDefaults, which SwiftUI does not observe.
    @State private var slotsEdition = 0

    /// Whatever there is to say right now, from either source.
    private var message: String? { note ?? router.lastFailure }

    private var entries: [PrebuiltDesign.Entry] { PrebuiltDesign.entries }
    private var entry: PrebuiltDesign.Entry? { PrebuiltDesign.selected(id: selection) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let entry, let manifest = entry.manifest {
                // Identity includes the chosen variant so picking another one
                // rebuilds the player rather than looping the old clip.
                composition(entry: entry, manifest: manifest)
                    .id("\(entry.id.uuidString)-\(VariantChoice.resolved(in: manifest)?.id.uuidString ?? "primary")")
            } else {
                EmptyDesignView()
            }

            if entries.count > 1 { PageDots(count: entries.count, index: index) }

            SaveButton(saving: saving) { save() }
            // Anything to choose at all: slot occupants, or a clip variant.
            if let manifest = entry?.manifest,
               !manifest.placedTiles.isEmpty || !manifest.builtVariants.isEmpty {
                SlotsButton { choosingSlots = true }
            }
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
        .sheet(isPresented: $choosingSlots) {
            if let entry, let manifest = entry.manifest {
                SlotSettingsView(manifest: manifest) { slotsEdition += 1 }
            }
        }
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
        // The same slot choices the widget applies, so the app never shows a
        // different set of apps than the Home Screen it imitates. slotsEdition
        // is what makes this line re-run after the sheet writes a choice.
        let _ = slotsEdition
        let authored = Dictionary(
            manifest.placedTiles.map { ($0.id, $0.appID) },
            uniquingKeysWith: { first, _ in first }
        )
        // The chosen clip variant's preview; the wallpaper stays the design's,
        // because variants only differ inside the widget frame.
        let variant = VariantChoice.resolved(in: manifest)
        return LoopingCompositionView(
            screenSize: manifest.screenSize,
            viewport: CGRect(origin: .zero, size: manifest.screenSize),
            tiles: SlotChoices.apply(to: manifest.placedTiles, designID: manifest.designID),
            videoURL: variant.flatMap { entry.previewURL(variant: $0.id) } ?? entry.previewURL,
            // The tile-free variant when the build has one: the live tiles
            // drawn over it are the occupants the phone chose, and a swapped
            // one over its baked authored self would ghost through the plate.
            wallpaper: (entry.plainWallpaperURL ?? entry.wallpaperURL)
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
                    iconImage: PrebuiltDesign.iconURL(
                        tileID: tile.id,
                        appID: tile.appID,
                        authoredAppID: authored[tile.id] ?? tile.appID
                    )
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
        guard let entry, let manifest = entry.manifest else {
            note = "This build has no wallpaper in it."
            return
        }
        saving = true
        Task {
            do {
                try await export(entry: entry, manifest: manifest)
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

    /// The wallpaper with the slots as they are right now.
    ///
    /// The shipped wallpaper was baked with the authored occupants, so after a
    /// swap it would continue the wrong icon past the widget's edge - which is
    /// the whole reason tiles are baked into it. So the phone bakes the
    /// effective tiles onto the tile-free variant itself. Designs built before
    /// that variant shipped fall back to the pre-baked file.
    private func export(entry: PrebuiltDesign.Entry, manifest: BuildManifest) async throws {
        let longest = Int(max(manifest.screenSize.width, manifest.screenSize.height))
        guard let plainURL = entry.plainWallpaperURL,
              let base = ImageLoader.load(at: plainURL, maxPixelSize: longest)
        else {
            guard let url = entry.wallpaperURL else {
                throw ExportError.wallpaperMissing(path: "prebuilt wallpaper for \(entry.name)")
            }
            try await WallpaperExporter.saveToPhotos(url: url)
            return
        }

        let authored = Dictionary(
            manifest.placedTiles.map { ($0.id, $0.appID) },
            uniquingKeysWith: { first, _ in first }
        )
        let composed = await WallpaperComposer.compose(
            frame: base,
            tiles: SlotChoices.apply(to: manifest.placedTiles, designID: manifest.designID),
            // Already baked into the plain wallpaper; they are not slot-dependent.
            assets: [],
            screenSize: manifest.screenSize,
            artwork: { tile in
                PrebuiltDesign.iconURL(
                    tileID: tile.id,
                    appID: tile.appID,
                    authoredAppID: authored[tile.id] ?? tile.appID
                )
                .flatMap { ImageLoader.load(at: $0, maxPixelSize: Int(tile.size)) }
            }
        )
        try await WallpaperExporter.saveToPhotos(image: composed)
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

/// Opens the slot settings, mirroring the save button on the other corner.
private struct SlotsButton: View {
    let action: () -> Void

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Button(action: action) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
                }
                .accessibilityLabel("Design options: choose the animation and which apps fill the slots")
                Spacer()
            }
        }
        .padding(.leading, 20)
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
