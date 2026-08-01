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
    /// Working copies, so the rows follow the field rather than the store -
    /// which is UserDefaults, and SwiftUI does not observe it.
    @State private var tapsOpenAPage = false
    @State private var address = BackgroundTap.defaultAddress

    var body: some View {
        NavigationStack {
            List {
                if !manifest.builtVariants.isEmpty {
                    Section {
                        Picker("Animation", selection: variantBinding) {
                            // Alphabetical from the one this scene leads with,
                            // the same order a swipe walks.
                            ForEach(manifest.clipSequence) { clip in
                                Text(clip.name).tag(clip.variantID)
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
                    Toggle("Tapping the background opens a page", isOn: Binding(
                        get: { tapsOpenAPage },
                        set: { on in
                            tapsOpenAPage = on
                            BackgroundTap.isEnabled = on
                            WidgetCenterBridge.reloadAll()
                        }
                    ))

                    if tapsOpenAPage {
                        TextField("google.com", text: Binding(
                            get: { address },
                            set: { typed in
                                address = typed
                                BackgroundTap.address = typed
                                WidgetCenterBridge.reloadAll()
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)

                        if let url = BackgroundTap.url(for: address) {
                            Text("Opens \(url.absoluteString) in your browser.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("That is not a web address, so nothing will answer the tap.")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                } header: {
                    Text("The space between the icons")
                } footer: {
                    Text("""
                    A tap that misses every icon opens this page in your \
                    default browser, straight from the Home Screen rather than \
                    through Motionary. Off leaves the gaps doing nothing.
                    """)
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
            tapsOpenAPage = BackgroundTap.isEnabled
            address = BackgroundTap.address
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
