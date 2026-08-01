import CoreGraphics
import os
import SwiftUI

/// Positions the clip and places app tiles on it, before anything is built.
///
/// It has to happen here rather than on the phone: the crop and the placement
/// are baked into the glyph images when the fonts are generated, so nothing
/// downstream can move them. The canvas is the phone's screen in points, with
/// the widget's frame drawn on it, because that frame is the only part that
/// ends up animated - anything outside it is wallpaper.
struct LayoutEditor: View {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "LayoutEditor")

    @Binding var design: DesignDocument
    let model: DeviceModel
    let poster: CGImage?
    /// Where a chosen background is stored, so the editor can both read one
    /// back and write a newly picked one alongside the design.
    let store: DesignStore?
    /// What the toolbar's title says, and what its two buttons do. Supplied by
    /// the window, which owns saving and building.
    var documentName: String = "Design"
    var savedNote: String = ""
    var onPreview: () -> Void = {}
    var onBuild: () -> Void = {}

    /// What is being edited. A set because aligning needs more than one thing
    /// at a time; command-click adds to it.
    ///
    /// Internal rather than private so the toolbar, layer list and status bar
    /// in LayoutEditorChrome.swift can read it - they are this same view.
    @State var selection: Set<UUID> = []
    @State private var placementBase: MediaTransform?
    @State private var scaleBase: Double?
    @State private var tileBase: CGPoint?
    /// The selected tile is collecting an alternate from the catalogue.
    @State private var addingAlternate = false
    @State private var libraryTab: LibraryTab = .apps
    /// Keyboard focus for the canvas, so arrow keys nudge the selection.
    @FocusState private var canvasFocused: Bool
    /// Applied to tiles added later, so turning labels off once does not have
    /// to be repeated for every app placed after it.
    @State private var labelsDefault = true
    @State private var skins: [SkinLibrary.Skin] = []
    @State private var background: CGImage?
    @State private var skinNote: String?
    @State private var skinSets: [SkinSet] = []
    /// The set collecting a new entry from the catalogue popover.
    @State private var addingEntryTo: UUID?
    /// The sprite-sheet importer, which turns one picture into a whole set.
    @State private var importingSheet = false
    /// The variant whose clip is standing in for the primary on the canvas.
    @State var previewedVariantID: UUID?
    @State private var variantPoster: CGImage?
    /// The clip running on the canvas, decoded once and held as frames.
    ///
    /// Composed exactly as a build composes them - same transform, same
    /// background, same crop - so what plays here is what the phone gets,
    /// rather than a second opinion about it. Small, because the canvas is
    /// small and a full-size loop is hundreds of megabytes.
    @State private var playbackFrames: [CGImage] = []
    @State private var isPlaying = false
    @State private var isLoadingPlayback = false
    /// The asset whose key colour is being picked by clicking it.
    @State private var pickingKeyFor: UUID?
    /// Set while an option-drag is making a copy, so the drag moves the copy
    /// rather than making a new one on every tick.
    @State private var duplicatedDuringDrag: UUID?
    /// Canvas points per phone point. Everything on the canvas is measured
    /// through it, so the composition scales as one picture.
    @State var zoom: CGFloat = LayoutEditor.defaultZoom
    /// The space the canvas has to sit in, measured rather than assumed, so
    /// "Fit" can work out a zoom that actually fits.
    @State private var canvasViewport: CGSize = .zero
    /// The lines the current drag is locked to, drawn while it lasts.
    @State private var activeGuides: [SnapGuide] = []

    /// The one thing selected, when exactly one is. Most of the inspector only
    /// makes sense for a single item; alignment is what the rest is for.
    private var singleSelection: UUID? {
        selection.count == 1 ? selection.first : nil
    }

    private var selectedTiles: [PlacedTile] {
        design.tiles.filter { selection.contains($0.id) }
    }

    /// This design's own icon library. Skins used to sit in one folder shared
    /// by every design, so a pack imported for one turned up in the picker of
    /// all of them; they live with the design that uses them now.
    var skinLibrary: SkinLibrary? {
        guard let store else { return nil }
        return try? SkinLibrary(root: store.skinsFolder(for: design.id))
    }

    /// One snap engine for the whole editor, carrying the design's real grid.
    ///
    /// The threshold is divided by the zoom so it stays the same distance
    /// under the cursor: at 25% a 14px reach is barely three points on screen,
    /// and snapping feels broken rather than subtle.
    var snapEngine: SnapEngine {
        SnapEngine(
            threshold: 14 / max(zoom, 0.05),
            screenSize: model.screenPixelSize,
            widgetRect: design.widgetRect,
            grid: design.grid
        )
    }

    // MARK: - Zoom

    /// Steps rather than a free slider: the canvas is a phone, and the sizes
    /// worth working at are a short list.
    private static let zoomStops: [CGFloat] = [0.25, 0.35, 0.5, 0.62, 0.75, 1, 1.25, 1.5, 2, 2.5]

    func zoomIn() {
        zoom = Self.zoomStops.first { $0 > zoom + 0.001 } ?? Self.zoomRange.upperBound
    }

    func zoomOut() {
        zoom = Self.zoomStops.last { $0 < zoom - 0.001 } ?? Self.zoomRange.lowerBound
    }

    /// The largest zoom that still shows the whole phone, with the canvas
    /// padding left over. Falls back to the default before the viewport has
    /// been measured, which is the state on the very first frame.
    func zoomToFit() {
        guard canvasViewport.width > 1, canvasViewport.height > 1 else {
            zoom = Self.defaultZoom
            return
        }
        let padding: CGFloat = 56
        let fit = min(
            (canvasViewport.width - padding) / model.screenPointSize.width,
            (canvasViewport.height - padding) / model.screenPointSize.height
        )
        zoom = min(max(fit, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }

    /// Where the canvas starts, and what the window is sized against.
    static let defaultZoom: CGFloat = 0.62
    static let zoomRange: ClosedRange<CGFloat> = 0.25 ... 2.5

    private var canvas: CGSize {
        CGSize(
            width: model.screenPointSize.width * zoom,
            height: model.screenPointSize.height * zoom
        )
    }

    /// Canvas points per screen pixel. Every gesture converts through this, so
    /// a drag moves the same distance on the phone as under the cursor.
    private var unit: CGFloat { canvas.width / model.screenPixelSize.width }

    /// The clip standing on the canvas: a previewed variant's frame, or the
    /// primary's. One shared transform positions them all - placement centres
    /// every source at the same point - so switching only switches the picture.
    private var activePoster: CGImage? {
        previewedVariantID == nil ? poster : (variantPoster ?? poster)
    }

    /// The clip's own pixel size, taken from the frame rather than stored: the
    /// poster is a frame of the source, so it is the source's size by
    /// definition and cannot drift from it.
    private var sourceSize: CGSize {
        guard let poster = activePoster else { return model.screenPixelSize }
        return CGSize(width: poster.width, height: poster.height)
    }

    /// Where the clip actually lands on the screen, in screen pixels.
    ///
    /// The same call the generator makes, so the canvas shows what will be
    /// built rather than an approximation of it. Drawing the poster stretched
    /// to the canvas instead - which this did at first - showed a distorted
    /// picture that moved when nothing else did.
    private var placement: CGRect {
        MediaFrameExtractor.placement(
            sourceSize: sourceSize,
            screenSize: model.screenPixelSize,
            transform: design.mediaTransform
        )
    }

    /// Wide enough for the canvas with a panel on either side.
    ///
    /// Without it the sheet inherited the studio window's 520pt width and cut
    /// the sidebar and the Build button off the right edge.
    static func width(for model: DeviceModel) -> CGFloat {
        model.screenPointSize.width * defaultZoom + sidebarWidth + layersWidth + 90
    }

    static func height(for model: DeviceModel) -> CGFloat {
        model.screenPointSize.height * defaultZoom + 140
    }

    static let sidebarWidth: CGFloat = 250
    static let layersWidth: CGFloat = 170

    /// Layers on the left, canvas in the middle, inspector and libraries on
    /// the right, with a toolbar over all three and a status bar under them.
    ///
    /// The shape is the point: what is being edited is named in one place, the
    /// libraries never move, and lining things up is a button rather than a
    /// steady hand. See docs/studio-design-brief.md.
    var body: some View {
        VStack(spacing: 0) {
            editorToolbar
            HStack(alignment: .top, spacing: 0) {
                layersPanel
                GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        screen
                            .padding(28)
                            .frame(
                                minWidth: geometry.size.width,
                                minHeight: geometry.size.height
                            )
                    }
                    .onAppear { canvasViewport = geometry.size }
                    .onChange(of: geometry.size) { _, size in canvasViewport = size }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(StudioTheme.canvasBackground)
                // Scrolled, because the sidebar holds more than the window is
                // tall. Overflowing it squeezed the flexible child - the skin
                // grid - down to nothing, so an imported skin was in the view
                // tree and zero pixels high, which reads exactly like an
                // import that failed.
                ScrollView {
                    sidebar
                        .frame(width: Self.sidebarWidth, alignment: .leading)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 12)
                }
                .frame(width: Self.sidebarWidth + 30)
                .background(StudioTheme.panel)
                .overlay(alignment: .leading) {
                    Rectangle().fill(StudioTheme.panelEdge).frame(width: 1)
                }
            }
            statusBar
        }
        .background(StudioTheme.canvasWell)
        .sheet(isPresented: $importingSheet) {
            SpriteSheetImporter(library: skinLibrary) { imported in
                skinSets.append(imported)
                saveSkinSets()
                reloadSkins()
                skinNote = "Imported \(imported.name): \(imported.entries.count) app\(imported.entries.count == 1 ? "" : "s"). Apply it to a tile to offer the rest as swaps."
            }
        }
        // A fixed dark theme: the canvas is a phone screen, and a panel that
        // changed weight with the system appearance would change what the
        // artwork beside it looks like.
        .environment(\.colorScheme, .dark)
        .tint(StudioTheme.accent)
        .task {
            migrateSkins()
            reloadSkins()
            reloadBackground()
            reloadSkinSets()
        }
        .task(id: previewedVariantID) {
            guard let previewedVariantID, let store,
                  let variant = design.variants.first(where: { $0.id == previewedVariantID })
            else {
                variantPoster = nil
                return
            }
            variantPoster = try? await MediaFrameExtractor(
                url: store.variantClipURL(for: design.id, name: variant.sourceVideoName),
                screenSize: model.screenPixelSize
            ).posterFrame()
        }
        // Keyed on both, so switching clips while running reloads rather than
        // leaving the last one's frames on the canvas.
        .task(id: PlaybackRequest(clip: previewedVariantID, running: isPlaying)) {
            await loadPlayback()
        }
    }

    /// What a playback load is for, so the task restarts when either changes.
    private struct PlaybackRequest: Equatable {
        let clip: UUID?
        let running: Bool
    }

    /// Longest side of a decoded playback frame, in pixels.
    ///
    /// The canvas is a few hundred points wide, so decoding the loop at screen
    /// size would spend a hundred megabytes to draw the same picture. At this
    /// size a 96-frame loop is about 40MB, and it is freed when playback stops.
    private static let playbackLongestSide: CGFloat = 560

    /// Plays a clip on the canvas, or stops the one already running.
    private func togglePlayback(of variantID: UUID?) {
        guard !(isPlaying && previewedVariantID == variantID) else {
            stopPlayback()
            return
        }
        stopPlayback()
        previewedVariantID = variantID
        isPlaying = true
    }

    private func stopPlayback() {
        isPlaying = false
        isLoadingPlayback = false
        playbackFrames = []
    }

    /// Decodes the running clip's loop through the same path a build uses.
    private func loadPlayback() async {
        guard isPlaying, let store else { return }
        let variant = design.variants.first { $0.id == previewedVariantID }
        let source = variant.map { store.variantClipURL(for: design.id, name: $0.sourceVideoName) }
            ?? store.sourceVideoURL(for: design)

        let screen = model.screenPixelSize
        let scale = Self.playbackLongestSide / max(screen.width, screen.height)
        let reduced = CGSize(width: (screen.width * scale).rounded(), height: (screen.height * scale).rounded())

        let extractor = MediaFrameExtractor(
            url: source,
            screenSize: reduced,
            // Against the reduced screen, or the offset - which is screen
            // pixels - places the clip five times too far from centre.
            transform: design.mediaTransform.scaled(by: scale),
            background: design.backgroundName.flatMap {
                ImageLoader.load(
                    at: store.backgroundURL(for: design.id, name: $0),
                    maxPixelSize: Int(max(reduced.width, reduced.height))
                )
            },
            clipRect: design.backgroundName == nil ? nil : scaledRect(design.widgetRect, by: scale),
            clipCornerRadius: design.effectiveCornerRadius * scale
        )
        isLoadingPlayback = true
        defer { isLoadingPlayback = false }
        do {
            // A variant is its own length, measured the way the build measures
            // it, so what plays here wraps where the built one wraps.
            var count = design.loopFrameCount
            if variant != nil {
                count = FontSetGenerator.variantLoopLength(
                    duration: try await extractor.summary().duration,
                    spec: design.spec,
                    playbackSpeed: design.playbackSpeed
                )
            }
            let frames = try await extractor.composedFrames(
                startFrame: variant == nil ? design.loopStartFrame : 0,
                count: count,
                frameRate: design.spec.framesPerSecond,
                speed: design.playbackSpeed
            )
            guard isPlaying else { return }
            playbackFrames = frames
        } catch {
            // Named: a play button that does nothing is indistinguishable from
            // a clip that is all one frame.
            isPlaying = false
            // Logged as well as shown: the note is cleared by the next thing
            // that happens, and this is the only record of why a clip refused.
            Self.logger.error("""
            could not play \(source.lastPathComponent, privacy: .public): \
            \(String(describing: error), privacy: .public)
            """)
            skinNote = "Could not play \(source.lastPathComponent): \(error)"
        }
    }

    private func scaledRect(_ rect: CGRect, by scale: CGFloat) -> CGRect {
        CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
    }

    /// Brings whatever this design references over from the old shared
    /// library, so moving skins into the design does not empty its tiles.
    private func migrateSkins() {
        guard let library = skinLibrary else { return }
        var wanted = Set(design.tiles.compactMap(\.skin))
        wanted.formUnion(design.tiles.flatMap { $0.alternates.compactMap(\.skin) })
        wanted.formUnion(((try? SkinSetStore().all()) ?? []).flatMap { $0.entries.map(\.skin) })
        let carried = SkinLibrary.migrateIfNeeded(wanted, into: library)
        if carried > 0 {
            skinNote = "Brought \(carried) skin\(carried == 1 ? "" : "s") into this design."
        }
    }

    private func reloadSkinSets() {
        do {
            skinSets = try SkinSetStore().all()
        } catch {
            skinNote = "Could not read the skin sets: \(error)"
        }
    }

    private func saveSkinSets() {
        do {
            try SkinSetStore().save(skinSets)
        } catch {
            skinNote = "Could not save the skin sets: \(error)"
        }
    }

    private func reloadBackground() {
        guard let store, let name = design.backgroundName else {
            background = nil
            return
        }
        background = ImageLoader.load(
            at: store.backgroundURL(for: design.id, name: name),
            maxPixelSize: Int(model.screenPixelSize.height)
        )
    }

    /// Copied in next to the design rather than referenced where it sits: a
    /// design reopened next week should still find its background.
    private func chooseBackground() {
        guard let store else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let source = panel.url else { return }

        let name = "background.\(source.pathExtension.isEmpty ? "png" : source.pathExtension)"
        let destination = store.backgroundURL(for: design.id, name: name)
        do {
            try store.createFolder(for: design.id)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            design.backgroundName = name
            reloadBackground()
        } catch {
            design.backgroundName = nil
        }
    }

    private func reloadSkins() {
        skins = skinLibrary?.all() ?? []
    }

    /// One tile's own artwork, imported for it alone.
    ///
    /// There used to be a library browser here: every skin in the design, laid
    /// out in a grid, with a tile selected to receive one. An iconset carries
    /// both the artwork and the app each piece opens, so that grid was the long
    /// way round to what a set does in one action. What it was still good for
    /// is the single odd icon a set has no entry for, and that is what this is.
    @ViewBuilder
    private func customIconRow(index: Int) -> some View {
        let tile = design.tiles[index]
        HStack(spacing: 6) {
            Text("Icon").font(.caption).foregroundStyle(.secondary)
            if let skin = tile.skin {
                AsyncSkinThumbnail(url: skinLibrary?.url(for: skin))
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .help(skin)
                Text(fromSet(skin) ?? "its own")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Clear") { clearCustomIcon(at: index) }
                    .buttonStyle(.studioCompact)
            } else {
                Text("the catalogue plate")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Custom...") { importCustomIcon(at: index) }
                    .buttonStyle(.studioCompact)
            }
        }
    }

    /// The set an icon came from, so the inspector can say where it got it
    /// rather than implying every icon was picked by hand.
    private func fromSet(_ skin: String) -> String? {
        skinSets.first { $0.entries.contains { $0.skin == skin } }?.name
    }

    /// Puts one imported picture on one tile.
    private func importCustomIcon(at index: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            // Reported rather than swallowed: an import that failed silently
            // looks exactly like one that worked, which is how a working
            // import once came to look broken.
            guard let library = skinLibrary else { return }
            let added = try library.importing([source])
            reloadSkins()
            guard let name = added.first else {
                skinNote = "Could not read \(source.lastPathComponent)."
                return
            }
            design.tiles[index].skin = name
            skinNote = nil
        } catch {
            skinNote = "Import failed: \(error.localizedDescription)"
        }
    }

    /// Takes the icon off a tile, and the file with it when it was that tile's
    /// alone - there is no browser to find an orphan in any more.
    private func clearCustomIcon(at index: Int) {
        guard let name = design.tiles[index].skin else { return }
        design.tiles[index].skin = nil
        if SkinReferences.isUnused(name, tiles: design.tiles, sets: skinSets) {
            skinLibrary?.remove(name)
            reloadSkins()
        }
    }

    /// Everything is layered as an overlay on a fixed-size black rectangle
    /// rather than stacked in a `ZStack`.
    ///
    /// The backdrop fill is deliberately larger than the screen, and inside a
    /// `ZStack` an oversized child grows the stack - so every `topLeading`
    /// offset ends up measured from a box bigger than the visible canvas and
    /// the whole composition shifts, widget frame included. An overlay adopts
    /// its base's size and cannot enlarge it, so the offsets stay honest.
    private var screen: some View {
        Color.black
            .frame(width: canvas.width, height: canvas.height)
            .overlay(alignment: .topLeading) { layers }
            .clipShape(RoundedRectangle(cornerRadius: 34 * zoom, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 34 * zoom, style: .continuous)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 1)
            )
            .gesture(clipDrag)
            .simultaneousGesture(clipZoom)
            .onTapGesture { selection = [] }
            .focusable()
            .focusEffectDisabled()
            .focused($canvasFocused)
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat]) { press in
                let step: CGFloat = press.modifiers.contains(.shift) ? 10 : 1
                let moved = switch press.key {
                case .leftArrow: nudgeSelection(dx: -step, dy: 0)
                case .rightArrow: nudgeSelection(dx: step, dy: 0)
                case .upArrow: nudgeSelection(dx: 0, dy: -step)
                case .downArrow: nudgeSelection(dx: 0, dy: step)
                default: false
                }
                return moved ? .handled : .ignored
            }
            // Selecting something on the canvas is the intent to work on it,
            // arrow keys included.
            .onChange(of: selection) { _, value in
                if !value.isEmpty { canvasFocused = true }
            }
    }

    /// The cells, drawn only while snapping is on: they are a placement aid,
    /// and a grid over a design nobody is snapping is just noise.
    @ViewBuilder
    private var gridOverlay: some View {
        if design.snapEnabled {
            let frame = design.widgetRect
            ForEach(design.grid.allCells, id: \.self) { cell in
                let rect = design.grid.cellRect(cell, in: frame)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        .white.opacity(occupiedCells.contains(cell) ? 0.08 : 0.22),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                    )
                    .frame(width: rect.width * unit, height: rect.height * unit)
                    .offset(x: rect.minX * unit, y: rect.minY * unit)
            }
            .allowsHitTesting(false)
        }
    }

    /// The lines a drag is locked to. They appear only while it lasts, which
    /// is what makes them read as feedback rather than as part of the design.
    @ViewBuilder
    private var guideOverlay: some View {
        ForEach(activeGuides) { guide in
            switch guide.axis {
            case .vertical:
                Rectangle()
                    .fill(StudioTheme.accent.opacity(0.9))
                    .frame(width: 1, height: canvas.height)
                    .offset(x: guide.position * unit)
            case .horizontal:
                Rectangle()
                    .fill(StudioTheme.accent.opacity(0.9))
                    .frame(width: canvas.width, height: 1)
                    .offset(y: guide.position * unit)
            }
        }
        .allowsHitTesting(false)
    }

    private var occupiedCells: Set<GridCell> {
        Set(design.tiles.compactMap(\.cell))
    }

    /// Click selects; command-click adds to the selection, so several tiles
    /// can be aligned together.
    func select(_ id: UUID) {
        if NSEvent.modifierFlags.contains(.command) {
            if selection.contains(id) {
                selection.remove(id)
            } else {
                selection.insert(id)
            }
        } else {
            selection = [id]
        }
    }

    /// The clip, in canvas coordinates.
    ///
    /// Wrapped in a canvas-sized container before being masked, because a mask
    /// applies in the coordinate space of the thing it masks: masking the
    /// offset image directly would clip against the image's own bounds and cut
    /// the wrong region entirely.
    private func clipLayer(poster: CGImage) -> some View {
        let rect = placement
        let frame = design.widgetRect
        return Color.clear
            .frame(width: canvas.width, height: canvas.height)
            .overlay(alignment: .topLeading) {
                Image(decorative: poster, scale: 1)
                    .resizable()
                    .frame(width: rect.width * unit, height: rect.height * unit)
                    .offset(x: rect.minX * unit, y: rect.minY * unit)
            }
            .mask(alignment: .topLeading) {
                // With a background chosen the clip stops at the widget frame:
                // beyond it the wallpaper should be the picture that was
                // picked, not the clip running past the only place it animates.
                if background == nil {
                    Rectangle()
                } else {
                    RoundedRectangle(cornerRadius: design.effectiveCornerRadius * unit, style: .continuous)
                        .frame(width: frame.width * unit, height: frame.height * unit)
                        .offset(x: frame.minX * unit, y: frame.minY * unit)
                }
            }
    }

    private var layers: some View {
        ZStack(alignment: .topLeading) {
            // Zero-sized anchor: it fixes the stack's origin at the canvas's
            // top left so the offsets below are measured from there.
            Color.clear.frame(width: 0, height: 0)
            // A chosen background replaces the derived fill, at full strength,
            // exactly as the compositor does it.
            if let background {
                Image(decorative: background, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: canvas.width, height: canvas.height)
                    .clipped()
            }
            if !playbackFrames.isEmpty {
                // A composed frame already carries the placement, the fill and
                // the background, so it stands in for both layers below rather
                // than on top of them.
                PlayingClip(frames: playbackFrames, framesPerSecond: design.spec.framesPerSecond)
                    .frame(width: canvas.width, height: canvas.height)
                    .clipped()
            } else if let poster = activePoster {
                // The generator fills whatever the clip does not cover with a
                // dimmed blow-up of the same frame rather than black. Drawing
                // black here instead - which this did - meant the wallpaper
                // that came out did not look like the one that was positioned.
                if background == nil, design.mediaTransform.fillsBackground {
                    let fill = MediaFrameExtractor.backdropPlacement(
                        sourceSize: sourceSize,
                        screenSize: model.screenPixelSize
                    )
                    Image(decorative: poster, scale: 1)
                        .resizable()
                        .opacity(MediaFrameExtractor.backdropOpacity)
                        .frame(width: fill.width * unit, height: fill.height * unit)
                        .offset(x: fill.minX * unit, y: fill.minY * unit)
                }
                clipLayer(poster: poster)
            }
            widgetFrame
            gridOverlay
            guideOverlay
            // Under the tiles, matching what the wallpaper bakes, so the canvas
            // shows the stacking the phone will actually have.
            ForEach(design.assets.sorted { $0.zIndex < $1.zIndex }) { asset in
                assetView(asset)
            }
            ForEach(design.tiles) { tile in
                tileView(tile)
            }
        }
    }

    /// The animated region, drawn so the clip can be positioned against it
    /// rather than against the whole screen.
    private var widgetFrame: some View {
        let rect = design.widgetRect
        return RoundedRectangle(cornerRadius: design.effectiveCornerRadius * unit, style: .continuous)
            .strokeBorder(.white.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .frame(width: rect.width * unit, height: rect.height * unit)
            .offset(x: rect.minX * unit, y: rect.minY * unit)
            .allowsHitTesting(false)
    }

    private func tileView(_ tile: PlacedTile) -> some View {
        let side = tile.size * unit
        return TileView(
            tile: tile,
            side: side,
            isSelected: selection.contains(tile.id),
            iconImage: tile.skin
                .flatMap { skinLibrary?.url(for: $0) }
                .flatMap { ImageLoader.load(at: $0, maxPixelSize: Int(side * 3)) }
                .map { Image(decorative: $0, scale: 1) }
        )
            .frame(width: side, height: side)
            .offset(x: tile.rect.minX * unit, y: tile.rect.minY * unit)
            .gesture(tileDrag(tile))
            .onTapGesture { select(tile.id) }
    }

    private func assetView(_ asset: PlacedAsset) -> some View {
        let width = asset.size.width * unit
        let height = asset.size.height * unit
        return Group {
            if let image = assetImage(asset) {
                Image(decorative: image, scale: 1).resizable()
            } else {
                // A missing file is shown rather than skipped: an asset that
                // silently vanishes reads as a bug in placement.
                ZStack {
                    Rectangle().fill(.red.opacity(0.15))
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
        }
        .frame(width: width, height: height)
        // Before the rotation on purpose: the tap then lands in the picture's
        // own unrotated space, which maps straight onto its pixels.
        .overlay {
            if pickingKeyFor == asset.id {
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { value in
                        pickKey(
                            for: asset,
                            at: value.location,
                            in: CGSize(width: width, height: height)
                        )
                    })
            }
        }
        .rotationEffect(.degrees(asset.rotation))
        .opacity(asset.opacity)
        .overlay {
            if selection.contains(asset.id) {
                Rectangle().strokeBorder(.white.opacity(0.9), lineWidth: 1)
                    .rotationEffect(.degrees(asset.rotation))
            }
        }
        .offset(x: asset.rect.minX * unit, y: asset.rect.minY * unit)
        .gesture(assetDrag(asset))
        .onTapGesture { select(asset.id) }
    }

    private func assetImage(_ asset: PlacedAsset) -> CGImage? {
        guard let store else { return nil }
        return AssetArtwork.image(for: asset, designID: design.id, store: store)
    }

    private func assetDrag(_ asset: PlacedAsset) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard let index = design.assets.firstIndex(where: { $0.id == asset.id })
                else { return }
                let base = tileBase ?? asset.center
                if tileBase == nil {
                    tileBase = base
                    selection = [asset.id]
                }
                design.assets[index].center = CGPoint(
                    x: base.x + value.translation.width / unit,
                    y: base.y + value.translation.height / unit
                )
            }
            .onEnded { _ in tileBase = nil }
    }

    // MARK: - Gestures

    private var clipDrag: some Gesture {
        DragGesture()
            .onChanged { value in
                let base = placementBase ?? design.mediaTransform
                if placementBase == nil { placementBase = base }
                // Divided by `unit` so a drag moves the clip by what the
                // cursor covered on the phone, not on the canvas.
                design.mediaTransform.offset = CGPoint(
                    x: base.offset.x + value.translation.width / unit,
                    y: base.offset.y + value.translation.height / unit
                )
            }
            .onEnded { _ in placementBase = nil }
    }

    /// Uniform, and anchored on the middle of the widget frame.
    ///
    /// Uniform because a clip stretched to fit reads as broken rather than
    /// framed, and anchored there because that is the part anyone is looking
    /// at while they size it - scaling about the screen's centre slides the
    /// subject out of the frame as it grows.
    private var clipZoom: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = scaleBase ?? design.mediaTransform.scale
                if scaleBase == nil { scaleBase = base }
                setScale(base * value.magnification)
            }
            .onEnded { _ in scaleBase = nil }
    }

    private func setScale(_ scale: Double) {
        let frame = design.widgetRect
        design.mediaTransform = MediaFrameExtractor.transform(
            design.mediaTransform,
            scaledTo: min(max(scale, 0.1), 8),
            anchoredAt: CGPoint(x: frame.midX, y: frame.midY),
            sourceSize: sourceSize,
            screenSize: model.screenPixelSize
        )
    }

    private func tileDrag(_ tile: PlacedTile) -> some Gesture {
        DragGesture()
            .onChanged { value in
                // Option-drag leaves the original where it is and moves a copy,
                // made once at the start of the gesture rather than per tick.
                var draggedID = duplicatedDuringDrag ?? tile.id
                if tileBase == nil {
                    if NSEvent.modifierFlags.contains(.option) {
                        var copy = tile
                        copy.id = UUID()
                        copy.cell = nil
                        design.tiles.append(copy)
                        duplicatedDuringDrag = copy.id
                        draggedID = copy.id
                    }
                    tileBase = tile.center
                    selection = [draggedID]
                }
                guard let index = design.tiles.firstIndex(where: { $0.id == draggedID }),
                      let base = tileBase
                else { return }

                let moved = CGPoint(
                    x: base.x + value.translation.width / unit,
                    y: base.y + value.translation.height / unit
                )
                let extent = design.tiles[index].boundingExtent
                let engine = snapEngine
                // Bounded by the screen, not by the widget frame: a tile may
                // hang over the edge, because the wallpaper carries a picture
                // of the part the widget cannot draw.
                guard design.snapEnabled else {
                    design.tiles[index].center = engine.clamp(center: moved, tileSize: extent)
                    // Dragged by hand with snapping off, so it holds no cell -
                    // the layer list says "off grid" rather than naming one it
                    // has left.
                    design.tiles[index].cell = nil
                    return
                }

                // The grid first, then the sibling guides: a cell is a
                // deliberate slot, and a tile a few pixels from one means that
                // one. Guides still catch anything placed between cells.
                let frame = design.widgetRect
                if let cell = design.grid.nearestCell(to: moved, in: frame) {
                    let centre = design.grid.cellCenter(cell, in: frame)
                    let reach = design.grid.tileSide(in: frame) * 0.45
                    let taken = design.tiles.contains { $0.id != draggedID && $0.cell == cell }
                    if !taken, abs(centre.x - moved.x) < reach, abs(centre.y - moved.y) < reach {
                        design.tiles[index].center = centre
                        design.tiles[index].cell = cell
                        activeGuides = [
                            SnapGuide(axis: .vertical, position: centre.x, kind: .iconGrid),
                            SnapGuide(axis: .horizontal, position: centre.y, kind: .iconGrid),
                        ]
                        return
                    }
                }
                let snapped = engine.snap(
                    center: moved,
                    tileSize: extent,
                    siblings: design.tiles.filter { $0.id != draggedID }
                )
                design.tiles[index].center = engine.clamp(center: snapped.center, tileSize: extent)
                design.tiles[index].cell = nil
                activeGuides = snapped.guides
            }
            .onEnded { _ in
                tileBase = nil
                duplicatedDuringDrag = nil
                activeGuides = []
            }
    }

    // MARK: - Assets

    private var selectedAsset: PlacedAsset? {
        guard let singleSelection else { return nil }
        return design.assets.first { $0.id == singleSelection }
    }

    /// Bindings resolve the asset by id on every access rather than closing over
    /// an index. An index taken while the inspector renders outlives the array
    /// it indexed - removing an asset while its slider is live would read off
    /// the end - and identity is what the inspector is really about anyway.
    private func assetBinding<Value>(
        _ id: UUID,
        _ path: WritableKeyPath<PlacedAsset, Value>,
        fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: { design.assets.first { $0.id == id }?[keyPath: path] ?? fallback },
            set: { newValue in
                guard let index = design.assets.firstIndex(where: { $0.id == id }) else { return }
                design.assets[index][keyPath: path] = newValue
            }
        )
    }

    private func chromaBinding(
        _ id: UUID,
        _ path: WritableKeyPath<ChromaKey.Settings, Double>
    ) -> Binding<Double> {
        Binding(
            get: { (design.assets.first { $0.id == id }?.chroma ?? .default)[keyPath: path] },
            set: { newValue in
                guard let index = design.assets.firstIndex(where: { $0.id == id }) else { return }
                var settings = design.assets[index].chroma ?? ChromaKey.Settings.default
                settings[keyPath: path] = newValue
                design.assets[index].chroma = settings
            }
        )
    }

    @ViewBuilder
    private var assetsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                StudioTheme.eyebrow("Pictures").foregroundStyle(StudioTheme.textTertiary)
                Spacer()
                Button("Add...") { importAssets() }.buttonStyle(.link)
            }

            if design.assets.isEmpty {
                Text("Any image, placed anywhere and drawn under the app tiles. A coloured backdrop is keyed out, and it can be retuned here at any time.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(design.assets.sorted { $0.zIndex < $1.zIndex }) { asset in
                    HStack(spacing: 6) {
                        Image(systemName: selection.contains(asset.id) ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(.secondary)
                        Text(asset.fileName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .font(.caption)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { select(asset.id) }
                    .contextMenu {
                        Button("Bring to front") { restack(asset, toFront: true) }
                        Button("Send to back") { restack(asset, toFront: false) }
                        Button("Remove", role: .destructive) { removeAsset(asset) }
                    }
                }
            }

        }
        .disabled(store == nil)
    }

    @ViewBuilder
    private func assetInspector(_ asset: PlacedAsset) -> some View {
        Divider()
        VStack(alignment: .leading, spacing: 4) {
            Text(asset.fileName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            LabeledContent("Width", value: "\(Int(asset.size.width)) px")
                .font(.caption2)
            // Height follows width: an asset is scaled, not stretched. The
            // aspect comes from the size it was imported at.
            Slider(
                value: Binding(
                    get: { asset.size.width },
                    set: { newWidth in
                        guard let index = design.assets.firstIndex(where: { $0.id == asset.id })
                        else { return }
                        let current = design.assets[index].size
                        let aspect = current.height / max(current.width, 1)
                        design.assets[index].size = CGSize(
                            width: newWidth,
                            height: newWidth * aspect
                        )
                    }
                ),
                in: 40 ... model.screenPixelSize.width * 1.5
            )

            LabeledContent("Rotation", value: "\(Int(asset.rotation))°").font(.caption2)
            Slider(value: assetBinding(asset.id, \.rotation, fallback: 0), in: -180 ... 180)

            LabeledContent("Opacity", value: String(format: "%.2f", asset.opacity)).font(.caption2)
            Slider(value: assetBinding(asset.id, \.opacity, fallback: 1), in: 0 ... 1)

            Divider()
            keyingControls(asset)
        }
    }

    @ViewBuilder
    private func keyingControls(_ asset: PlacedAsset) -> some View {
        let chroma = asset.chroma ?? ChromaKey.Settings.default
        Toggle("Remove backdrop", isOn: Binding(
            get: { design.assets.first { $0.id == asset.id }?.chroma?.enabled ?? false },
            set: { on in
                guard let index = design.assets.firstIndex(where: { $0.id == asset.id })
                else { return }
                var settings = design.assets[index].chroma ?? ChromaKey.Settings.default
                settings.enabled = on
                design.assets[index].chroma = settings
            }
        ))
        .font(.caption)

        if chroma.enabled {
            LabeledContent("Tolerance", value: String(format: "%.2f", chroma.tolerance))
                .font(.caption2)
            Slider(value: chromaBinding(asset.id, \.tolerance), in: 0 ... 2)

            LabeledContent("Edge softness", value: String(format: "%.2f", chroma.softness))
                .font(.caption2)
            Slider(value: chromaBinding(asset.id, \.softness), in: 0 ... 2)

            LabeledContent("Spill removal", value: String(format: "%.2f", chroma.spill))
                .font(.caption2)
            Slider(value: chromaBinding(asset.id, \.spill), in: 0 ... 1)

            HStack {
                Text(chroma.keyColor == nil ? "Colour: detected" : "Colour: chosen")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if chroma.keyColor != nil {
                    Button("Redetect") {
                        guard let index = design.assets.firstIndex(where: { $0.id == asset.id })
                        else { return }
                        design.assets[index].chroma?.setKeyColor(nil)
                    }
                    .buttonStyle(.link).font(.caption2)
                }
            }

            Button(pickingKeyFor == asset.id ? "Click the backdrop..." : "Pick colour") {
                pickingKeyFor = pickingKeyFor == asset.id ? nil : asset.id
            }
            .buttonStyle(.link)
            .font(.caption2)
            .help("Detection reads the border. Pick instead when the backdrop is not what surrounds the picture.")
        }
    }

    private func importAssets() {
        guard let store else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            do {
                let name = try store.importAsset(url, for: design.id)
                let placed = store.assetURL(for: design.id, name: name)
                design.assets.append(newAsset(named: name, at: placed))
            } catch {
                skinNote = "Could not add \(url.lastPathComponent): \(error)"
            }
        }
    }

    /// Placed in the middle of the widget frame, at a size that fits it, so a
    /// picture lands somewhere visible rather than off-screen at full
    /// resolution.
    private func newAsset(named name: String, at url: URL) -> PlacedAsset {
        let rect = design.widgetRect
        var size = CGSize(width: rect.width * 0.5, height: rect.width * 0.5)
        if let image = ImageLoader.load(at: url, maxPixelSize: 64) {
            let aspect = CGFloat(image.height) / CGFloat(max(image.width, 1))
            size = CGSize(width: rect.width * 0.5, height: rect.width * 0.5 * aspect)
        }
        return PlacedAsset(
            fileName: name,
            center: CGPoint(x: rect.midX, y: rect.midY),
            size: size,
            zIndex: (design.assets.map(\.zIndex).max() ?? 0) + 1
        )
    }

    /// Samples the colour under a click and keys on that instead of the
    /// detected border colour. Detection reads the border, which is wrong
    /// whenever the backdrop is not what surrounds the picture.
    private func pickKey(for asset: PlacedAsset, at point: CGPoint, in size: CGSize) {
        guard let store,
              let index = design.assets.firstIndex(where: { $0.id == asset.id }),
              size.width > 0, size.height > 0
        else { return }

        let unitPoint = CGPoint(x: point.x / size.width, y: point.y / size.height)
        guard let colour = AssetArtwork.sampleColor(
            in: asset, designID: design.id, store: store, at: unitPoint
        ) else {
            skinNote = "Could not read that pixel - it may be fully transparent."
            return
        }

        var settings = design.assets[index].chroma ?? ChromaKey.Settings.default
        settings.enabled = true
        settings.setKeyColor(colour)
        design.assets[index].chroma = settings
        pickingKeyFor = nil
    }

    private func restack(_ asset: PlacedAsset, toFront: Bool) {
        guard let index = design.assets.firstIndex(where: { $0.id == asset.id }) else { return }
        let levels = design.assets.map(\.zIndex)
        design.assets[index].zIndex = toFront
            ? (levels.max() ?? 0) + 1
            : (levels.min() ?? 0) - 1
    }

    /// Takes the file with it. An asset lives in the design, so leaving the
    /// picture behind would grow the folder every time one is swapped out.
    private func removeAsset(_ asset: PlacedAsset) {
        design.assets.removeAll { $0.id == asset.id }
        selection.remove(asset.id)
        store?.removeAsset(named: asset.fileName, for: design.id)
    }

    // MARK: - Skin sets

    /// Themed icon packs: one picture per app, drawn in one style. Applying a
    /// set fills a tile's artwork and its swap list in one step, so "the neon
    /// icons" is authored once and reused on every design.
    @ViewBuilder
    private var skinSetsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                StudioTheme.eyebrow("Skin sets").foregroundStyle(StudioTheme.textTertiary)
                Spacer()
                Button("Sheet...") { importingSheet = true }
                    .buttonStyle(.link)
                    .help("Cut a sprite sheet into a set, using a table of names")
                Button("New set") {
                    skinSets.append(SkinSet(name: "Set \(skinSets.count + 1)"))
                    saveSkinSets()
                }
                .buttonStyle(.link)
            }

            if skinSets.isEmpty {
                Text("A set pairs each app with a picture in one style - like an icon pack. Apply it to a tile and the phone can swap that slot to any other app in the set, artwork and link together.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach($skinSets) { $set in
                DisclosureGroup {
                    skinSetBody($set)
                } label: {
                    TextField("Name", text: Binding(
                        get: { set.name },
                        set: { set.name = $0; saveSkinSets() }
                    ))
                    .textFieldStyle(.plain)
                    .font(.caption.weight(.medium))
                }
            }
        }
        .disabled(store == nil)
    }

    @ViewBuilder
    private func skinSetBody(_ set: Binding<SkinSet>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(set.wrappedValue.entries) { entry in
                HStack(spacing: 6) {
                    Circle()
                        .fill(AppCatalog.app(id: entry.appID)?.tint ?? .gray)
                        .frame(width: 8, height: 8)
                    Text(AppCatalog.app(id: entry.appID)?.name ?? entry.appID)
                        .font(.caption)
                    AsyncSkinThumbnail(url: skinLibrary?.url(for: entry.skin))
                        .frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    if set.wrappedValue.defaultAppID == entry.appID {
                        Text("default")
                            .font(.system(size: 9).monospaced())
                            .foregroundStyle(StudioTheme.accent)
                    }
                    Spacer()
                    Button {
                        set.wrappedValue.entries.removeAll { $0.appID == entry.appID }
                        if set.wrappedValue.defaultAppID == entry.appID {
                            set.wrappedValue.defaultAppID = nil
                        }
                        saveSkinSets()
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Remove \(AppCatalog.app(id: entry.appID)?.name ?? entry.appID) from the set")
                }
                .contentShape(Rectangle())
                // Clicking an entry connects it to whatever is selected: this
                // icon, and the app it stands for, on that tile.
                .onTapGesture { use(entry, from: set.wrappedValue) }
                .contextMenu {
                    Button("Put on the selected tile") { use(entry, from: set.wrappedValue) }
                    Button("Make this the set's default") {
                        set.wrappedValue.defaultAppID = entry.appID
                        saveSkinSets()
                    }
                }
                .help("Put \(AppCatalog.app(id: entry.appID)?.name ?? entry.appID) on the selected tile")
            }

            HStack {
                Button("Add app...") { addingEntryTo = set.wrappedValue.id }
                    .buttonStyle(.link)
                    .font(.caption)
                    .popover(isPresented: Binding(
                        get: { addingEntryTo == set.wrappedValue.id },
                        set: { if !$0 { addingEntryTo = nil } }
                    )) {
                        CataloguePicker { appID in
                            addingEntryTo = nil
                            addEntry(appID: appID, to: set)
                        }
                    }
                Spacer()
                Button("Delete set", role: .destructive) {
                    skinSets.removeAll { $0.id == set.wrappedValue.id }
                    saveSkinSets()
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            if !set.wrappedValue.entries.isEmpty {
                HStack {
                    if let singleSelection, design.tiles.contains(where: { $0.id == singleSelection }) {
                        Button("Apply to selected tile") {
                            apply(set.wrappedValue, onlyTo: singleSelection)
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                    Button("Apply to all tiles") {
                        apply(set.wrappedValue, onlyTo: nil)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                Text("Adding an app the set already has replaces its picture. Applying rewrites the tile's swap list to this set.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 4)
    }

    /// Puts one entry of a set on the selected tile: its artwork, and the app
    /// it stands for.
    ///
    /// Both at once, because that is what an entry is - a picture of an app.
    /// Either half can still be changed on its own afterwards, from the Opens
    /// picker or the Skins grid.
    private func use(_ entry: SkinSet.Entry, from set: SkinSet) {
        guard let singleSelection,
              let index = design.tiles.firstIndex(where: { $0.id == singleSelection })
        else {
            skinNote = "Select a tile first, then click an app in the set to put it there."
            return
        }
        design.tiles[index].appID = entry.appID
        design.tiles[index].custom = nil
        design.tiles[index].skin = entry.skin
        design.tiles[index].icon = nil
        // The rest of the set becomes what the phone can swap this slot to.
        design.tiles[index].alternates = set.entries
            .filter { $0.appID != entry.appID }
            .map { TileAlternate(appID: $0.appID, skin: $0.skin) }
        skinNote = "\(AppCatalog.app(id: entry.appID)?.name ?? entry.appID) from \(set.name)."
    }

    /// Picks the picture for a newly added app, imported through the library
    /// so it is keyed, trimmed and squared like every other skin.
    private func addEntry(appID: String, to set: Binding<SkinSet>) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose the \(AppCatalog.app(id: appID)?.name ?? appID) picture for this set"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            guard let library = skinLibrary,
                  let imported = try library.importing([source]).first else {
                skinNote = "Could not read \(source.lastPathComponent) as an image."
                return
            }
            set.wrappedValue.setEntry(appID: appID, skin: imported)
            saveSkinSets()
            reloadSkins()
        } catch {
            skinNote = "Could not import \(source.lastPathComponent): \(error)"
        }
    }

    /// `onlyTo: nil` applies to every tile: each keeps its own app as the
    /// default and gets the rest of the set to swap to - four defaults of one
    /// set is just four tiles this ran across.
    private func apply(_ set: SkinSet, onlyTo tileID: UUID?) {
        var touched = 0
        for index in design.tiles.indices
        where tileID == nil || design.tiles[index].id == tileID {
            design.tiles[index] = set.applied(to: design.tiles[index])
            touched += 1
        }
        skinNote = "Applied \(set.name) to \(touched) tile\(touched == 1 ? "" : "s")."
    }

    // MARK: - Variants

    /// Alternative clips for the animated area - same layout, same crop, and
    /// the phone picks which one plays. Authored here because every variant is
    /// a full lane-font set that has to be compiled into the install.
    @ViewBuilder
    private var variantsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                StudioTheme.eyebrow("Animation variants").foregroundStyle(StudioTheme.textTertiary)
                Spacer()
                Button("Add...") { importVariants() }.buttonStyle(.link)
            }

            if design.variants.isEmpty {
                Text("Other clips for the same design - like five idle animations of one scene. The phone chooses which plays. Each adds about 29MB of fonts to the install.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The design's own clip is in the list because it is one of the
            // choices on the phone: it can be named and it can be led with,
            // exactly like the rest.
            clipRow(
                name: Binding(
                    get: { design.primaryClipTitle },
                    set: { design.primaryClipName = $0.isEmpty ? nil : $0 }
                ),
                isPreviewed: previewedVariantID == nil,
                isDefault: design.defaultVariantID == nil,
                onPreview: { previewedVariantID = nil },
                onDefault: { design.defaultVariantID = nil },
                onPlay: { togglePlayback(of: nil) },
                isPlaying: isPlaying && previewedVariantID == nil,
                isLoading: isLoadingPlayback && previewedVariantID == nil,
                // A scene is its clip, so the last one cannot go. With others
                // to take over it can: one of them becomes the design's own.
                onRemove: design.variants.isEmpty ? nil : { removePrimaryClip() }
            )

            ForEach(design.variants) { variant in
                clipRow(
                    name: Binding(
                        get: { variant.name },
                        set: { newName in
                            guard let index = design.variants.firstIndex(where: { $0.id == variant.id })
                            else { return }
                            design.variants[index].name = newName
                        }
                    ),
                    isPreviewed: previewedVariantID == variant.id,
                    isDefault: design.defaultVariantID == variant.id,
                    onPreview: {
                        previewedVariantID = previewedVariantID == variant.id ? nil : variant.id
                    },
                    onDefault: { design.defaultVariantID = variant.id },
                    onPlay: { togglePlayback(of: variant.id) },
                    isPlaying: isPlaying && previewedVariantID == variant.id,
                    isLoading: isLoadingPlayback && previewedVariantID == variant.id,
                    onRemove: { removeVariant(variant) }
                )
            }

            if !design.variants.isEmpty {
                Text("Click a clip to see it on the canvas, and the star to lead with it - a phone shows that one until it picks another. Position and crop are shared, and each clip loops at its own length.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(store == nil)
    }

    /// One clip in the list: what it is called, whether the canvas is showing
    /// it, whether the phone leads with it, and whether it is running.
    /// `onRemove` is nil while this clip is the only one the scene has.
    @ViewBuilder
    private func clipRow(
        name: Binding<String>,
        isPreviewed: Bool,
        isDefault: Bool,
        onPreview: @escaping () -> Void,
        onDefault: @escaping () -> Void,
        onPlay: @escaping () -> Void,
        isPlaying: Bool,
        isLoading: Bool,
        onRemove: (() -> Void)?
    ) -> some View {
        HStack(spacing: 6) {
            Button(action: onPreview) {
                Image(systemName: isPreviewed ? "eye.fill" : "film")
                    .font(.caption2)
                    .foregroundStyle(isPreviewed ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("Show this clip on the canvas")

            Button(action: onPlay) {
                // A six-second clip takes a couple of seconds to decode, and
                // silence for that long is indistinguishable from a play
                // button that does not work.
                if isLoading {
                    ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 11, height: 11)
                } else {
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                        .font(.caption2)
                        .foregroundStyle(isPlaying ? Color.accentColor : .secondary)
                }
            }
            .buttonStyle(.plain)
            .help(isPlaying ? "Stop" : "Play this clip on the canvas")

            // A field rather than a label: the name is what the phone's list
            // shows, and a clip called "Variant 3" says nothing there.
            TextField("Name", text: name)
                .textFieldStyle(.plain)
                .font(.caption)
                .foregroundStyle(isPreviewed ? Color.accentColor : .primary)
                .lineLimit(1)

            Button(action: onDefault) {
                Image(systemName: isDefault ? "star.fill" : "star")
                    .font(.caption2)
                    .foregroundStyle(isDefault ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(isDefault)
            .help(isDefault ? "Phones show this one first" : "Show this one first on a phone")

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .help("Remove this clip")
            }
        }
    }

    private func importVariants() {
        guard let store else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .gif, .quickTimeMovie, .mpeg4Movie]
        panel.allowsMultipleSelection = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        for url in panel.urls {
            do {
                let name = try store.importVariantClip(url, for: design.id)
                let stem = url.deletingPathExtension().lastPathComponent
                // A digest filename says nothing on the phone's picker, and
                // that picker is the whole point of a variant.
                let title = DesignStore.looksLikeADigest(stem)
                    ? "Variant \(design.variants.count + 1)"
                    : stem
                design.variants.append(ClipVariant(name: title, sourceVideoName: name))
            } catch {
                skinNote = "Could not add \(url.lastPathComponent): \(error)"
            }
        }
    }

    /// Takes the design's own clip out by promoting another into its place.
    ///
    /// Everything positional is shared already, so nothing on the canvas moves;
    /// only the loop has to be re-measured, because the successor is its own
    /// length.
    private func removePrimaryClip() {
        guard let store, let promotion = ClipPromotion.promoting(in: design) else { return }

        // The successor stops being a variant, so anything holding its id has
        // to let go before the list changes under it.
        if !promotion.design.variants.contains(where: { $0.id == previewedVariantID }) {
            previewedVariantID = nil
        }
        stopPlayback()

        design = promotion.design
        store.removeVariantClip(named: promotion.retiredFileName, for: design.id)

        // The loop was sized to the clip that just went. Left alone, a longer
        // successor would be cut short and a shorter one sampled past its end.
        Task {
            guard let summary = try? await MediaFrameExtractor(
                url: store.sourceVideoURL(for: design),
                screenSize: model.screenPixelSize
            ).summary() else {
                skinNote = "\(promotion.promotedName) took over, but could not be measured - check the loop length."
                return
            }
            design.sourceDuration = summary.duration
            design.retuneLoop()
            skinNote = "\(promotion.promotedName) is now this scene's own clip."
        }
    }

    /// Takes the clip with it, like removing an asset does: the file lives in
    /// the design, and a swapped-out variant should not keep growing it.

    private func removeVariant(_ variant: ClipVariant) {
        if previewedVariantID == variant.id { previewedVariantID = nil }
        // Otherwise the design leads with a clip that is no longer in it, and
        // the build quietly writes no default at all.
        if design.defaultVariantID == variant.id { design.defaultVariantID = nil }
        design.variants.removeAll { $0.id == variant.id }
        store?.removeVariantClip(named: variant.sourceVideoName, for: design.id)
    }

    // MARK: - Sidebar

    /// Which library the bottom of the sidebar shows. The inspector above it
    /// answers the selection; these never reorder or disappear.
    private enum LibraryTab: String, CaseIterable, Identifiable {
        case apps = "Apps"
        case looks = "Looks"
        case pictures = "Pictures"
        case clips = "Clips"

        var id: String { rawValue }
    }

    /// The sidebar is an inspector over a library. The inspector answers
    /// "what am I editing right now" - a tile, a picture, or the scene itself
    /// when nothing is selected - so the controls that matter are always at
    /// the top instead of below the fold of one long column.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            inspector

            Rectangle().fill(StudioTheme.headerEdge).frame(height: 1)

            // A trough with a raised chip on the selected tab, the way the
            // mockup draws it - a system segmented control reads as a form
            // field rather than a place to live.
            HStack(spacing: 2) {
                ForEach(LibraryTab.allCases) { tab in
                    Text(tab.rawValue)
                        .font(StudioTheme.body)
                        .foregroundStyle(libraryTab == tab ? StudioTheme.textBright : StudioTheme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(
                            libraryTab == tab ? StudioTheme.controlFill : .clear,
                            in: RoundedRectangle(cornerRadius: StudioTheme.radius, style: .continuous)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { libraryTab = tab }
                }
            }
            .padding(2)
            .background(StudioTheme.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            switch libraryTab {
            case .apps:
                catalogueSection
                placedTilesSection
            case .looks:
                skinSetsSection
            case .pictures:
                assetsSection
            case .clips:
                variantsSection
            }
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if selection.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                inspectorHeading("\(selection.count) tiles", detail: "aligning together")
                Text("Use the align buttons in the toolbar, or Make a row. Command-click a tile to add or remove it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let singleSelection, let index = design.tiles.firstIndex(where: { $0.id == singleSelection }) {
            selected(index: index)
        } else if let asset = selectedAsset {
            VStack(alignment: .leading, spacing: 10) {
                inspectorHeading("Picture", detail: asset.fileName)
                positionFields(
                    center: asset.center,
                    setCenter: { center in
                        guard let index = design.assets.firstIndex(where: { $0.id == asset.id })
                        else { return }
                        design.assets[index].center = center
                    }
                )
                assetInspector(asset)
            }
        } else {
            sceneInspector
        }
    }

    /// "Editing / Tile — opens Music": what is selected, and the one fact
    /// about it worth reading before anything else.
    func inspectorHeading(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            StudioTheme.eyebrow("Editing")
                .foregroundStyle(StudioTheme.accent)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StudioTheme.textBright)
                if let detail {
                    Text(detail)
                        .font(StudioTheme.body)
                        .foregroundStyle(StudioTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .background(StudioTheme.headerFill)
        .overlay(alignment: .bottom) {
            Rectangle().fill(StudioTheme.headerEdge).frame(height: 1)
        }
        // Bleeds to the panel's edges: it is a header strip, not a card.
        .padding(.horizontal, -15)
        .padding(.top, -12)
    }

    /// Typed position, because a drag cannot hit an exact pixel and reading
    /// one back is half of lining things up.
    private func positionFields(
        center: CGPoint,
        setCenter: @escaping (CGPoint) -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Text("X · Y").font(.caption).foregroundStyle(.secondary)
            TextField("x", value: Binding(
                get: { Int(center.x.rounded()) },
                set: { setCenter(CGPoint(x: CGFloat($0), y: center.y)) }
            ), format: .number)
                .frame(width: 54)
            TextField("y", value: Binding(
                get: { Int(center.y.rounded()) },
                set: { setCenter(CGPoint(x: center.x, y: CGFloat($0))) }
            ), format: .number)
                .frame(width: 54)
            Text("px").font(.caption2).foregroundStyle(.secondary)
            Spacer()
        }
        .textFieldStyle(StudioFieldStyle())
        .font(.system(size: 11, design: .monospaced))
    }

    /// Nothing selected means the scene itself is selected. It is never blank.
    private var sceneInspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            inspectorHeading("Scene", detail: "wallpaper, frame, clip")

            VStack(alignment: .leading, spacing: 4) {
                StudioTheme.eyebrow("Tile grid").foregroundStyle(StudioTheme.textTertiary)
                HStack(spacing: 6) {
                    Stepper(
                        "\(design.grid.columns) across",
                        value: Binding(
                            get: { design.grid.columns },
                            set: { design.grid.columns = max(1, min(8, $0)) }
                        ),
                        in: 1 ... 8
                    )
                    .controlSize(.small)
                }
                HStack(spacing: 6) {
                    Stepper(
                        "\(design.grid.rows) down",
                        value: Binding(
                            get: { design.grid.rows },
                            set: { design.grid.rows = max(1, min(8, $0)) }
                        ),
                        in: 1 ... 8
                    )
                    .controlSize(.small)
                }
                Text("\(design.tiles.compactMap(\.cell).count) of \(design.grid.cellCount) cells used. New tiles fill the next free one.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Clip size")
                    Spacer()
                    Text(String(format: "%.0f%%", design.mediaTransform.scale * 100))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { design.mediaTransform.scale },
                        set: { setScale($0) }
                    ),
                    in: 0.1 ... 4
                )
                Button("Fit to widget") {
                    design.mediaTransform = MediaTransform.fitting(
                        sourceSize: sourceSize,
                        inside: design.widgetRect,
                        screenSize: model.screenPixelSize
                    )
                }
                .buttonStyle(.link)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Background").font(.caption.weight(.semibold))
                    Spacer()
                    Button(design.backgroundName == nil ? "Choose..." : "Replace...") {
                        chooseBackground()
                    }
                    .buttonStyle(.link)
                }
                if design.backgroundName != nil {
                    Button("Use the clip instead") {
                        design.backgroundName = nil
                        reloadBackground()
                    }
                    .buttonStyle(.link)
                } else {
                    Toggle("Fill behind the clip", isOn: Binding(
                        get: { design.mediaTransform.fillsBackground },
                        set: { design.mediaTransform.fillsBackground = $0 }
                    ))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Corner radius")
                    Spacer()
                    Text("\(Int(design.effectiveCornerRadius))px")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { design.effectiveCornerRadius },
                        set: { design.widgetCornerRadius = $0 }
                    ),
                    in: 0 ... 160
                )
                Text("iOS does not publish the widget's corner radius. Match it here if the clip shows in the corners.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Snap to grid", isOn: $design.snapEnabled)

            Toggle("Icon labels", isOn: Binding(
                get: { design.tiles.allSatisfy(\.showsLabel) && !design.tiles.isEmpty },
                set: { on in
                    labelsDefault = on
                    for index in design.tiles.indices { design.tiles[index].showsLabel = on }
                }
            ))
            .disabled(design.tiles.isEmpty)

            let outside = design.tiles.filter { !SnapEngine.isFullyInside($0, frame: design.widgetRect) }
            if !outside.isEmpty {
                Text("""
                \(outside.count) app\(outside.count == 1 ? "" : "s") cross the widget edge. \
                Only the part inside answers a tap; the rest is baked into the wallpaper, \
                so save that to the phone as well.
                """)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("The dashed frame is the widget: only what falls inside it animates and answers a tap. Click anything on the canvas to edit it here.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let skinNote {
                Text(skinNote)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The catalogue lives in the sidebar rather than behind a button: adding
    /// apps is the editor's most common act, and a popover made it a hunt.
    private var catalogueSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            StudioTheme.eyebrow("Add an app").foregroundStyle(StudioTheme.textTertiary)
            CatalogueList(height: 200) { appID in
                add(appID: appID)
            }
        }
    }

    @ViewBuilder
    private var placedTilesSection: some View {
        if !design.tiles.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                StudioTheme.eyebrow("Placed").foregroundStyle(StudioTheme.textTertiary)
                ForEach(design.tiles) { tile in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(AppCatalog.app(id: tile.appID)?.tint ?? .gray)
                            .frame(width: 10, height: 10)
                        Text(AppCatalog.app(id: tile.appID)?.name ?? tile.appID)
                            .font(.caption)
                            .foregroundStyle(selection.contains(tile.id) ? Color.accentColor : .primary)
                        if !tile.alternates.isEmpty {
                            Text("+\(tile.alternates.count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { select(tile.id) }
                }
            }
        }
    }

    // MARK: - Alignment

    /// Where the align row puts a selected thing's edge, always against the
    /// widget frame: it is the region a launcher lives in, and the edge the
    /// eye lines things up against.
    private func alignRow(
        extent: CGSize,
        set: @escaping (CGPoint) -> Void,
        current: @escaping () -> CGPoint
    ) -> some View {
        let frame = design.widgetRect
        return VStack(alignment: .leading, spacing: 4) {
            Text("Align in widget").font(.caption.weight(.semibold))
            HStack(spacing: 4) {
                alignButton("align.horizontal.left", "Left edge") {
                    set(CGPoint(x: frame.minX + extent.width / 2, y: current().y))
                }
                alignButton("align.horizontal.center", "Centre") {
                    set(CGPoint(x: frame.midX, y: current().y))
                }
                alignButton("align.horizontal.right", "Right edge") {
                    set(CGPoint(x: frame.maxX - extent.width / 2, y: current().y))
                }
                Divider().frame(height: 14)
                alignButton("align.vertical.top", "Top edge") {
                    set(CGPoint(x: current().x, y: frame.minY + extent.height / 2))
                }
                alignButton("align.vertical.center", "Middle") {
                    set(CGPoint(x: current().x, y: frame.midY))
                }
                alignButton("align.vertical.bottom", "Bottom edge") {
                    set(CGPoint(x: current().x, y: frame.maxY - extent.height / 2))
                }
            }
        }
    }

    private func alignButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22, height: 18)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(help)
    }

    private func positionReadout(center: CGPoint) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("x \(Int(center.x))  y \(Int(center.y)) px")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text("Arrow keys nudge 1 px; hold Shift for 10.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Moves whatever is selected by whole pixels, clamped like a drag is.
    private func nudgeSelection(dx: CGFloat, dy: CGFloat) -> Bool {
        let engine = snapEngine
        if let singleSelection, let index = design.tiles.firstIndex(where: { $0.id == singleSelection }) {
            let moved = CGPoint(
                x: design.tiles[index].center.x + dx,
                y: design.tiles[index].center.y + dy
            )
            design.tiles[index].center = engine.clamp(
                center: moved,
                tileSize: design.tiles[index].boundingExtent
            )
            return true
        }
        if let singleSelection, let index = design.assets.firstIndex(where: { $0.id == singleSelection }) {
            let asset = design.assets[index]
            let moved = CGPoint(x: asset.center.x + dx, y: asset.center.y + dy)
            design.assets[index].center = engine.clamp(
                center: moved,
                tileSize: max(asset.size.width, asset.size.height)
            )
            return true
        }
        return false
    }

    private func selected(index: Int) -> some View {
        let tile = design.tiles[index]
        let app = AppCatalog.app(id: tile.appID)
        return VStack(alignment: .leading, spacing: 10) {
            inspectorHeading("Tile", detail: "opens \(tile.displayName)")

            // What the tile opens and what it looks like are separate choices:
            // the artwork comes from the Looks tab, and this is only the app a
            // tap reaches. A sheet's names are a starting point, not a binding.
            Picker("Opens", selection: Binding(
                get: { design.tiles[index].custom == nil ? design.tiles[index].appID : Self.customTag },
                set: { chosen in
                    guard chosen != Self.customTag else {
                        design.tiles[index].custom = CustomTarget(
                            name: design.tiles[index].displayName,
                            scheme: ""
                        )
                        return
                    }
                    design.tiles[index].custom = nil
                    design.tiles[index].appID = chosen
                    // A slot cannot offer a swap to the app it already shows.
                    design.tiles[index].alternates.removeAll { $0.appID == chosen }
                }
            )) {
                ForEach(AppCatalog.all) { entry in
                    Text(entry.name).tag(entry.id)
                }
                Divider()
                Text("Another app...").tag(Self.customTag)
            }
            .controlSize(.small)

            if design.tiles[index].custom != nil {
                customTargetFields(index: index)
            } else if app?.canLaunch == false {
                Text("\(app?.name ?? tile.appID) publishes no URL scheme, so a tap cannot open it. The tile still draws.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Caption", isOn: Binding(
                get: { design.tiles[index].showsLabel },
                set: { design.tiles[index].showsLabel = $0 }
            ))
            .controlSize(.small)

            Divider()

            StudioTheme.eyebrow("Position").foregroundStyle(StudioTheme.textTertiary)
            positionFields(center: tile.center) { center in
                guard design.tiles.indices.contains(index) else { return }
                design.tiles[index].center = center
                design.tiles[index].cell = nil
            }

            HStack(spacing: 6) {
                Text("Size").font(.caption).foregroundStyle(.secondary)
                TextField("size", value: Binding(
                    get: { Int(design.tiles[index].size.rounded()) },
                    set: { newSize in
                        design.tiles[index].size = max(40, CGFloat(newSize))
                        // Growing a tile can push it off the screen just as
                        // dragging can.
                        design.tiles[index].center = snapEngine.clamp(
                            center: design.tiles[index].center,
                            tileSize: design.tiles[index].boundingExtent
                        )
                    }
                ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 54)
                Text("px square").font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            .font(.caption.monospacedDigit())

            HStack(spacing: 6) {
                Text("Cell").font(.caption).foregroundStyle(.secondary)
                Text(tile.cell?.label ?? "off grid")
                    .font(.caption.monospaced())
                Spacer()
                Button("Snap to cell") { snapToCell(index: index) }
                    .buttonStyle(.studioCompact)
                    .disabled(design.grid.firstFreeCell(occupied: occupiedCells) == nil && tile.cell == nil)
            }

            LabeledContent("Angle") {
                Slider(
                    value: Binding(
                        get: { design.tiles[index].rotation },
                        set: { design.tiles[index].rotation = $0 }
                    ),
                    in: -45 ... 45
                )
            }
            .controlSize(.small)

            customIconRow(index: index)

            alternatesSection(index: index)

            HStack {
                Button("Duplicate") { duplicate(index: index) }
                    .controlSize(.small)
                Button("Remove tile", role: .destructive) {
                    design.tiles.removeAll { $0.id == tile.id }
                    selection = []
                }
                .controlSize(.small)
            }
        }
    }

    /// Sentinel for the "another app" row, which is not an app id.
    static let customTag = "\u{0000}custom"

    /// Name and URL for an app the catalogue does not carry.
    ///
    /// Anything on the phone can be opened this way: the widget hands the tap
    /// to the app and the app opens the URL, so the catalogue is a shortcut
    /// rather than the limit.
    @ViewBuilder
    private func customTargetFields(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name", text: Binding(
                get: { design.tiles[index].custom?.name ?? "" },
                set: { design.tiles[index].custom?.name = $0 }
            ))
            .textFieldStyle(StudioFieldStyle())

            TextField("scheme:// or https://", text: Binding(
                get: { design.tiles[index].custom?.scheme ?? "" },
                set: { design.tiles[index].custom?.scheme = $0 }
            ))
            .textFieldStyle(StudioFieldStyle())
            .font(.system(size: 11, design: .monospaced))

            if design.tiles[index].canLaunch {
                Text("Opens \(design.tiles[index].custom?.launchCandidates.first?.absoluteString ?? "")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(StudioTheme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Type the app's URL scheme - spotify, things, bear. Most apps have one; a web address works too.")
                    .font(.system(size: 10))
                    .foregroundStyle(StudioTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Puts a tile on the nearest free cell, or on the first free one when it
    /// is nowhere near a cell at all.
    private func snapToCell(index: Int) {
        guard design.tiles.indices.contains(index) else { return }
        let frame = design.widgetRect
        let tile = design.tiles[index]
        let taken = Set(design.tiles.filter { $0.id != tile.id }.compactMap(\.cell))

        let nearest = design.grid.nearestCell(to: tile.center, in: frame)
        let target = (nearest.map { !taken.contains($0) } ?? false)
            ? nearest
            : design.grid.firstFreeCell(occupied: taken)
        guard let target else {
            skinNote = "All \(design.grid.cellCount) cells are taken. Make the grid bigger in Scene, or remove a tile."
            return
        }
        design.tiles[index].center = design.grid.cellCenter(target, in: frame)
        design.tiles[index].cell = target
    }

    private func duplicate(index: Int) {
        guard design.tiles.indices.contains(index) else { return }
        var copy = design.tiles[index]
        copy.id = UUID()
        copy.cell = nil
        // Offset by a quarter tile so the copy is visibly its own thing rather
        // than hidden exactly behind the original.
        let step = copy.size * 0.25
        copy.center = snapEngine.clamp(
            center: CGPoint(x: copy.center.x + step, y: copy.center.y + step),
            tileSize: copy.boundingExtent
        )
        design.tiles.append(copy)
        selection = [copy.id]
    }

    /// The rest of the slot's list: apps the phone may swap in for this one.
    ///
    /// The choice itself happens on the phone - tiles are live SwiftUI over
    /// the frozen animation, so the occupant is the one part of a design that
    /// can change after install. What is authored here is only what is on
    /// offer, because an alternate's artwork has to be baked into the bundle.
    @ViewBuilder
    private func alternatesSection(index: Int) -> some View {
        let tile = design.tiles[index]
        Divider()
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                StudioTheme.eyebrow("Phone can swap to").foregroundStyle(StudioTheme.textTertiary)
                Spacer()
                Button("Add...") { addingAlternate = true }
                    .buttonStyle(.link)
                    .popover(isPresented: $addingAlternate) {
                        CataloguePicker { appID in
                            addAlternate(appID, at: index)
                            addingAlternate = false
                        }
                    }
            }

            if tile.alternates.isEmpty {
                Text("On the phone, a slot can be reassigned to any app listed here, or hidden. Without a list it only offers its own app.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(tile.offeredAlternates) { alternate in
                HStack(spacing: 6) {
                    Circle()
                        .fill(AppCatalog.app(id: alternate.appID)?.tint ?? .gray)
                        .frame(width: 10, height: 10)
                    Text(AppCatalog.app(id: alternate.appID)?.name ?? alternate.appID)
                        .font(.caption)
                    if let skin = alternate.skin {
                        Image(systemName: "photo")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Ships with the skin \(skin)")
                    }
                    Spacer()
                    Button {
                        design.tiles[index].alternates.removeAll { $0.appID == alternate.appID }
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Stop offering \(AppCatalog.app(id: alternate.appID)?.name ?? alternate.appID)")
                }
                .contextMenu {
                    Menu("Skin") {
                        Button("None - catalogue plate") {
                            setAlternateSkin(nil, appID: alternate.appID, at: index)
                        }
                        ForEach(skins) { skin in
                            Button(skin.id) {
                                setAlternateSkin(skin.id, appID: alternate.appID, at: index)
                            }
                        }
                    }
                }
            }

            if !tile.alternates.isEmpty, !SnapEngine.isFullyInside(tile, frame: design.widgetRect) {
                Text("This slot crosses the widget edge, so the part outside keeps its built look whatever the phone picks.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func addAlternate(_ appID: String, at index: Int) {
        let tile = design.tiles[index]
        // The same app twice in one slot would make the phone's stored choice
        // ambiguous, so it is refused rather than resolved later.
        guard appID != tile.appID, !tile.alternates.contains(where: { $0.appID == appID }) else { return }
        design.tiles[index].alternates.append(TileAlternate(appID: appID))
    }

    private func setAlternateSkin(_ skin: String?, appID: String, at index: Int) {
        guard let position = design.tiles[index].alternates.firstIndex(where: { $0.appID == appID })
        else { return }
        design.tiles[index].alternates[position].skin = skin
    }

    private func add(appID: String) {
        // On a free spot inside the widget frame - outside it a tile is only a
        // picture on the wallpaper - and never on top of a tile already
        // placed, which is what made adding four apps start with un-stacking.
        let size: CGFloat = 180
        let center = SnapEngine(
            screenSize: model.screenPixelSize,
            widgetRect: design.widgetRect
        ).freePlacement(size: size, avoiding: design.tiles)
        var tile = PlacedTile(appID: appID, center: center, size: size)
        tile.showsLabel = labelsDefault
        design.tiles.append(tile)
        selection = [tile.id]
    }
}

/// The popover shape of the catalogue, for flows that collect one app - a
/// slot's alternates. The sidebar embeds `CatalogueList` directly instead.
private struct CataloguePicker: View {
    let onPick: (String) -> Void

    var body: some View {
        CatalogueList(onPick: onPick)
            .padding(12)
            .frame(width: 240)
    }
}

/// The catalogue as the mockup draws it: a grid of plates, four across, each
/// with the app's tint and its name under it. A list of names reads as a form;
/// this reads as the thing being placed.
private struct CatalogueList: View {
    var height: CGFloat = 240
    let onPick: (String) -> Void

    @State private var query = ""

    private var matches: [CatalogApp] {
        let all = AppCatalog.all
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search apps", text: $query)
                .textFieldStyle(StudioFieldStyle())

            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(matches) { app in
                        Button { onPick(app.id) } label: {
                            VStack(spacing: 4) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(StudioTheme.controlFill)
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(app.tint.opacity(0.35))
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(StudioTheme.controlEdge, lineWidth: 1)
                                    Image(systemName: app.symbol)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(StudioTheme.text)
                                    // Some Apple apps publish no URL scheme, so
                                    // a tile for one can never open anything.
                                    // Better said here than found by tapping it.
                                    if !app.canLaunch {
                                        Image(systemName: "hand.raised.slash")
                                            .font(.system(size: 8))
                                            .foregroundStyle(StudioTheme.textDim)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                                            .padding(3)
                                    }
                                }
                                .frame(height: 36)
                                Text(app.name)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(StudioTheme.textTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(app.canLaunch
                            ? "Add \(app.name)"
                            : "\(app.name) cannot be opened from a widget: it publishes no URL scheme.")
                    }
                }
                if matches.isEmpty {
                    Text("Nothing named \"\(query)\". Try another name.")
                        .font(StudioTheme.small)
                        .foregroundStyle(StudioTheme.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
            }
            .frame(height: height)

            Text("Click an app to add it. New tiles fill the next free cell.")
                .font(.system(size: 10))
                .foregroundStyle(StudioTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}


/// A skin thumbnail, decoded once per appearance.
private struct AsyncSkinThumbnail: View {
    let url: URL?

    @State private var image: Image?

    var body: some View {
        Group {
            if let image {
                image.resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                Color.gray.opacity(0.2)
            }
        }
        .task(id: url) {
            image = url
                .flatMap { ImageLoader.load(at: $0, maxPixelSize: 132) }
                .map { Image(decorative: $0, scale: 1) }
        }
    }
}



/// Steps through a decoded loop on the canvas.
///
/// Driven by the clock rather than by a timer that counts frames: the picture
/// is a function of the time, which is how the widget's own animation works,
/// so a slow redraw drops a frame instead of falling behind.
private struct PlayingClip: View {
    let frames: [CGImage]
    let framesPerSecond: Int

    var body: some View {
        let rate = Double(max(framesPerSecond, 1))
        TimelineView(.periodic(from: .now, by: 1 / rate)) { context in
            let step = Int(context.date.timeIntervalSince1970 * rate)
            Image(decorative: frames[((step % frames.count) + frames.count) % frames.count], scale: 1)
                .resizable()
        }
    }
}
