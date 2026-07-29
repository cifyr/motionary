import CoreGraphics
import SwiftUI

/// Positions the clip and places app tiles on it, before anything is built.
///
/// It has to happen here rather than on the phone: the crop and the placement
/// are baked into the glyph images when the fonts are generated, so nothing
/// downstream can move them. The canvas is the phone's screen in points, with
/// the widget's frame drawn on it, because that frame is the only part that
/// ends up animated - anything outside it is wallpaper.
struct LayoutEditor: View {
    @Binding var design: DesignDocument
    let model: DeviceModel
    let poster: CGImage?

    @State private var selection: UUID?
    @State private var placementBase: MediaTransform?
    @State private var scaleBase: Double?
    @State private var tileBase: CGPoint?
    @State private var showingCatalogue = false

    /// Points per screen pixel, so the canvas is the phone at a readable size.
    private static let zoom: CGFloat = 0.62

    private var canvas: CGSize {
        CGSize(
            width: model.screenPointSize.width * Self.zoom,
            height: model.screenPointSize.height * Self.zoom
        )
    }

    /// Canvas points per screen pixel. Every gesture converts through this, so
    /// a drag moves the same distance on the phone as under the cursor.
    private var unit: CGFloat { canvas.width / model.screenPixelSize.width }

    /// The clip's own pixel size, taken from the frame rather than stored: the
    /// poster is a frame of the source, so it is the source's size by
    /// definition and cannot drift from it.
    private var sourceSize: CGSize {
        guard let poster else { return model.screenPixelSize }
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

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            screen
            sidebar.frame(width: 220)
        }
        .padding(20)
    }

    private var screen: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if let poster {
                let rect = placement
                Image(decorative: poster, scale: 1)
                    .resizable()
                    .frame(width: rect.width * unit, height: rect.height * unit)
                    .offset(x: rect.minX * unit, y: rect.minY * unit)
            }
            widgetFrame
            ForEach(design.tiles) { tile in
                tileView(tile)
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipShape(RoundedRectangle(cornerRadius: 34 * Self.zoom, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 34 * Self.zoom, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
        .gesture(clipDrag)
        .simultaneousGesture(clipZoom)
        .onTapGesture { selection = nil }
    }

    /// The animated region, drawn so the clip can be positioned against it
    /// rather than against the whole screen.
    private var widgetFrame: some View {
        let rect = design.widgetRect
        return RoundedRectangle(cornerRadius: 24 * Self.zoom, style: .continuous)
            .strokeBorder(.white.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .frame(width: rect.width * unit, height: rect.height * unit)
            .offset(x: rect.minX * unit, y: rect.minY * unit)
            .allowsHitTesting(false)
    }

    private func tileView(_ tile: PlacedTile) -> some View {
        let side = tile.size * unit
        return TileView(tile: tile, side: side, isSelected: selection == tile.id)
            .frame(width: side, height: side)
            .offset(x: tile.rect.minX * unit, y: tile.rect.minY * unit)
            .gesture(tileDrag(tile))
            .onTapGesture { selection = tile.id }
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
                guard let index = design.tiles.firstIndex(where: { $0.id == tile.id }) else { return }
                let base = tileBase ?? design.tiles[index].center
                if tileBase == nil {
                    tileBase = base
                    selection = tile.id
                }
                let moved = CGPoint(
                    x: base.x + value.translation.width / unit,
                    y: base.y + value.translation.height / unit
                )
                let extent = design.tiles[index].boundingExtent
                guard design.snapEnabled else {
                    design.tiles[index].center = CGPoint(
                        x: min(max(moved.x, extent / 2), model.screenPixelSize.width - extent / 2),
                        y: min(max(moved.y, extent / 2), model.screenPixelSize.height - extent / 2)
                    )
                    return
                }
                let engine = SnapEngine(
                    screenSize: model.screenPixelSize,
                    widgetRect: design.widgetRect
                )
                let snapped = engine.snap(
                    center: moved,
                    tileSize: extent,
                    siblings: design.tiles.filter { $0.id != tile.id }
                )
                design.tiles[index].center = engine.clamp(center: snapped.center, tileSize: extent)
            }
            .onEnded { _ in tileBase = nil }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Layout").font(.headline)

            Button {
                showingCatalogue = true
            } label: {
                Label("Add app", systemImage: "plus.app")
            }
            .popover(isPresented: $showingCatalogue) {
                CataloguePicker { appID in
                    add(appID: appID)
                    showingCatalogue = false
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Size")
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

            Toggle("Snap to grid", isOn: $design.snapEnabled)

            if let selection, let index = design.tiles.firstIndex(where: { $0.id == selection }) {
                Divider()
                selected(index: index)
            } else {
                Text("Drag the picture to move it, pinch or use the slider to size it. Tap a tile to adjust it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
            Text("The dashed frame is the widget. Only what falls inside it animates; the rest becomes the wallpaper.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func selected(index: Int) -> some View {
        let tile = design.tiles[index]
        return VStack(alignment: .leading, spacing: 10) {
            Text(AppCatalog.app(id: tile.appID)?.name ?? tile.appID)
                .font(.subheadline.weight(.semibold))

            LabeledContent("Size") {
                Slider(
                    value: Binding(
                        get: { design.tiles[index].size },
                        set: { design.tiles[index].size = max(40, $0) }
                    ),
                    in: 40 ... 400
                )
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
            Toggle("Label", isOn: Binding(
                get: { design.tiles[index].showsLabel },
                set: { design.tiles[index].showsLabel = $0 }
            ))

            HStack {
                Button("Remove", role: .destructive) {
                    design.tiles.removeAll { $0.id == tile.id }
                    selection = nil
                }
            }
        }
    }

    private func add(appID: String) {
        // Dropped into the middle of the widget frame rather than the middle
        // of the screen: outside that frame a tile sits on wallpaper the
        // widget never draws, which looks like it vanished.
        let frame = design.widgetRect
        var tile = PlacedTile(
            appID: appID,
            center: CGPoint(x: frame.midX, y: frame.midY),
            size: 180
        )
        design.tiles.append(tile)
        selection = tile.id
    }
}

private struct CataloguePicker: View {
    let onPick: (String) -> Void

    @State private var query = ""

    private var matches: [CatalogApp] {
        let all = AppCatalog.all
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(matches) { app in
                        Button { onPick(app.id) } label: {
                            HStack {
                                Circle().fill(app.tint).frame(width: 14, height: 14)
                                Text(app.name)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 260)
        }
        .padding(12)
        .frame(width: 240)
    }
}
