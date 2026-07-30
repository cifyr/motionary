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
    /// Where a chosen background is stored, so the editor can both read one
    /// back and write a newly picked one alongside the design.
    let store: DesignStore?

    @State private var selection: UUID?
    @State private var placementBase: MediaTransform?
    @State private var scaleBase: Double?
    @State private var tileBase: CGPoint?
    @State private var showingCatalogue = false
    /// Applied to tiles added later, so turning labels off once does not have
    /// to be repeated for every app placed after it.
    @State private var labelsDefault = true
    @State private var skins: [SkinLibrary.Skin] = []
    @State private var background: CGImage?
    @State private var skinNote: String?
    /// The asset whose key colour is being picked by clicking it.
    @State private var pickingKeyFor: UUID?

    /// Points per screen pixel, so the canvas is the phone at a readable size.
    static let zoom: CGFloat = 0.62

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

    /// Wide enough for the canvas and the sidebar together.
    ///
    /// Without it the sheet inherited the studio window's 520pt width and cut
    /// the sidebar and the Build button off the right edge.
    static func width(for model: DeviceModel) -> CGFloat {
        model.screenPointSize.width * zoom + sidebarWidth + 60
    }

    static func height(for model: DeviceModel) -> CGFloat {
        model.screenPointSize.height * zoom + 40
    }

    private static let sidebarWidth: CGFloat = 240

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            screen
            // Scrolled, because the sidebar holds more than the sheet is tall.
            // Overflowing it squeezed the flexible child - the skin grid - down
            // to nothing, so an imported skin was in the view tree and zero
            // pixels high, which reads exactly like an import that failed.
            ScrollView {
                sidebar.frame(width: Self.sidebarWidth, alignment: .leading)
            }
            .frame(width: Self.sidebarWidth)
        }
        .padding(20)
        .task {
            reloadSkins()
            reloadBackground()
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
        skins = (try? SkinLibrary().all()) ?? []
    }

    private func importSkins() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsMultipleSelection = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        do {
            // Counted and reported. Swallowing this with `try?` made a failed
            // import look exactly like a successful one, which is how an
            // import that worked came to look like an import that did nothing.
            let added = try SkinLibrary().importing(panel.urls)
            reloadSkins()
            let failed = panel.urls.count - added.count
            skinNote = failed == 0
                ? "Added \(added.count) skin\(added.count == 1 ? "" : "s")."
                : "Added \(added.count), could not read \(failed)."
        } catch {
            skinNote = "Import failed: \(error.localizedDescription)"
        }
    }

    /// The library, always reachable.
    ///
    /// It used to live inside the selected tile's section, which meant there was
    /// nowhere to import a skin until a tile happened to be selected - and no
    /// way to tell that was why nothing appeared to happen.
    private var skinPicker: some View {
        let index = selection.flatMap { id in design.tiles.firstIndex { $0.id == id } }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Skins").font(.caption.weight(.semibold))
                Spacer()
                Button("Import...") { importSkins() }.buttonStyle(.link)
            }
            if let skinNote {
                Text(skinNote).font(.caption2).foregroundStyle(.secondary)
            }
            if skins.isEmpty {
                Text("No skins yet. Import icon artwork - a green screen is removed automatically - and it stays available for every design.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if index == nil {
                Text("\(skins.count) skin\(skins.count == 1 ? "" : "s") ready. Select a tile to put one on it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let index {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 6), count: 4), spacing: 6) {
                    Button {
                        design.tiles[index].skin = nil
                    } label: {
                        Image(systemName: "nosign")
                            .frame(width: 44, height: 44)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help("No skin - use the tinted plate")

                    ForEach(skins) { skin in
                        Button {
                            design.tiles[index].skin = skin.id
                        } label: {
                            AsyncSkinThumbnail(url: skin.url)
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(
                                            design.tiles[index].skin == skin.id
                                                ? Color.accentColor : .clear,
                                            lineWidth: 2
                                        )
                                }
                        }
                        .buttonStyle(.plain)
                        .help(skin.id)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
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
            .clipShape(RoundedRectangle(cornerRadius: 34 * Self.zoom, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 34 * Self.zoom, style: .continuous)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 1)
            )
            .gesture(clipDrag)
            .simultaneousGesture(clipZoom)
            .onTapGesture { selection = nil }
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
            if let poster {
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
            isSelected: selection == tile.id,
            iconImage: tile.skin
                .flatMap { try? SkinLibrary().url(for: $0) }
                .flatMap { ImageLoader.load(at: $0, maxPixelSize: Int(side * 3)) }
                .map { Image(decorative: $0, scale: 1) }
        )
            .frame(width: side, height: side)
            .offset(x: tile.rect.minX * unit, y: tile.rect.minY * unit)
            .gesture(tileDrag(tile))
            .onTapGesture { selection = tile.id }
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
            if selection == asset.id {
                Rectangle().strokeBorder(.white.opacity(0.9), lineWidth: 1)
                    .rotationEffect(.degrees(asset.rotation))
            }
        }
        .offset(x: asset.rect.minX * unit, y: asset.rect.minY * unit)
        .gesture(assetDrag(asset))
        .onTapGesture { selection = asset.id }
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
                    selection = asset.id
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
                let engine = SnapEngine(
                    screenSize: model.screenPixelSize,
                    widgetRect: design.widgetRect
                )
                // Bounded by the screen, not by the widget frame: a tile may
                // hang over the edge, because the wallpaper carries a picture
                // of the part the widget cannot draw.
                guard design.snapEnabled else {
                    design.tiles[index].center = engine.clamp(center: moved, tileSize: extent)
                    return
                }
                let snapped = engine.snap(
                    center: moved,
                    tileSize: extent,
                    siblings: design.tiles.filter { $0.id != tile.id }
                )
                design.tiles[index].center = engine.clamp(center: snapped.center, tileSize: extent)
            }
            .onEnded { _ in tileBase = nil }
    }

    // MARK: - Assets

    private var selectedAsset: PlacedAsset? {
        guard let selection else { return nil }
        return design.assets.first { $0.id == selection }
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
                Text("Pictures").font(.caption.weight(.semibold))
                Spacer()
                Button("Add...") { importAssets() }.buttonStyle(.link)
            }

            if design.assets.isEmpty {
                Text("Any image, placed anywhere and drawn under the app tiles. A coloured backdrop is keyed out, and it can be retuned here at any time.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(design.assets.sorted { $0.zIndex < $1.zIndex }) { asset in
                    HStack(spacing: 6) {
                        Image(systemName: selection == asset.id ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(.secondary)
                        Text(asset.fileName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .font(.caption)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selection = asset.id }
                    .contextMenu {
                        Button("Bring to front") { restack(asset, toFront: true) }
                        Button("Send to back") { restack(asset, toFront: false) }
                        Button("Remove", role: .destructive) { removeAsset(asset) }
                    }
                }
            }

            if let asset = selectedAsset {
                assetInspector(asset)
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
        if selection == asset.id { selection = nil }
        store?.removeAsset(named: asset.fileName, for: design.id)
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

            assetsSection

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

            skinPicker

            Toggle("Snap to grid", isOn: $design.snapEnabled)

            Toggle("Icon labels", isOn: Binding(
                get: { design.tiles.allSatisfy(\.showsLabel) && !design.tiles.isEmpty },
                set: { on in
                    labelsDefault = on
                    for index in design.tiles.indices { design.tiles[index].showsLabel = on }
                }
            ))
            .disabled(design.tiles.isEmpty)

            if let selection, let index = design.tiles.firstIndex(where: { $0.id == selection }) {
                Divider()
                selected(index: index)
            } else {
                Text("Drag the picture to move it, pinch or use the slider to size it. Tap a tile to adjust it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("The dashed frame is the widget. Only what falls inside it animates and answers a tap; the rest becomes the wallpaper, tiles included.")
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
            if AppCatalog.app(id: tile.appID)?.canLaunch == false {
                Text("Cannot be opened from a widget - no URL scheme exists for it. It still draws.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LabeledContent("Size") {
                Slider(
                    value: Binding(
                        get: { design.tiles[index].size },
                        set: { size in
                            design.tiles[index].size = max(40, size)
                            // Growing a tile can push it off the screen just as
                            // dragging can.
                            design.tiles[index].center = SnapEngine(
                                screenSize: model.screenPixelSize,
                                widgetRect: design.widgetRect
                            ).clamp(
                                center: design.tiles[index].center,
                                tileSize: design.tiles[index].boundingExtent
                            )
                        }
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
        // Dropped into the middle of the widget frame rather than the middle of
        // the screen: outside that frame a tile is only a picture on the
        // wallpaper, and a new tile should land somewhere it can be tapped.
        let frame = design.widgetRect
        var tile = PlacedTile(
            appID: appID,
            center: CGPoint(x: frame.midX, y: frame.midY),
            size: 180
        )
        tile.showsLabel = labelsDefault
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
                                // Some Apple apps publish no URL scheme, so a
                                // tile for one can never open anything. Better
                                // said here than discovered by tapping it.
                                if !app.canLaunch {
                                    Image(systemName: "hand.raised.slash")
                                        .foregroundStyle(.secondary)
                                        .help("\(app.name) cannot be opened from a widget: it publishes no URL scheme.")
                                }
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


/// A skin thumbnail, decoded once per appearance.
private struct AsyncSkinThumbnail: View {
    let url: URL

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
            image = ImageLoader.load(at: url, maxPixelSize: 132).map { Image(decorative: $0, scale: 1) }
        }
    }
}


