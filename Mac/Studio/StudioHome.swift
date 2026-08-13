import SwiftUI

/// Everything that can be done to a design, in one value.
///
/// Carried rather than passed one closure at a time because two places show
/// designs — the library and the sidebar — and when each wired its own subset
/// they drifted: the sidebar would rename and delete a starter that the library
/// refused to touch, on the same right-click, one pane apart.
struct DesignActions {
    var open: (DesignDocument) -> Void
    var toggleStar: (DesignDocument) -> Void
    var duplicate: (DesignDocument) -> Void
    var rename: (DesignDocument) -> Void
    var export: (DesignDocument) -> Void
    var delete: (DesignDocument) -> Void
}

/// The one menu. Both panes show this, so a design offers the same things
/// wherever it is right-clicked.
struct DesignMenu: View {
    let design: DesignDocument
    let isStarter: Bool
    let actions: DesignActions

    var body: some View {
        Button("Open") { actions.open(design) }
        // Named for what it does rather than for the star: the star is how it
        // is drawn, not what it means.
        Button(design.isStarred ? "Remove from the phone build" : "Include in the phone build") {
            actions.toggleStar(design)
        }
        Divider()
        Button("Duplicate") { actions.duplicate(design) }
        // Export is how a design is shared: one archive carrying the clip, the
        // background and the skins it uses, so it opens on someone else's Mac.
        Button("Export…") { actions.export(design) }
        Divider()
        Button("Rename…") { actions.rename(design) }
            .disabled(isStarter)
        Button("Delete…", role: .destructive) { actions.delete(design) }
            .disabled(isStarter)
        if isStarter {
            Divider()
            Text("Starters cannot be renamed or deleted. Duplicate one to change it.")
        }
    }
}

/// The library, as pictures.
///
/// What a design *is* is a picture on a phone, so that is what this shows. The
/// old library was a list of names and dates in a 320pt column, which meant the
/// only way to find out what a design looked like was to open it.
///
/// Two groups, and the split is not cosmetic: starters ship with Studio and are
/// always there to open, copy and take apart, so a new install is never an
/// empty room. Anything you make lands in the second group and behaves
/// normally.
struct StudioHome: View {
    let designs: [DesignDocument]
    let starterIDs: Set<UUID>
    let store: DesignStore
    let model: DeviceModel
    @Binding var selection: UUID?
    let actions: DesignActions
    let onNew: () -> Void
    let onImport: () -> Void
    /// A file dropped on the library, rather than chosen through a panel.
    let onImportFile: (URL) -> Void
    let onInstallAll: () -> Void
    /// What "Install all" would actually do, or why it cannot. Shown next to
    /// the button so the phone's absence is legible before it is pressed.
    let installAllState: InstallAllState

    struct InstallAllState {
        let starred: Int
        let buildable: Int
        let deviceName: String?
        let isBusy: Bool

        /// A missing phone no longer blocks the button: choosing one is the
        /// first thing the sheet behind it asks for.
        var canRun: Bool { buildable > 0 && !isBusy }

        /// Says the next thing to do, not the state it is in.
        var explanation: String {
            if isBusy { return "Working…" }
            if starred == 0 { return "Star a design to include it" }
            if buildable == 0 { return "Build a starred design first" }
            return "\(buildable) starred → \(deviceName ?? "choose a phone")"
        }
    }

    // A phone is twice as tall as it is wide, so a 230pt card is 500pt of
    // shelf. Narrower fits a real library on one screen and still reads.
    private let columns = [GridItem(.adaptive(minimum: 148, maximum: 180), spacing: 16)]

    private var starters: [DesignDocument] { designs.filter { starterIDs.contains($0.id) } }
    private var mine: [DesignDocument] { designs.filter { !starterIDs.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            Divider()
            grid
        }
        .background(StudioTheme.libraryBackground)
        // Dropping an exported design anywhere on the library imports it,
        // which is what someone who has just been sent one will try first.
        .onDrop(of: [.zip, .fileURL], isTargeted: nil) { providers in
            onImportDropped(providers)
        }
    }

    /// The library's own controls, above the shelf.
    ///
    /// Install all sits here rather than in a menu because it is the thing the
    /// whole tool is for, and it carries its own explanation: a disabled button
    /// that will not say why is worse than no button.
    private var actionBar: some View {
        HStack(spacing: 10) {
            // The window has no title bar to carry the app's name, so the bar
            // that replaced it carries it.
            Text("Motionary Studio")
                .font(StudioTheme.title)
                .foregroundStyle(StudioTheme.textBright)
                .padding(.trailing, 4)

            Button(action: onNew) {
                Label("New design", systemImage: "plus")
            }
            .buttonStyle(.studio)

            Button(action: onImport) {
                Label("Import…", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.studio)
            .help("Open a .motionary.zip someone sent you")

            Spacer()

            Text(installAllState.explanation)
                .font(StudioTheme.monoSmall)
                .foregroundStyle(StudioTheme.textTertiary)

            Button(action: onInstallAll) {
                Label("Install all", systemImage: "iphone.and.arrow.forward")
            }
            .buttonStyle(.studioProminent)
            .disabled(!installAllState.canRun)
            .help("Compile every starred design into the app and install it")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(StudioTheme.headerFill)
    }

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if !starters.isEmpty {
                    section(
                        "Starters",
                        note: "Ship with Studio. Open one to see how it is put together, or duplicate it to make it yours.",
                        designs: starters,
                        areStarters: true
                    )
                }

                if mine.isEmpty {
                    yourDesignsEmpty
                } else {
                    section("Your designs", note: nil, designs: mine, areStarters: false)
                }
            }
            .padding(28)
        }
        // Not `canvasBackground`. That one is fixed dark because it sits behind
        // artwork and must not change what the artwork looks like — but the
        // library is a room full of cards, not a viewing surface, and a dark
        // well behind light cards reads as an unfinished theme rather than a
        // deliberate one.
        .background(StudioTheme.libraryBackground)
    }

    /// Accepts a dropped archive by handing its URL to the same importer the
    /// button uses, so there is one import path rather than two.
    private func onImportDropped(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.pathExtension.lowercased() == "zip" else { return }
            Task { @MainActor in onImportFile(url) }
        }
        return true
    }

    private func section(
        _ title: String,
        note: String?,
        designs: [DesignDocument],
        areStarters: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    StudioTheme.eyebrow(title)
                        .foregroundStyle(StudioTheme.textSecondary)
                    Text("\(designs.count)")
                        .font(StudioTheme.monoSmall)
                        .foregroundStyle(StudioTheme.textDim)
                }
                if let note {
                    Text(note)
                        .font(StudioTheme.small)
                        .foregroundStyle(StudioTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(designs) { design in
                    DesignCard(
                        design: design,
                        store: store,
                        model: model,
                        isStarter: areStarters,
                        isSelected: selection == design.id,
                        onOpen: { actions.open(design) },
                        onToggleStar: { actions.toggleStar(design) }
                    )
                    .onTapGesture { selection = design.id }
                    .contextMenu {
                        DesignMenu(design: design, isStarter: areStarters, actions: actions)
                    }
                }
            }
        }
    }

    /// An empty screen is an invitation to act, so it says the next move rather
    /// than reporting that there is nothing here.
    private var yourDesignsEmpty: some View {
        VStack(alignment: .leading, spacing: 12) {
            StudioTheme.eyebrow("Your designs")
                .foregroundStyle(StudioTheme.textSecondary)

            VStack(spacing: 10) {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(StudioTheme.textDim)
                Text("Nothing of your own yet")
                    .font(StudioTheme.bodyStrong)
                    .foregroundStyle(StudioTheme.text)
                Text("Drop a clip to start from scratch, or duplicate a starter above and change it.")
                    .font(StudioTheme.small)
                    .foregroundStyle(StudioTheme.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                Button("New design from a clip…", action: onNew)
                    .buttonStyle(.studioProminent)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 34)
            .background(StudioTheme.panel.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        StudioTheme.panelEdge,
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                    )
            }
        }
    }
}
