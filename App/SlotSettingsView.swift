import SwiftUI

/// The settings that belong to the design rather than to any one slot: which
/// clip plays, and the way back from everything this phone has changed.
///
/// Slots are edited on the screen itself, by tapping them - a list of them here
/// as well would be a second answer to the same question, and the two would
/// disagree the moment one of them was wrong.
struct SlotSettingsView: View {
    let manifest: BuildManifest
    /// Called after every write so the home view re-reads the choices.
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    /// nil is the primary clip, mirroring `VariantChoice`.
    @State private var variantID: UUID?

    var body: some View {
        NavigationStack {
            List {
                if !manifest.builtVariants.isEmpty {
                    Section {
                        Picker("Animation", selection: variantBinding) {
                            Text(manifest.primaryClipTitle).tag(UUID?.none)
                            ForEach(manifest.builtVariants) { variant in
                                Text(variant.name).tag(UUID?.some(variant.id))
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } header: {
                        Text("Animation")
                    } footer: {
                        Text("""
                        The same design with a different clip in the animated \
                        area. While editing, swiping sideways anywhere but an \
                        icon steps through these too.
                        """)
                    }
                }

                Section {
                    Button("Put everything back the way it was built", role: .destructive) {
                        reset()
                    }
                } footer: {
                    Text("Clears every icon, app and link chosen on this phone.")
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
    /// Per-slot editing happens on the screen itself; what belongs here is the
    /// way back, in one place, for when a design has been changed past
    /// recognising.
    private func reset() {
        for tile in manifest.placedTiles {
            SlotChoices.set(.standard, designID: manifest.designID, tileID: tile.id)
            SlotChoices.setIcon(nil, designID: manifest.designID, tileID: tile.id)
            SlotChoices.setLink(nil, designID: manifest.designID, tileID: tile.id)
        }
        WidgetCenterBridge.reloadAll()
        onChange()
    }
}
