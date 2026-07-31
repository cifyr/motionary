import SwiftUI

/// One spot of the design, edited on the phone.
///
/// A spot is either a slot the studio placed - which already carries a skin set
/// and a list of apps - or a cell of the grid the design left empty. Both are
/// changed the same way, because from the phone's side they are the same thing:
/// pick the artwork, then say what it opens.
struct SlotEditorView: View {
    /// What is being edited. An authored tile is the one from the manifest, not
    /// the effective one: the picker offers the *set's* skins, and the effective
    /// tile has already had the phone's own choice written over it.
    enum Spot: Identifiable, Equatable {
        case tile(PlacedTile)
        case cell(GridCell)

        var id: String {
            switch self {
            case .tile(let tile): tile.id.uuidString
            case .cell(let cell): "cell-\(cell.label)"
            }
        }

        var cell: GridCell? {
            if case .cell(let cell) = self { return cell }
            return nil
        }

        var tile: PlacedTile? {
            if case .tile(let tile) = self { return tile }
            return nil
        }
    }

    /// The artwork on a spot. Kept apart from the app so the two can be chosen
    /// independently, which is the whole point: an icon is a picture, not a
    /// claim about what it opens.
    enum IconChoice: Equatable {
        /// The icon the studio baked for this slot. Only an authored tile has
        /// one to go back to.
        case authored
        /// Nothing drawn at all.
        case none
        case skin(String)
    }

    let manifest: BuildManifest
    let spot: Spot
    /// Called after every write, so the screen behind re-reads the choices.
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var icon: IconChoice = .authored
    @State private var opensApp = false
    /// A catalogue id, or `customValue` when the app is typed by hand.
    @State private var appSelection = ""
    @State private var customName = ""
    @State private var customScheme = ""

    private static let customValue = "-custom-"

    /// The skins this spot may wear.
    ///
    /// A slot the studio styled offers its own set and nothing else - that is
    /// the point of a set. An empty cell belongs to no set, so it offers what
    /// the design's own slots are wearing, which is the pack it was built in.
    /// Only a design with no styled slots at all falls back to the whole
    /// library, where there is no set to prefer.
    private var skins: [String] {
        if let tile = spot.tile, !tile.setSkins.isEmpty { return tile.setSkins }
        var seen = Set<String>()
        let designs = manifest.placedTiles
            .flatMap(\.setSkins)
            .filter { seen.insert($0).inserted }
        return designs.isEmpty ? PrebuiltDesign.skinNames(designID: manifest.designID) : designs
    }

    /// The apps offered without typing anything: every catalogue entry that can
    /// actually be opened. One that publishes no scheme is left out, because
    /// picking it would produce a tile that silently does nothing.
    private var catalogue: [CatalogApp] {
        AppCatalog.all.filter(\.canLaunch).sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            List {
                iconSection
                appSection
                if canClear {
                    Section {
                        Button("Empty this spot", role: .destructive) {
                            icon = .none
                            opensApp = false
                            write()
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: load)
    }

    private var title: String {
        switch spot {
        case .tile(let tile): tile.displayName
        case .cell(let cell): "Empty spot \(cell.label)"
        }
    }

    /// Only a spot with something in it can be emptied. Offering it on one that
    /// is already blank is a button that does nothing.
    private var canClear: Bool {
        switch spot {
        case .tile: icon != .none
        case .cell(let cell): SlotChoices.addition(designID: manifest.designID, cell: cell) != nil
        }
    }

    // MARK: - The icon

    private var iconSection: some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 10)], spacing: 10) {
                swatch(.none) {
                    Image(systemName: "square.dashed")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                if spot.tile != nil {
                    swatch(.authored) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(skins, id: \.self) { skin in
                    swatch(.skin(skin)) {
                        if let image = PrebuiltDesign.skinURL(designID: manifest.designID, skin: skin)
                            .flatMap({ ImageLoader.load(at: $0, maxPixelSize: 160) }) {
                            Image(decorative: image, scale: 1).resizable().scaledToFit()
                        } else {
                            Image(systemName: "questionmark")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Icon")
        } footer: {
            Text(skins.isEmpty
                 ? "This build shipped no icons for this spot. Rebuild from the studio to send its icon set over."
                 : "The icons this design carries for this spot. None leaves it blank.")
        }
    }

    private func swatch(_ choice: IconChoice, @ViewBuilder content: () -> some View) -> some View {
        Button {
            icon = choice
            write()
        } label: {
            content()
                .frame(width: 54, height: 54)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(icon == choice ? Color.accentColor : .clear, lineWidth: 2.5)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label(for: choice))
        .accessibilityAddTraits(icon == choice ? [.isSelected] : [])
    }

    private func label(for choice: IconChoice) -> String {
        switch choice {
        case .authored: "The design's own icon"
        case .none: "No icon"
        case .skin(let name): name
        }
    }

    // MARK: - The app

    private var appSection: some View {
        Section {
            Toggle("Choose the app it opens", isOn: Binding(
                get: { opensApp },
                set: { on in
                    opensApp = on
                    if on, appSelection.isEmpty { appSelection = catalogue.first?.id ?? Self.customValue }
                    write()
                }
            ))

            if opensApp {
                Picker("App", selection: Binding(
                    get: { appSelection },
                    set: { appSelection = $0; write() }
                )) {
                    ForEach(catalogue) { app in
                        Label(app.name, systemImage: app.symbol).tag(app.id)
                    }
                    Text("Something else…").tag(Self.customValue)
                }

                if appSelection == Self.customValue {
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
                }

                if let first = target()?.launchCandidates.first {
                    Text("Opens \(first.absoluteString)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if appSelection == Self.customValue {
                    Text("Type the app's URL scheme - spotify, things, bear. A web address works too.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Opens")
        } footer: {
            Text(opensApp
                 ? "Motionary opens the app for you, so a spot can point at anything on this phone."
                 : defaultOpensDescription)
        }
    }

    private var defaultOpensDescription: String {
        switch spot {
        case .tile(let tile): "Opens \(tile.displayName), as the design was built."
        case .cell: "This spot opens nothing until an app is chosen."
        }
    }

    // MARK: - Reading and writing

    private func load() {
        switch spot {
        case .tile(let tile):
            if SlotChoices.choice(designID: manifest.designID, tileID: tile.id) == .hidden {
                icon = .none
            } else if let chosen = SlotChoices.icon(designID: manifest.designID, tileID: tile.id) {
                icon = chosen.isEmpty ? .none : .skin(chosen)
            } else {
                icon = .authored
            }
            adopt(SlotChoices.link(designID: manifest.designID, tileID: tile.id))
        case .cell(let cell):
            let addition = SlotChoices.addition(designID: manifest.designID, cell: cell)
            icon = addition?.skin.map(IconChoice.skin) ?? .none
            adopt(addition?.target)
        }
    }

    /// Matches a stored target back to the catalogue where it came from one, so
    /// re-opening the sheet shows the app that was picked rather than dropping
    /// every choice into the hand-typed fields.
    private func adopt(_ target: CustomTarget?) {
        guard let target else {
            opensApp = false
            appSelection = ""
            return
        }
        opensApp = true
        customName = target.name
        customScheme = target.scheme
        appSelection = catalogue.first { $0.scheme == target.scheme && $0.name == target.name }?.id
            ?? Self.customValue
    }

    /// What the spot should open, or nil when it keeps the design's own target.
    private func target() -> CustomTarget? {
        guard opensApp else { return nil }
        if appSelection == Self.customValue {
            return CustomTarget(name: customName, scheme: customScheme)
        }
        guard let app = catalogue.first(where: { $0.id == appSelection }) else { return nil }
        return CustomTarget(name: app.name, scheme: app.scheme ?? "", webFallback: app.webFallback)
    }

    private func write() {
        switch spot {
        case .tile(let tile):
            SlotChoices.set(icon == .none ? .hidden : .standard, designID: manifest.designID, tileID: tile.id)
            switch icon {
            case .authored, .none: SlotChoices.setIcon(nil, designID: manifest.designID, tileID: tile.id)
            case .skin(let name): SlotChoices.setIcon(name, designID: manifest.designID, tileID: tile.id)
            }
            SlotChoices.setLink(target(), designID: manifest.designID, tileID: tile.id)
        case .cell(let cell):
            let chosen = target()
            // A spot with neither artwork nor a destination is an empty spot,
            // and storing one would leave an invisible tile swallowing taps.
            guard icon != .none || chosen != nil else {
                SlotChoices.setAddition(nil, designID: manifest.designID, cell: cell)
                break
            }
            var skin: String?
            if case .skin(let name) = icon { skin = name }
            SlotChoices.setAddition(
                SlotChoices.Addition(
                    cell: cell,
                    skin: skin,
                    target: chosen,
                    name: chosen?.name ?? skin ?? cell.label
                ),
                designID: manifest.designID,
                cell: cell
            )
        }
        WidgetCenterBridge.reloadAll()
        onChange()
    }
}
