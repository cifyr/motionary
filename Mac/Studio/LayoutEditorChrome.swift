import SwiftUI

/// The editor's frame: the toolbar over the canvas, the layer list beside it,
/// and the status bar under it.
///
/// Styled from the design mockup - see `StudioTheme` for where the colours and
/// type come from. Split from `LayoutEditor` for size alone; these are the same
/// view, and the state they read lives there.
extension LayoutEditor {
    // MARK: - Toolbar

    /// Not `toolbar`: that name is `View.toolbar(content:)`, and the compiler
    /// resolves the modifier rather than this property.
    var editorToolbar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 1) {
                Text(documentName)
                    .font(StudioTheme.title)
                    .tracking(-0.13)
                    .foregroundStyle(StudioTheme.textBright)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(savedNote.isEmpty ? "unsaved" : savedNote)
                    .font(StudioTheme.monoSmall)
                    .foregroundStyle(StudioTheme.textDim)
            }
            .frame(minWidth: 158, alignment: .leading)

            // Aligning is a button, not a steady hand. Dimmed rather than
            // hidden with nothing selected, so the row never moves about.
            HStack(spacing: 3) {
                alignButton("align.horizontal.left", "Align left", .left)
                alignButton("align.horizontal.center", "Align horizontal centres", .centerX)
                alignButton("align.horizontal.right", "Align right", .right)
                Rectangle().fill(StudioTheme.divider).frame(width: 1, height: 16)
                    .padding(.horizontal, 3)
                alignButton("align.vertical.top", "Align top", .top)
                alignButton("align.vertical.center", "Align vertical centres", .centerY)
                alignButton("align.vertical.bottom", "Align bottom", .bottom)
            }
            .disabled(alignmentTargets.isEmpty)

            Button("Space evenly") {
                design.tiles = LayoutActions.spacedEvenly(design.tiles, selection: selection)
            }
            .buttonStyle(.studio)
            .disabled(alignmentTargets.count < 3)
            .help("Equal gaps between the selected tiles")

            Button("Make a row") {
                design.tiles = LayoutActions.madeIntoRow(
                    design.tiles,
                    selection: selection,
                    gap: design.grid.gap
                )
            }
            .buttonStyle(.studio)
            .disabled(alignmentTargets.count < 2)
            .help("Tops aligned, equal gaps, in the order they already sit")

            Spacer()

            Button("Preview", action: onPreview)
                .buttonStyle(.studio)
            Button("Build to Home Screen", action: onBuild)
                .buttonStyle(.studioProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(
            LinearGradient(
                colors: [StudioTheme.toolbarTop, StudioTheme.toolbarBottom],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(StudioTheme.toolbarEdge).frame(height: 1)
        }
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
            Image(systemName: symbol).font(.system(size: 11))
        }
        .buttonStyle(.studioCompact)
        .help(alignmentTargets.count > 1 ? help : "\(help) in the widget frame")
    }

    // MARK: - Layers

    /// Everything on the canvas, in the order it draws.
    ///
    /// The order is fixed by the compositor - wallpaper, clip, pictures, tiles
    /// - so this list is for finding and selecting things, not for restacking
    /// them. It is also the only place a tile's cell is visible at a glance.
    var layersPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            StudioTheme.eyebrow("Layers")
                .foregroundStyle(StudioTheme.textTertiary)
                .padding(.horizontal, 13)
                .padding(.top, 12)
                .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    layerRow(
                        title: "Scene",
                        detail: "wallpaper, frame",
                        isSelected: selection.isEmpty
                    ) { selection = [] }

                    if !design.tiles.isEmpty {
                        layerGroup("Tiles")
                        ForEach(design.tiles) { tile in
                            layerRow(
                                title: AppCatalog.app(id: tile.appID)?.name ?? tile.appID,
                                detail: tile.cell?.label ?? "off grid",
                                isSelected: selection.contains(tile.id)
                            ) { select(tile.id) }
                        }
                    }

                    if !design.assets.isEmpty {
                        layerGroup("Pictures")
                        ForEach(design.assets.sorted { $0.zIndex < $1.zIndex }) { asset in
                            layerRow(
                                title: asset.fileName,
                                detail: nil,
                                isSelected: selection.contains(asset.id)
                            ) { select(asset.id) }
                        }
                    }

                    layerGroup("Clip")
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
                            .font(.system(size: 10))
                            .foregroundStyle(StudioTheme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 6)
                            .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }

            Spacer(minLength: 0)

            Text("Order is fixed: wallpaper, clip, pictures, tiles.")
                .font(.system(size: 10))
                .foregroundStyle(StudioTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(13)
        }
        .frame(width: Self.layersWidth, alignment: .leading)
        .background(StudioTheme.panel)
        .overlay(alignment: .trailing) {
            Rectangle().fill(StudioTheme.panelEdge).frame(width: 1)
        }
    }

    private func layerGroup(_ text: String) -> some View {
        StudioTheme.eyebrow(text)
            .foregroundStyle(StudioTheme.textDim)
            .padding(.horizontal, 6)
            .padding(.top, 10)
            .padding(.bottom, 3)
    }

    private func layerRow(
        title: String,
        detail: String?,
        isSelected: Bool,
        indented: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            if indented {
                Text("+")
                    .font(StudioTheme.monoSmall)
                    .foregroundStyle(isSelected ? StudioTheme.onAccent : StudioTheme.textDim)
            }
            Text(title)
                .font(StudioTheme.small)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let detail {
                Text(detail)
                    .font(StudioTheme.monoSmall)
                    .foregroundStyle(isSelected ? StudioTheme.onAccent.opacity(0.75) : StudioTheme.textDim)
            }
        }
        .foregroundStyle(isSelected ? StudioTheme.onAccent : StudioTheme.text)
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(
            isSelected ? StudioTheme.accent : .clear,
            in: RoundedRectangle(cornerRadius: StudioTheme.radius, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    // MARK: - Status bar

    var statusBar: some View {
        HStack(spacing: 11) {
            Text("\(model.name) · \(Int(model.screenPointSize.width)) × \(Int(model.screenPointSize.height)) pt")
                .font(StudioTheme.mono)
                .tracking(0.3)
            Text("zoom locked")
                .foregroundStyle(StudioTheme.textDim)

            Rectangle().fill(StudioTheme.divider).frame(width: 1, height: 16)

            Text(selectionSummary)
                .font(StudioTheme.mono)
                .foregroundStyle(StudioTheme.accent)

            Spacer()

            Text("Arrows nudge 1 px · ⇧ arrows 10 px · ⌥ drag duplicates · ⌘ click adds")
                .foregroundStyle(StudioTheme.textDim)
                .lineLimit(1)
                .truncationMode(.tail)

            Toggle("Snap to grid", isOn: $design.snapEnabled)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .foregroundStyle(StudioTheme.textSecondary)
        }
        .font(StudioTheme.body)
        .foregroundStyle(StudioTheme.textSecondary)
        .padding(.horizontal, 15)
        .frame(height: 30)
        .background(StudioTheme.statusFill)
        .overlay(alignment: .top) {
            Rectangle().fill(StudioTheme.statusEdge).frame(height: 1)
        }
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
