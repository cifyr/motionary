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
    /// Taps change a slot rather than open an app, and a blanked slot comes
    /// back as a target so it can be changed again.
    @State private var isEditing = false
    @State private var editingTile: PlacedTile?
    @Environment(\.displayScale) private var displayScale

    /// Whatever there is to say right now, from either source.
    private var message: String? { note ?? router.lastFailure }

    private var entries: [PrebuiltDesign.Entry] { PrebuiltDesign.entries }
    private var entry: PrebuiltDesign.Entry? { PrebuiltDesign.selected(id: selection) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let entry, let manifest = entry.manifest {
                // Identity is the scene, not the clip within it. Including the
                // clip tore the player down and built a new one on every
                // change, which blanked the screen to the wallpaper - baked
                // from the scene's own clip - for as long as the next one took
                // to load. The player swaps its own clip in place instead.
                composition(entry: entry, manifest: manifest)
                    .id(entry.id)
            } else {
                EmptyDesignView()
            }

            if entries.count > 1, !isEditing { PageDots(count: entries.count, index: index) }

            if isEditing {
                EditingBar(
                    hasBackgrounds: !(entry?.manifest?.builtVariants.isEmpty ?? true),
                    onOptions: { choosingSlots = true },
                    onDone: { isEditing = false }
                )
            } else {
                SaveButton(saving: saving) { save() }
                // Anything to change at all: a slot, or a clip variant.
                if let manifest = entry?.manifest,
                   !manifest.placedTiles.isEmpty || !manifest.builtVariants.isEmpty {
                    SlotsButton { isEditing = true }
                }
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
        .sheet(item: $editingTile) { tile in
            if let manifest = entry?.manifest {
                SlotEditorView(manifest: manifest, tile: tile) { slotsEdition += 1 }
            }
        }
        // A swipe rather than any chrome: the whole point of this screen is to
        // be the Home Screen, and a switcher on top of it would spoil that.
        //
        // What it moves through is whatever is being worked on. Editing a
        // scene, it steps through that scene's backgrounds; otherwise through
        // the scenes themselves. Across the background only, so a drag that
        // starts on an icon belongs to that icon.
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    guard !isOnASlot(value.startLocation) else { return }
                    let step = value.translation.width < 0 ? 1 : -1
                    if isEditing {
                        switchBackground(by: step)
                    } else {
                        switchDesign(by: step)
                    }
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

    @ViewBuilder
    private func composition(entry: PrebuiltDesign.Entry, manifest: BuildManifest) -> some View {
        if let first = RandomClipRotation.nextTransition(after: Date(), in: manifest) {
            TimelineView(.periodic(from: first, by: RandomClipRotation.interval(for: manifest))) { context in
                composition(entry: entry, manifest: manifest, at: context.date)
            }
        } else {
            composition(entry: entry, manifest: manifest, at: Date())
        }
    }

    private func composition(entry: PrebuiltDesign.Entry, manifest: BuildManifest, at date: Date) -> some View {
        let spec = TimerFontSpec(laneCount: manifest.laneCount, framesPerSecond: manifest.framesPerSecond)
        // The same slot choices the widget applies, so the app never shows a
        // different set of apps than the Home Screen it imitates. slotsEdition
        // is what makes this line re-run after the sheet writes a choice.
        let _ = slotsEdition
        let authored = Dictionary(
            manifest.placedTiles.map { ($0.id, $0.appID) },
            uniquingKeysWith: { first, _ in first }
        )
        // The chosen clip variant's preview; the wallpaper stays the design's,
        // because variants only differ inside the widget frame. The loop is
        // the variant's own - lengths need not match across variants.
        let variant = VariantChoice.resolved(in: manifest, at: date)
        let loop = variant?.loopFrameCount ?? manifest.loopFrameCount
        // Blanked slots come back while editing: one that draws nothing would
        // otherwise be unreachable, and blanking it would be a one-way door.
        let blanked = isEditing ? SlotChoices.blankedTiles(manifest: manifest) : []
        let blankIDs = Set(blanked.map(\.id))
        return LoopingCompositionView(
            screenSize: manifest.screenSize,
            viewport: CGRect(origin: .zero, size: manifest.screenSize),
            tiles: SlotChoices.effectiveTiles(manifest: manifest) + blanked,
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
            startTime: { spec.videoTime(loopFrameCount: loop) },
            assets: manifest.placedAssets,
            assetImage: { asset in
                PrebuiltDesign.pictureURL(assetID: asset.id)
                    .flatMap {
                        ImageLoader.load(
                            at: $0,
                            maxPixelSize: Int(max(asset.size.width, asset.size.height))
                        )
                    }
                    .map { Image(decorative: $0, scale: 1) }
            }
        ) { tile, side in
            Button {
                guard !isEditing else {
                    // The authored tile, not the effective one: the editor
                    // offers the slot's own set and its own default, both of
                    // which the phone's choice has already written over.
                    editingTile = manifest.placedTiles.first { $0.id == tile.id } ?? tile
                    return
                }
                router.launch(tile: tile)
            } label: {
                if blankIDs.contains(tile.id) {
                    BlankSlot(side: side)
                } else {
                    TileView(
                        tile: tile,
                        side: side,
                        isSelected: isEditing,
                        iconImage: SlotArtwork.image(
                            for: tile,
                            designID: manifest.designID,
                            authoredAppID: authored[tile.id] ?? tile.appID,
                            side: side
                        ) ?? icons.image(for: tile)
                    )
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label(for: tile, isBlank: blankIDs.contains(tile.id)))
        }
        .ignoresSafeArea()
    }

    private func label(for tile: PlacedTile, isBlank: Bool) -> String {
        if isBlank { return "Fill the blank spot" }
        return isEditing ? "Change \(tile.displayName)" : "Open \(tile.displayName)"
    }

    /// Whether a drag began on an icon. A slot is a button, and a swipe that
    /// starts inside one belongs to it rather than to the background.
    private func isOnASlot(_ point: CGPoint) -> Bool {
        guard let manifest = entry?.manifest else { return false }
        let scale = 1 / max(displayScale, 1)
        return (SlotChoices.effectiveTiles(manifest: manifest) + SlotChoices.blankedTiles(manifest: manifest))
            .contains { tile in
                CGRect(
                    x: tile.rect.minX * scale,
                    y: tile.rect.minY * scale,
                    width: tile.size * scale,
                    height: tile.size * scale
                ).contains(point)
            }
    }

    /// Steps through this scene's backgrounds, its own clip included.
    ///
    /// Editing only. Out of edit mode the same swipe changes scene, so a scene
    /// with one background simply does nothing here rather than quietly
    /// changing something else - a swipe that means two things depending on
    /// what this design happens to carry is worse than one that means nothing.
    private func switchBackground(by step: Int) {
        guard let manifest = entry?.manifest, !manifest.builtVariants.isEmpty else { return }
        // Alphabetical from the clip this scene leads with, so a swipe walks
        // the same order the options sheet lists.
        let options = manifest.clipSequence
        let current = VariantChoice.resolved(in: manifest)?.id
        let position = options.firstIndex { $0.variantID == current } ?? 0
        let next = options[(position + step + options.count) % options.count]
        VariantChoice.set(next.variantID, designID: manifest.designID)
        WidgetCenterBridge.reloadAll()
        slotsEdition += 1
        note = next.name
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
            tiles: SlotChoices.effectiveTiles(manifest: manifest),
            // Already baked into the plain wallpaper; they are not slot-dependent.
            assets: [],
            screenSize: manifest.screenSize,
            // The skin the phone chose first, exactly as the widget resolves
            // it: a wallpaper baked from the authored icon would continue the
            // wrong artwork past the widget's edge, which is the one thing
            // baking the tiles into it is for.
            artwork: { tile in
                let url = tile.skin.flatMap { PrebuiltDesign.skinURL(designID: manifest.designID, skin: $0) }
                    ?? PrebuiltDesign.iconURL(
                        tileID: tile.id,
                        appID: tile.appID,
                        authoredAppID: authored[tile.id] ?? tile.appID
                    )
                return url.flatMap { ImageLoader.load(at: $0, maxPixelSize: Int(tile.size)) }
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

/// A slot the phone blanked.
///
/// It draws nothing on the Home Screen at all - the widget simply leaves it out
/// - but while editing it has to be here and obviously tappable, or blanking a
/// slot would be the one change that cannot be undone from the screen it was
/// made on.
private struct BlankSlot: View {
    let side: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
            .fill(.black.opacity(0.25))
            .overlay {
                RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: max(1.5, side * 0.03))
            }
            .frame(width: side, height: side)
    }
}

/// What edit mode replaces the corner buttons with: what tapping does now, a
/// way to the settings that are not per spot, and a way out.
private struct EditingBar: View {
    /// Whether this scene has more than one background, which is what the
    /// swipe does here - saying so on a scene with one would be a lie.
    let hasBackgrounds: Bool
    let onOptions: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Button("Options", systemImage: "slider.horizontal.3", action: onOptions)
                    .labelStyle(.titleAndIcon)
                Spacer()
                Text(hasBackgrounds ? "Tap a spot, swipe for backgrounds" : "Tap a spot to change it")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Button("Done", action: onDone)
                    .fontWeight(.semibold)
            }
            .font(.callout)
            .tint(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .padding(.horizontal, 16)
            .padding(.bottom, 34)
        }
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
                .accessibilityLabel("Edit the spots: change an icon, fill an empty one, choose what it opens")
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
