import SwiftUI

/// The editor's frame: the toolbar over the canvas, the layer list beside it,
/// and the status bar under it.
///
/// Split from `LayoutEditor` for size alone - these are the same view, and the
/// state they read lives there.
extension LayoutEditor {
    // MARK: - Toolbar

    /// Not `toolbar`: that name is `View.toolbar(content:)`, and the compiler
    /// resolves the modifier rather than this property.
    var editorToolbar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(documentName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !savedNote.isEmpty {
                    Text(savedNote)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 120, alignment: .leading)

            Divider().frame(height: 20)

            // Aligning is a button, not a steady hand. Disabled with nothing
            // selected rather than hidden, so the row does not move about.
            HStack(spacing: 2) {
                alignButton("align.horizontal.left", "Align left", .left)
                alignButton("align.horizontal.center", "Align horizontal centres", .centerX)
                alignButton("align.horizontal.right", "Align right", .right)
                Divider().frame(height: 14)
                alignButton("align.vertical.top", "Align top", .top)
                alignButton("align.vertical.center", "Align vertical centres", .centerY)
                alignButton("align.vertical.bottom", "Align bottom", .bottom)
            }
            .disabled(alignmentTargets.isEmpty)

            Button("Space evenly") {
                design.tiles = LayoutActions.spacedEvenly(design.tiles, selection: selection)
            }
            .disabled(alignmentTargets.count < 3)
            .help("Equal gaps between the selected tiles")

            Button("Make a row") {
                design.tiles = LayoutActions.madeIntoRow(
                    design.tiles,
                    selection: selection,
                    gap: design.grid.gap
                )
            }
            .disabled(alignmentTargets.count < 2)
            .help("Tops aligned, equal gaps, in the order they already sit")

            Spacer()

            Button("Preview", action: onPreview)
            Button("Build to Home Screen", action: onBuild)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Which tiles an align button would move. Alignment is a tile idea here:
    /// a picture is decoration and has no edge anyone lines up against.
    var alignmentTargets: [PlacedTile] {
        design.tiles.filter { selection.contains($0.id) }
    }

    private func alignButton(_ symbol: String, _ help: String, _ edge: LayoutActions.Edge) -> some View {
        Button {
            design.tiles = LayoutActions.aligned(
                design.tiles,
                selection: selection,
                to: edge,
                widgetRect: design.widgetRect
            )
        } label: {
            Image(systemName: symbol).frame(width: 22, height: 18)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(alignmentTargets.count > 1 ? help : "\(help) in the widget frame")
    }

    // MARK: - Layers

    /// Everything on the canvas, in the order it draws.
    ///
    /// The order is fixed by the compositor - wallpaper, clip, pictures, tiles
    /// - so this list is for finding and selecting things, not for restacking
    /// them. It is also the only place a tile's cell is visible at a glance.
    var layersPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            layerHeading("Layers")

            layerRow(
                title: "Scene",
                detail: "wallpaper, frame",
                isSelected: selection.isEmpty
            ) { selection = [] }

            if !design.tiles.isEmpty {
                layerHeading("Tiles")
                ForEach(design.tiles) { tile in
                    layerRow(
                        title: AppCatalog.app(id: tile.appID)?.name ?? tile.appID,
                        detail: tile.cell?.label ?? "off grid",
                        isSelected: selection.contains(tile.id)
                    ) { select(tile.id) }
                }
            }

            if !design.assets.isEmpty {
                layerHeading("Pictures")
                ForEach(design.assets.sorted { $0.zIndex < $1.zIndex }) { asset in
                    layerRow(
                        title: asset.fileName,
                        detail: nil,
                        isSelected: selection.contains(asset.id)
                    ) { select(asset.id) }
                }
            }

            layerHeading("Clip")
            layerRow(
                title: design.sourceVideoName,
                detail: previewedVariantID == nil ? "shown" : nil,
                isSelected: false
            ) { previewedVariantID = nil }

            ForEach(design.variants) { variant in
                layerRow(
                    title: variant.name,
                    detail: previewedVariantID == variant.id ? "shown" : nil,
                    isSelected: false,
                    indented: true
                ) {
                    previewedVariantID = previewedVariantID == variant.id ? nil : variant.id
                }
            }

            if !design.variants.isEmpty {
                Text("All variants share the clip's position.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Text("Order is fixed: wallpaper, clip, pictures, tiles.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func layerHeading(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold).monospaced())
            .foregroundStyle(.tertiary)
            .padding(.top, 2)
    }

    private func layerRow(
        title: String,
        detail: String?,
        isSelected: Bool,
        indented: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            if indented { Spacer().frame(width: 10) }
            Text(title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let detail {
                Text(detail)
                    .font(.system(size: 9).monospaced())
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            isSelected ? Color.accentColor.opacity(0.25) : .clear,
            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    // MARK: - Status bar

    var statusBar: some View {
        HStack(spacing: 12) {
            Text("\(model.name) · \(Int(model.screenPointSize.width)) × \(Int(model.screenPointSize.height)) pt")
                .foregroundStyle(.secondary)

            Divider().frame(height: 12)

            Text(selectionSummary)
                .foregroundStyle(.primary)

            Spacer()

            Text("Arrows nudge 1 px · ⇧ arrows 10 px · ⌥ drag duplicates · ⌘ click adds to the selection")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Toggle("Snap to grid", isOn: $design.snapEnabled)
                .toggleStyle(.checkbox)
                .controlSize(.small)
        }
        .font(.caption.monospaced())
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    /// What is selected, in the terms the inspector uses for it.
    private var selectionSummary: String {
        if selection.isEmpty { return "Nothing selected" }
        if selection.count > 1 { return "\(selection.count) selected" }
        if let tile = design.tiles.first(where: { selection.contains($0.id) }) {
            let name = AppCatalog.app(id: tile.appID)?.name ?? tile.appID
            return "\(name)  x \(Int(tile.center.x))  y \(Int(tile.center.y))  \(Int(tile.size)) px"
        }
        if let asset = design.assets.first(where: { selection.contains($0.id) }) {
            return "\(asset.fileName)  x \(Int(asset.center.x))  y \(Int(asset.center.y))"
        }
        return "Nothing selected"
    }
}
