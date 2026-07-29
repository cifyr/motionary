import SwiftUI
import os

struct EditorView: View {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "Editor")

    @EnvironmentObject private var library: DesignLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var design: DesignDocument
    @State private var selectedTileID: UUID?
    @State private var activeGuides: [SnapGuide] = []
    @State private var showingTilePalette = false
    @State private var buildStage: FontSetGenerator.Stage?
    @State private var buildFailure: String?
    @State private var exportMessage: String?
    @State private var wallpaper: Image?
    /// A raw frame from the source, so placement can be previewed live rather
    /// than only after a rebuild.
    @State private var sourceFrame: CGImage?
    @State private var placementBase = MediaTransform.identity
    @State private var showingPreview = false
    @State private var showingIconPicker = false
    /// Rotation at the start of a rotate gesture, since the gesture reports a
    /// delta from where the fingers began rather than an absolute angle.
    @State private var rotationBase: Double = 0
    /// Size at the start of a pinch, for the same reason.
    @State private var sizeBase: CGFloat = 160
    @StateObject private var icons: IconImageLoader

    init(design: DesignDocument) {
        _design = State(initialValue: design)
        _icons = StateObject(wrappedValue: IconImageLoader(store: try? DesignStore()))
    }

    private var selectedTile: PlacedTile? {
        design.tiles.first { $0.id == selectedTileID }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                canvas
                Divider()
                controls
            }
            .navigationTitle(design.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        library.save(design)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingTilePalette = true
                    } label: {
                        Label("Add app", systemImage: "apps.iphone")
                    }
                }
            }
            .sheet(isPresented: $showingTilePalette) {
                TilePaletteView { app in
                    addTile(for: app)
                }
            }
            .sheet(isPresented: $showingIconPicker) {
                if let store = library.store, let cache = try? IconCache(store: store), let tile = selectedTile {
                    IconPickerView(
                        cache: cache,
                        suggestion: AppCatalog.app(id: tile.appID)?.name ?? tile.appID
                    ) { icon in
                        applyIcon(icon, to: tile.id)
                    }
                }
            }
            .sheet(isPresented: $showingPreview) {
                if let store = library.store {
                    WidgetPreviewView(design: design, store: store)
                }
            }
            .overlay {
                if let buildStage {
                    ProgressOverlay(caption: buildStage.caption, fraction: buildStage.fraction)
                }
            }
            .alert("Build failed", isPresented: Binding(
                get: { buildFailure != nil },
                set: { if !$0 { buildFailure = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(buildFailure ?? "")
            }
            .alert("Export", isPresented: Binding(
                get: { exportMessage != nil },
                set: { if !$0 { exportMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportMessage ?? "")
            }
            .task {
                loadWallpaperPreview()
                placementBase = design.mediaTransform
                await loadSourceFrame()
            }
        }
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geometry in
            let screen = DeviceGeometry.screenPixelSize
            let scale = min(geometry.size.width / screen.width, geometry.size.height / screen.height)
            let canvasSize = CGSize(width: screen.width * scale, height: screen.height * scale)

            ZStack {
                Color.black

                if let sourceFrame {
                    SourcePlacementLayer(
                        sourceImage: sourceFrame,
                        transform: design.mediaTransform,
                        screenSize: screen,
                        canvasScale: scale
                    )
                    .contentShape(Rectangle())
                    .gesture(placementDrag(scale: scale).simultaneously(with: placementMagnify()))
                } else if let wallpaper {
                    wallpaper.resizable().interpolation(.high)
                } else {
                    Color(white: 0.12)
                        .overlay(Text("Loading source").font(.caption).foregroundStyle(.secondary))
                }

                CropOutline(rect: design.effectiveCrop, screen: screen, color: .yellow, label: "Animated")
                CropOutline(rect: design.widgetRect, screen: screen, color: .cyan, label: design.widgetSize.title)

                ForEach(design.tiles) { tile in
                    TileView(
                        tile: tile,
                        side: tile.size * scale,
                        isSelected: tile.id == selectedTileID,
                        iconImage: icons.image(for: tile)
                    )
                        .position(
                            x: tile.center.x * scale,
                            y: tile.center.y * scale
                        )
                        .gesture(dragGesture(for: tile, scale: scale)
                            .simultaneously(with: rotateGesture(for: tile))
                            .simultaneously(with: magnifyGesture(for: tile)))
                        .onTapGesture {
                            selectedTileID = tile.id
                            rotationBase = tile.rotation
                            sizeBase = tile.size
                        }
                }

                ForEach(activeGuides) { guide in
                    GuideLine(guide: guide, screen: screen)
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .clipped()
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.06))
    }

    /// Drag anywhere off a tile to move the source. Tile gestures sit on top,
    /// so they take precedence and this only fires on the background.
    private func placementDrag(scale: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                design.mediaTransform.offset = CGPoint(
                    x: placementBase.offset.x + value.translation.width / scale,
                    y: placementBase.offset.y + value.translation.height / scale
                )
            }
            .onEnded { _ in
                placementBase = design.mediaTransform
                library.save(design)
            }
    }

    private func placementMagnify() -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                applyPinch(value)
            }
            .onEnded { value in
                applyPinch(value)
                placementBase = design.mediaTransform
                library.save(design)
            }
    }

    /// Always derived from the transform at gesture start, so a long pinch does
    /// not accumulate rounding from its own intermediate results.
    /// Changing speed resizes the loop to keep a whole pass through the source,
    /// otherwise speeding up would just repeat part of it.
    private func applySpeed(_ speed: Double) {
        design.playbackSpeed = speed
        if design.sourceDuration > 0 {
            design.loopFrameCount = design.spec.seamlessLoopLength(
                nearest: design.naturalLoopFrames,
                maximum: 96
            )
        }
        library.save(design)
    }

    private func applyPinch(_ value: MagnifyGesture.Value) {
        guard let sourceFrame else { return }
        // Clamped so a stray pinch cannot shrink the source to nothing or blow
        // it up past anything useful.
        let scale = min(max(placementBase.scale * value.magnification, 0.2), 4)
        let screen = DeviceGeometry.screenPixelSize
        // startAnchor is a unit point over the canvas, which represents the
        // whole screen, so it converts straight to screen pixels.
        let anchor = CGPoint(
            x: value.startAnchor.x * screen.width,
            y: value.startAnchor.y * screen.height
        )
        design.mediaTransform = MediaFrameExtractor.transform(
            placementBase,
            scaledTo: scale,
            anchoredAt: anchor,
            sourceSize: CGSize(width: sourceFrame.width, height: sourceFrame.height),
            screenSize: screen
        )
    }

    private func dragGesture(for tile: PlacedTile, scale: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                selectedTileID = tile.id
                update(tile: tile, to: value.location, scale: scale, commit: false)
            }
            .onEnded { value in
                update(tile: tile, to: value.location, scale: scale, commit: true)
                activeGuides = []
            }
    }

    private func magnifyGesture(for tile: PlacedTile) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                selectedTileID = tile.id
                apply(size: sizeBase * value.magnification, to: tile.id, commit: false)
            }
            .onEnded { value in
                apply(size: sizeBase * value.magnification, to: tile.id, commit: true)
                sizeBase = design.tiles.first { $0.id == tile.id }?.size ?? sizeBase
            }
    }

    private func rotateGesture(for tile: PlacedTile) -> some Gesture {
        RotateGesture()
            .onChanged { value in
                selectedTileID = tile.id
                apply(rotation: rotationBase + value.rotation.degrees, to: tile.id, commit: false)
            }
            .onEnded { value in
                apply(rotation: rotationBase + value.rotation.degrees, to: tile.id, commit: true)
                rotationBase = design.tiles.first { $0.id == tile.id }?.rotation ?? 0
            }
    }

    private func apply(size: CGFloat, to tileID: UUID, commit: Bool) {
        guard let index = design.tiles.firstIndex(where: { $0.id == tileID }) else { return }
        design.tiles[index].size = max(20, size)
        let engine = SnapEngine(widgetRect: design.widgetRect)
        // Growing a tile can push it past an edge, so re-clamp after resizing.
        design.tiles[index].center = engine.clamp(
            center: design.tiles[index].center,
            tileSize: design.tiles[index].boundingExtent
        )
        if commit { library.save(design) }
    }

    private func apply(rotation: Double, to tileID: UUID, commit: Bool) {
        guard let index = design.tiles.firstIndex(where: { $0.id == tileID }) else { return }
        let engine = SnapEngine(widgetRect: design.widgetRect)
        design.tiles[index].rotation = design.snapEnabled
            ? engine.snap(rotation: rotation)
            : SnapEngine.wrap(rotation)
        // Rotating grows the footprint, so a tile near an edge has to move back
        // inside rather than letting a corner hang off.
        design.tiles[index].center = engine.clamp(
            center: design.tiles[index].center,
            tileSize: design.tiles[index].boundingExtent
        )
        if commit { library.save(design) }
    }

    private func update(tile: PlacedTile, to location: CGPoint, scale: CGFloat, commit: Bool) {
        guard let index = design.tiles.firstIndex(where: { $0.id == tile.id }) else { return }
        let engine = SnapEngine(widgetRect: design.widgetRect)
        // The gesture reports canvas points; the model stores screen pixels.
        let raw = CGPoint(x: location.x / scale, y: location.y / scale)
        let clamped = engine.clamp(center: raw, tileSize: tile.boundingExtent)

        if design.snapEnabled {
            let result = engine.snap(
                center: clamped,
                tileSize: tile.size,
                siblings: design.tiles.filter { $0.id != tile.id }
            )
            design.tiles[index].center = result.center
            activeGuides = result.guides
        } else {
            design.tiles[index].center = clamped
            activeGuides = []
        }

        if commit { library.save(design) }
    }

    private func applyIcon(_ icon: IconAsset?, to tileID: UUID) {
        guard let index = design.tiles.firstIndex(where: { $0.id == tileID }) else { return }
        if let existing = design.tiles[index].icon { icons.forget(existing) }
        design.tiles[index].icon = icon
        library.save(design)
        Self.logger.info("tile \(tileID.uuidString, privacy: .public) icon set to \(icon?.id ?? "none", privacy: .public)")
    }

    private func addTile(for app: CatalogApp) {
        let widget = design.widgetRect
        let side = min(widget.width, widget.height) * 0.22
        let tile = PlacedTile(
            appID: app.id,
            center: CGPoint(x: widget.midX, y: widget.midY),
            size: side
        )
        design.tiles.append(tile)
        selectedTileID = tile.id
        library.save(design)
        Self.logger.info("added tile \(app.id, privacy: .public) to \(self.design.id.uuidString, privacy: .public)")
    }

    // MARK: - Controls

    private var controls: some View {
        Form {
            Section("Widget") {
                LabeledContent("Size", value: "Full screen")
                LabeledContent(
                    "Frame",
                    value: "\(Int(DeviceGeometry.pixelSize.width))x\(Int(DeviceGeometry.pixelSize.height)) px"
                )

                if !WidgetFamilyCompatibility.supportsFullScreen {
                    Label(
                        "This device does not offer the tall portrait widget. It needs iOS 27.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                DisclosureGroup("Fine alignment") {
                    NudgeSlider(label: "Horizontal", value: $design.widgetNudge.x)
                    NudgeSlider(label: "Vertical", value: $design.widgetNudge.y)
                    Text("The frame is calibrated for an iPhone 17 Pro. Nudge it only if the widget sits slightly off the wallpaper on your phone.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let tile = selectedTile {
                Section("Selected tile") {
                    LabeledContent("App", value: AppCatalog.app(id: tile.appID)?.name ?? tile.appID)
                    Button {
                        showingIconPicker = true
                    } label: {
                        Label(tile.icon == nil ? "Choose icon" : "Change icon", systemImage: "square.grid.2x2")
                    }
                    if let icon = tile.icon {
                        HStack {
                            Text(icon.id).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Button("Remove") { applyIcon(nil, to: tile.id) }
                                .font(.caption)
                        }
                    }
                    ColorPicker("Plate colour", selection: Binding(
                        get: { tile.tintHex.flatMap(Color.init(hex:)) ?? AppCatalog.app(id: tile.appID)?.tint ?? .gray },
                        set: { newValue in
                            guard let index = design.tiles.firstIndex(where: { $0.id == tile.id }) else { return }
                            design.tiles[index].tintHex = newValue.hexString
                            library.save(design)
                        }
                    ))
                    VStack(alignment: .leading, spacing: 2) {
                        Slider(
                            value: Binding(
                                get: { tile.size },
                                set: { apply(size: $0, to: tile.id, commit: true) }
                            ),
                            in: 60 ... 480,
                            step: 2
                        )
                        Text("Size \(Int(tile.size.rounded())) px")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Slider(
                            value: Binding(
                                get: { tile.rotation },
                                set: { apply(rotation: $0, to: tile.id, commit: true) }
                            ),
                            in: -180 ... 180,
                            step: 1
                        )
                        HStack {
                            Text("Rotation \(Int(tile.rotation.rounded()))°")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Reset") { apply(rotation: 0, to: tile.id, commit: true) }
                                .font(.caption2)
                                .disabled(tile.rotation == 0)
                        }
                    }
                    Toggle("Show label", isOn: Binding(
                        get: { tile.showsLabel },
                        set: { newValue in
                            guard let index = design.tiles.firstIndex(where: { $0.id == tile.id }) else { return }
                            design.tiles[index].showsLabel = newValue
                            library.save(design)
                        }
                    ))
                    Button("Remove tile", role: .destructive) {
                        design.tiles.removeAll { $0.id == tile.id }
                        selectedTileID = nil
                        library.save(design)
                    }
                }
            }

            Section("Motion") {
                Picker("Smoothness", selection: $design.smoothness) {
                    ForEach(MotionSmoothness.allCases) { option in
                        VStack(alignment: .leading) {
                            Text(option.title)
                            Text(option.subtitle).font(.caption2)
                        }
                        .tag(option)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Slider(
                        value: Binding(
                            get: { design.playbackSpeed },
                            set: { applySpeed($0) }
                        ),
                        in: 0.25 ... 4,
                        step: 0.05
                    )
                    HStack {
                        Text("Speed \(String(format: "%.2f", design.playbackSpeed))x")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset") { applySpeed(1) }
                            .font(.caption2)
                            .disabled(design.playbackSpeed == 1)
                    }
                }
                Stepper(value: $design.loopFrameCount, in: 1 ... 240) {
                    LabeledContent(
                    "Loop length",
                    value: "\(design.loopFrameCount) frames · \(String(format: "%.2f", design.loopDuration))s"
                )
                }
                Stepper(value: $design.loopStartFrame, in: 0 ... 600) {
                    LabeledContent("Start at", value: "frame \(design.loopStartFrame)")
                }
                if let seamless = nearestSeamlessLength, seamless != design.loopFrameCount {
                    Button("Snap loop to \(seamless) frames") {
                        design.loopFrameCount = seamless
                        library.save(design)
                    }
                    .font(.caption)
                }
                if !design.spec.divides(loopFrameCount: design.loopFrameCount) {
                    Label(
                        "\(design.loopFrameCount) does not divide \(design.spec.totalFrames); the loop will cut at the 30-second wrap.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }
                Toggle("Snap to guides", isOn: $design.snapEnabled)
            }

            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Slider(value: Binding(
                        get: { design.mediaTransform.scale },
                        set: { design.mediaTransform.scale = $0; library.save(design) }
                    ), in: 0.2 ... 3, step: 0.01)
                    Text("Scale \(String(format: "%.2f", design.mediaTransform.scale))x")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                LabeledContent(
                    "Position",
                    value: "\(Int(design.mediaTransform.offset.x)), \(Int(design.mediaTransform.offset.y)) px"
                )
                .font(.caption2)
                Toggle("Fill gaps with the source", isOn: Binding(
                    get: { design.mediaTransform.fillsBackground },
                    set: { design.mediaTransform.fillsBackground = $0; library.save(design) }
                ))
                if !design.mediaTransform.isIdentity {
                    Button("Reset placement") {
                        design.mediaTransform = .identity
                        placementBase = .identity
                        library.save(design)
                    }
                    .font(.caption)
                }
            } header: {
                Text("Source placement")
            } footer: {
                Text("Drag and pinch the canvas to fit the source. A clip shot in portrait already fills the screen; a square GIF does not. Rebuild to apply.")
            }

            Section("Quality") {
                VStack(alignment: .leading) {
                    Slider(value: $design.jpegQuality, in: 0.3 ... 0.9)
                    Text("JPEG quality \(Int(design.jpegQuality * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Animated area", value: sizeCaption)
                if !design.hasAnimatedArea {
                    // Recoverable in place. Without this the design could only
                    // report "no animated area" at the end of every build, with
                    // no way to put it right.
                    Label(
                        "The animated area falls outside the widget frame, so there is nothing to build.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    Button("Reset animated area") {
                        design.animationCrop = design.widgetRect
                        library.save(design)
                    }
                    .font(.caption)
                }
                if let estimate {
                    LabeledContent("Estimated payload", value: estimate.formattedEstimate)
                        .foregroundStyle(estimate.isWithinRecommended ? Color.primary : Color.orange)
                    if !estimate.isWithinRecommended {
                        Text("Above the size a widget extension comfortably holds. Lower quality, shrink the animated area, or drop Smoothness.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section {
                Button {
                    Task { await build() }
                } label: {
                    Label("Build widget", systemImage: "hammer.fill")
                }
                .disabled(buildStage != nil)

                Button {
                    showingPreview = true
                } label: {
                    Label("Preview widget", systemImage: "eye")
                }
                .disabled(library.manifest(for: design) == nil)

                Button {
                    Task { await exportWallpaper() }
                } label: {
                    Label("Save wallpaper to Photos", systemImage: "square.and.arrow.down")
                }
                .disabled(library.manifest(for: design) == nil)
            } footer: {
                Text("Set the exported image as your Home Screen wallpaper with no blur and no zoom, then add the \(design.widgetSize.title) Motionary widget in the matching slot. The widget shows whichever design is selected in Designs.")
            }
        }
        .frame(maxHeight: 340)
    }

    /// Closest loop length that still tiles the 30-second timer cycle, so the
    /// wrap does not introduce a second visible cut.
    private var nearestSeamlessLength: Int? {
        design.spec
            .seamlessLoopLengths(maximum: 240)
            .min { abs($0 - design.loopFrameCount) < abs($1 - design.loopFrameCount) }
    }

    /// Estimated from the real crop at the real quality, so the number shown
    /// is the one a build would produce rather than a guess.
    private var estimate: PayloadBudget? {
        guard let sourceFrame else { return nil }
        let crop = design.effectiveCrop
        guard crop.width >= 2, crop.height >= 2 else { return nil }

        // The source frame is raw; the crop is in composed screen space, so
        // scale a sample of equivalent area rather than cropping the wrong box.
        let composedArea = crop.width * crop.height
        let sourceArea = CGFloat(sourceFrame.width * sourceFrame.height)
        guard sourceArea > 0 else { return nil }
        let sampleSide = (min(composedArea, sourceArea)).squareRoot()
        let sampleRect = CGRect(
            x: 0, y: 0,
            width: min(CGFloat(sourceFrame.width), sampleSide),
            height: min(CGFloat(sourceFrame.height), sampleSide)
        ).integral
        guard let sample = sourceFrame.cropping(to: sampleRect),
              let data = FrameEncoder.jpegData(sample, quality: design.jpegQuality)
        else { return nil }

        let perPixel = Double(data.count) / Double(max(1, sampleRect.width * sampleRect.height))
        let bytes = Int(perPixel * Double(composedArea))
        return PayloadBudget(spec: design.spec, averageEncodedFrameBytes: bytes)
    }

    private var sizeCaption: String {
        let crop = design.effectiveCrop
        return "\(Int(crop.width))x\(Int(crop.height)) px"
    }

    // MARK: - Actions

    private func build() async {
        guard let store = library.store else { return }
        library.save(design)
        do {
            let generator = FontSetGenerator(store: store)
            let manifest = try await generator.build(design: design) { stage in
                Task { @MainActor in buildStage = stage }
            }
            design.buildGeneration = manifest.buildGeneration
            library.save(design)
            loadWallpaperPreview()
            WidgetCenterBridge.reloadAll()
            Self.logger.info("built \(self.design.id.uuidString, privacy: .public), \(manifest.totalFontBytes) bytes")
        } catch {
            buildFailure = String(describing: error)
            Self.logger.error("build failed: \(String(describing: error), privacy: .public)")
        }
        buildStage = nil
    }

    private func exportWallpaper() async {
        guard let store = library.store else { return }
        do {
            try await WallpaperExporter.saveToPhotos(url: store.wallpaperURL(for: design.id))
            exportMessage = "Saved to Photos. Set it as your Home Screen wallpaper with blur and zoom off."
        } catch {
            exportMessage = String(describing: error)
        }
    }

    private func loadSourceFrame() async {
        guard let store = library.store else { return }
        let url = store.sourceVideoURL(for: design)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            sourceFrame = try await MediaFrameExtractor(url: url)
                .posterFrame(
                    at: design.loopStartFrame,
                    frameRate: design.spec.framesPerSecond,
                    speed: design.playbackSpeed
                )
        } catch {
            Self.logger.error("could not load a source frame: \(String(describing: error), privacy: .public)")
        }
    }

    private func loadWallpaperPreview() {
        guard let store = library.store else { return }
        let url = store.wallpaperURL(for: design.id)
        guard let image = UIImage(contentsOfFile: url.path) else {
            wallpaper = nil
            return
        }
        wallpaper = Image(uiImage: image)
    }
}

// MARK: - Canvas pieces

private struct CropOutline: View {
    let rect: CGRect
    let screen: CGSize
    let color: Color
    let label: String

    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / screen.width
            let frame = CGRect(
                x: rect.minX * scale, y: rect.minY * scale,
                width: rect.width * scale, height: rect.height * scale
            )
            Rectangle()
                .strokeBorder(color.opacity(0.85), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .frame(width: frame.width, height: frame.height)
                .overlay(alignment: .topLeading) {
                    Text(label)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 3)
                        .background(.black.opacity(0.6))
                        .offset(y: -10)
                }
                .position(x: frame.midX, y: frame.midY)
        }
        .allowsHitTesting(false)
    }
}

private struct GuideLine: View {
    let guide: SnapGuide
    let screen: CGSize

    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / screen.width
            let position = guide.position * scale
            Rectangle()
                .fill(color)
                .frame(
                    width: guide.axis == .vertical ? 1 : geometry.size.width,
                    height: guide.axis == .vertical ? geometry.size.height : 1
                )
                .position(
                    x: guide.axis == .vertical ? position : geometry.size.width / 2,
                    y: guide.axis == .vertical ? geometry.size.height / 2 : position
                )
        }
        .allowsHitTesting(false)
    }

    private var color: Color {
        switch guide.kind {
        case .screenCenter, .screenEdge: .pink
        case .widgetFrame: .cyan
        case .iconGrid: .green
        case .sibling: .orange
        }
    }
}

private struct NudgeSlider: View {
    let label: String
    @Binding var value: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Slider(value: $value, in: -60 ... 60, step: 1)
            Text("\(label) \(Int(value)) px").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
