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
    @State private var showingPreview = false
    @State private var showingIconPicker = false
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
            .task { loadWallpaperPreview() }
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

                if let wallpaper {
                    wallpaper.resizable().interpolation(.high)
                } else {
                    // Before the first build there is no composed still yet.
                    Color(white: 0.12)
                        .overlay(Text("Build to see the video").font(.caption).foregroundStyle(.secondary))
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
                        .gesture(dragGesture(for: tile, scale: scale))
                        .onTapGesture { selectedTileID = tile.id }
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

    private func update(tile: PlacedTile, to location: CGPoint, scale: CGFloat, commit: Bool) {
        guard let index = design.tiles.firstIndex(where: { $0.id == tile.id }) else { return }
        let engine = SnapEngine(widgetRect: design.widgetRect)
        // The gesture reports canvas points; the model stores screen pixels.
        let raw = CGPoint(x: location.x / scale, y: location.y / scale)
        let clamped = engine.clamp(center: raw, tileSize: tile.size)

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
                Picker("Size", selection: $design.widgetSize) {
                    ForEach(WidgetSizeOption.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
                .onChange(of: design.widgetSize) { _, _ in
                    design.widgetSlot = .topLeft
                    library.save(design)
                }

                if design.widgetSize == .fullScreen, !WidgetFamilyCompatibility.supportsFullScreen {
                    Label(
                        "This device does not offer the tall portrait widget. It needs iOS 27.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                SlotPicker(size: design.widgetSize, slot: $design.widgetSlot)

                DisclosureGroup("Fine alignment") {
                    NudgeSlider(label: "Horizontal", value: $design.widgetNudge.x)
                    NudgeSlider(label: "Vertical", value: $design.widgetNudge.y)
                    Text("Only the full-screen slot is measured. Nudge the others until the widget lines up with the wallpaper on your phone.")
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
                Stepper(value: $design.loopFrameCount, in: 1 ... 240) {
                    LabeledContent("Loop length", value: "\(design.loopFrameCount) frames")
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

            Section("Quality") {
                VStack(alignment: .leading) {
                    Slider(value: $design.jpegQuality, in: 0.3 ... 0.9)
                    Text("JPEG quality \(Int(design.jpegQuality * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Animated area", value: sizeCaption)
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

private struct SlotPicker: View {
    let size: WidgetSizeOption
    @Binding var slot: WidgetSlot

    var body: some View {
        let grid = size.slotGrid
        VStack(alignment: .leading, spacing: 6) {
            Text("Placement").font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 4) {
                ForEach(0 ..< grid.rows, id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(0 ..< grid.columns, id: \.self) { column in
                            let candidate = WidgetSlot(column: column, row: row)
                            Button {
                                slot = candidate
                            } label: {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(slot == candidate ? Color.accentColor : Color.secondary.opacity(0.25))
                                    .frame(height: 22)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxWidth: 160)
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
