import SwiftUI

/// Chooses which app occupies each slot of the active design, or hides it.
///
/// The slots and their candidate lists are authored in the studio and frozen
/// into the manifest; the occupant is the phone's choice. Every change is
/// written to the app group and pushed, so the Home Screen follows immediately.
struct SlotSettingsView: View {
    let manifest: BuildManifest
    /// Called after every write so the home view re-reads the choices.
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    /// Working copy of the stored choices, so the rows update as menus change.
    @State private var choices: [String: String] = [:]
    /// nil is the primary clip, mirroring `VariantChoice`.
    @State private var variantID: UUID?

    private var tiles: [PlacedTile] { manifest.placedTiles }

    var body: some View {
        NavigationStack {
            List {
                if !manifest.builtVariants.isEmpty {
                    Section {
                        Picker("Animation", selection: variantBinding) {
                            Text("Standard").tag(UUID?.none)
                            ForEach(manifest.builtVariants) { variant in
                                Text(variant.name).tag(UUID?.some(variant.id))
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } header: {
                        Text("Animation")
                    } footer: {
                        Text("The same design with a different clip in the animated area.")
                    }
                }

                Section {
                    ForEach(tiles) { tile in
                        slotRow(tile)
                    }
                } header: {
                    Text("Slots")
                } footer: {
                    Text("""
                    Each slot offers the apps chosen for it in the studio. \
                    To change an icon, point a slot somewhere else, or fill an \
                    empty spot, tap it on the screen behind this sheet.
                    """)
                }

                Section {
                    Button("Put everything back the way it was built", role: .destructive) {
                        reset()
                    }
                } footer: {
                    Text("Clears every icon, link and filled spot chosen on this phone.")
                }
            }
            .navigationTitle("Design options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            choices = SlotChoices.stored(designID: manifest.designID)
            // Validated against this build, so a stale stored id shows as the
            // Standard row it will actually draw as.
            variantID = VariantChoice.resolved(in: manifest)?.id
        }
    }

    private var variantBinding: Binding<UUID?> {
        Binding(
            get: { variantID },
            set: { id in
                variantID = id
                VariantChoice.set(id, designID: manifest.designID)
                WidgetCenterBridge.reloadAll()
                onChange()
            }
        )
    }

    /// Everything this phone decided, undone at once.
    ///
    /// Per-spot editing happens on the screen itself; what belongs here is the
    /// way back, because a filled spot cannot otherwise be found once it looks
    /// like part of the design.
    private func reset() {
        for tile in tiles {
            SlotChoices.set(.standard, designID: manifest.designID, tileID: tile.id)
            SlotChoices.setIcon(nil, designID: manifest.designID, tileID: tile.id)
            SlotChoices.setLink(nil, designID: manifest.designID, tileID: tile.id)
        }
        for addition in SlotChoices.additions(designID: manifest.designID) {
            SlotChoices.setAddition(nil, designID: manifest.designID, cell: addition.cell)
        }
        choices = SlotChoices.stored(designID: manifest.designID)
        WidgetCenterBridge.reloadAll()
        onChange()
    }

    private func slotRow(_ tile: PlacedTile) -> some View {
        // The stored value, resolved against what this build actually offers -
        // a choice that no longer exists shows as the default it will draw as.
        let current = currentValue(for: tile)
        return HStack(spacing: 12) {
            occupantMark(appID: current == SlotChoices.hiddenValue ? nil : current)
            VStack(alignment: .leading, spacing: 2) {
                Text(currentTitle(for: tile, value: current))
                if tile.alternates.isEmpty {
                    Text("No alternates in this build")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu {
                Picker("Occupant", selection: binding(for: tile)) {
                    Text(name(for: tile.appID)).tag(tile.appID)
                    ForEach(tile.alternates) { alternate in
                        Text(name(for: alternate.appID)).tag(alternate.appID)
                    }
                    Text("Hidden").tag(SlotChoices.hiddenValue)
                }
            } label: {
                HStack(spacing: 4) {
                    Text(current == SlotChoices.hiddenValue ? "Hidden" : name(for: current))
                        .font(.callout)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    /// What the slot will actually draw: the stored choice when this build
    /// still offers it, else the authored occupant it falls back to.
    private func currentValue(for tile: PlacedTile) -> String {
        guard let stored = choices[tile.id.uuidString] else { return tile.appID }
        if stored == SlotChoices.hiddenValue { return stored }
        let offered = [tile.appID] + tile.alternates.map(\.appID)
        return offered.contains(stored) ? stored : tile.appID
    }

    private func currentTitle(for tile: PlacedTile, value: String) -> String {
        value == SlotChoices.hiddenValue
            ? "\(name(for: tile.appID)) slot"
            : name(for: value)
    }

    private func name(for appID: String) -> String {
        AppCatalog.app(id: appID)?.name ?? appID
    }

    private func occupantMark(appID: String?) -> some View {
        Group {
            if let appID, let app = AppCatalog.app(id: appID) {
                Image(systemName: app.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(app.tint.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                Image(systemName: "eye.slash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
    }

    private func binding(for tile: PlacedTile) -> Binding<String> {
        Binding(
            get: { currentValue(for: tile) },
            set: { value in
                write(value == tile.appID ? .standard : choice(from: value), tile: tile)
            }
        )
    }

    private func choice(from value: String) -> SlotChoices.Choice {
        value == SlotChoices.hiddenValue ? .hidden : .app(value)
    }

    private func write(_ choice: SlotChoices.Choice, tile: PlacedTile) {
        SlotChoices.set(choice, designID: manifest.designID, tileID: tile.id)
        choices = SlotChoices.stored(designID: manifest.designID)
        // Pushed on every change rather than on dismiss: the sheet is exactly
        // half the screen, and the widget updating behind it is the feedback.
        WidgetCenterBridge.reloadAll()
        onChange()
    }
}
