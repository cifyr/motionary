import SwiftUI

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
    let onOpen: (DesignDocument) -> Void
    let onDuplicate: (DesignDocument) -> Void
    let onRename: (DesignDocument) -> Void
    let onDelete: (DesignDocument) -> Void
    let onNew: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 230), spacing: 18)]

    private var starters: [DesignDocument] { designs.filter { starterIDs.contains($0.id) } }
    private var mine: [DesignDocument] { designs.filter { !starterIDs.contains($0.id) } }

    var body: some View {
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
                        onOpen: { onOpen(design) }
                    )
                    .onTapGesture { selection = design.id }
                    .contextMenu { menu(for: design, isStarter: areStarters) }
                }
            }
        }
    }

    @ViewBuilder
    private func menu(for design: DesignDocument, isStarter: Bool) -> some View {
        Button("Open") { onOpen(design) }
        Button("Duplicate") { onDuplicate(design) }
        Divider()
        Button("Rename…") { onRename(design) }
            .disabled(isStarter)
        Button("Delete…", role: .destructive) { onDelete(design) }
            .disabled(isStarter)
        if isStarter {
            Divider()
            Text("Starters cannot be renamed or deleted. Duplicate one to change it.")
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
