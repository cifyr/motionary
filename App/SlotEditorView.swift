import SwiftUI

/// One slot of the design, changed on the phone.
///
/// A slot carries a set: the app the studio put there and every other app the
/// same icon pack was drawn for. Picking one of them is a single choice, not
/// two - the artwork and the app it stands for travel together, so choosing the
/// Spotify drawing points the slot at Spotify and names it Spotify. What is left
/// over is the link, which only matters when the set names something the
/// catalogue has never heard of, or when this phone opens it some other way.
struct SlotEditorView: View {
    /// The authored tile from the manifest, not the effective one: the set and
    /// the slot's own default both live there, and the phone's choice has
    /// already been written over the effective copy.
    let manifest: BuildManifest
    let tile: PlacedTile
    /// Called after every write, so the screen behind re-reads the choices.
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// The chosen entry's id: an appID, or `blankValue` for no icon at all.
    @State private var selection = ""
    @State private var customLink = false
    @State private var customName = ""
    @State private var customShortcut = ""
    @State private var customScheme = ""

    /// One thing the slot can become: an app drawn in this set's style.
    ///
    /// The blank comes first and belongs to every set - a slot has to be able
    /// to hold nothing without disappearing, which is what it did when blanking
    /// simply dropped it.
    private struct Entry: Identifiable {
        let appID: String
        let skin: String?
        var id: String { appID }
    }

    private var entries: [Entry] {
        [Entry(appID: SlotChoices.blankValue, skin: nil), Entry(appID: tile.appID, skin: tile.skin)]
            + tile.offeredAlternates.map { Entry(appID: $0.appID, skin: $0.skin) }
    }

    private var isBlank: Bool { selection == SlotChoices.blankValue }

    /// The catalogue entry behind the selection, when there is one. A set drawn
    /// for a category rather than an app - "Games", "Banking" - has none, and
    /// then the name and the link are this phone's to supply.
    private var catalogueApp: CatalogApp? {
        isBlank ? nil : AppCatalog.app(id: selection)
    }

    var body: some View {
        NavigationStack {
            List {
                iconSection
                if !isBlank { linkSection }
            }
            .navigationTitle(isBlank ? "Blank spot" : displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .emberSheet()
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: load)
    }

    /// What the slot is called right now: the name this phone gave it, else the
    /// catalogue's, else the set's own word for it.
    private var displayName: String {
        if customLink, !customName.isEmpty { return customName }
        return catalogueApp?.name ?? selection
    }

    // MARK: - The set

    private var iconSection: some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: 10)], spacing: 10) {
                ForEach(entries) { entry in
                    swatch(entry)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Icon").emberLabel()
        } footer: {
            Text("""
            The apps this slot's icon pack was drawn for. Choosing one changes \
            the picture and what it opens together. Blank leaves the spot empty \
            without giving it up - it stays here to change back.
            """)
        }
    }

    private func swatch(_ entry: Entry) -> some View {
        let isSelected = selection == entry.appID
        return Button {
            guard selection != entry.appID else { return }
            selection = entry.appID
            // The link belonged to the app that was there. Carrying it over
            // would leave the slot showing one app and opening another, which
            // is the exact confusion a set is meant to remove.
            customLink = false
            customName = ""
            customShortcut = ""
            customScheme = ""
            write()
        } label: {
            VStack(spacing: 4) {
                Group {
                    if let skin = entry.skin,
                       let image = PrebuiltDesign.skinURL(designID: manifest.designID, skin: skin)
                           .flatMap({ ImageLoader.load(at: $0, maxPixelSize: 160) }) {
                        Image(decorative: image, scale: 1).resizable().scaledToFit()
                    } else if entry.appID == SlotChoices.blankValue {
                        Image(systemName: "square.dashed")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: AppCatalog.app(id: entry.appID)?.symbol ?? "questionmark")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 54, height: 54)
                .background(Color.white.opacity(0.06))
                .overlay {
                    Rectangle()
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2.5)
                }

                Text(name(of: entry))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name(of: entry))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func name(of entry: Entry) -> String {
        entry.appID == SlotChoices.blankValue ? "Blank" : (AppCatalog.app(id: entry.appID)?.name ?? entry.appID)
    }

    // MARK: - What it opens

    @ViewBuilder
    private var linkSection: some View {
        Section {
            // A set drawn for a category has no app behind it, so there is
            // nothing to fall back to and the fields are the only answer.
            if catalogueApp == nil {
                Text("This icon stands for \(selection), which is not an app this build knows. Name it and say what it opens.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Toggle("Open something else", isOn: Binding(
                    get: { customLink },
                    set: { on in
                        customLink = on
                        if on, customName.isEmpty { customName = catalogueApp?.name ?? selection }
                        if on, customScheme.isEmpty { customScheme = catalogueApp?.scheme ?? "" }
                        write()
                    }
                ))
            }

            if customLink || catalogueApp == nil {
                TextField("Name", text: Binding(
                    get: { customName },
                    set: { customName = $0; write() }
                ))
                .textFieldStyle(.roundedBorder)

                TextField("scheme:// or https://", text: Binding(
                    get: { customScheme },
                    set: { customScheme = $0; write() }
                ))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

                // Left blank by most people. It is here for the app whose
                // scheme does not work or does not exist, where a Shortcut is
                // the only thing that can still open it.
                TextField("Shortcut name (optional)", text: Binding(
                    get: { customShortcut },
                    set: { customShortcut = $0; write() }
                ))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            }

            if let first = target()?.launchCandidates.first {
                Text("Opens \(first.absoluteString)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if customLink || catalogueApp == nil {
                Text("Type the app's URL scheme - spotify, things, bear. A web address works too.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Opens").emberLabel()
        } footer: {
            if !customLink, let app = catalogueApp {
                Text(app.canLaunch
                     ? "Opens \(app.name) through Motionary."
                     : "\(app.name) publishes no way in, so this spot opens nothing until a link is given.")
            }
        }
    }

    // MARK: - Reading and writing

    private func load() {
        switch SlotChoices.choice(designID: manifest.designID, tileID: tile.id) {
        case .hidden: selection = SlotChoices.blankValue
        case .app(let id): selection = id
        case .standard: selection = tile.appID
        }
        if let stored = SlotChoices.link(designID: manifest.designID, tileID: tile.id) {
            customLink = true
            customName = stored.name
            customScheme = stored.scheme
            customShortcut = stored.shortcutName ?? ""
        }
    }

    /// What the slot should open, or nil when the chosen app's own route is
    /// what it uses.
    private func target() -> CustomTarget? {
        guard customLink || catalogueApp == nil, !isBlank else { return nil }
        let name = customName.trimmingCharacters(in: .whitespaces)
        let shortcut = customShortcut.trimmingCharacters(in: .whitespaces)
        return CustomTarget(
            name: name.isEmpty ? selection : name,
            scheme: customScheme,
            shortcutName: shortcut.isEmpty ? nil : shortcut
        )
    }

    private func write() {
        let choice: SlotChoices.Choice = if isBlank {
            .hidden
        } else if selection == tile.appID {
            .standard
        } else {
            .app(selection)
        }
        SlotChoices.set(choice, designID: manifest.designID, tileID: tile.id)
        // The set already carries the artwork for whichever app was chosen, so
        // the per-slot icon override is only in the way here: it would pin the
        // old picture onto the new app.
        SlotChoices.setIcon(nil, designID: manifest.designID, tileID: tile.id)
        SlotChoices.setLink(target(), designID: manifest.designID, tileID: tile.id)
        WidgetCenterBridge.reloadAll()
        onChange()
    }
}
