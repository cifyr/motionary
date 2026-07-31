import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

/// Turns one sheet of icons plus a table of names into a skin set.
///
/// The table is the layout as well as the labels, so nothing has to be counted:
/// seven columns of names is seven columns of icons. What comes out is a set
/// the phone can swap within, plus every unmatched icon still in the library
/// to be put on a tile by hand.
///
/// Carries the studio's colours itself rather than inheriting them: a sheet is
/// presented outside the editor's view tree, so the environment set on the
/// editor never reaches here - which is how this first shipped as white text
/// on a white panel.
struct SpriteSheetImporter: View {
    /// Called with the finished set so the editor can add it to its library.
    let onImport: (SkinSet) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var sheetURL: URL?
    @State private var sheet: CGImage?
    @State private var namesText = ""
    @State private var setName = ""
    @State private var failure: String?
    @State private var busy = false

    private var layout: SpriteSheet.Layout? { SpriteSheet.parseNames(namesText) }

    private var canImport: Bool {
        sheet != nil && (layout?.cellCount ?? 0) > 0 && !busy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import a sprite sheet")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StudioTheme.textBright)
                Text("One picture of icons on a grid, and the names that go with them. The names decide the grid: seven columns of names cuts the sheet into seven columns.")
                    .font(StudioTheme.small)
                    .foregroundStyle(StudioTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 14) {
                sheetWell
                VStack(alignment: .leading, spacing: 8) {
                    StudioTheme.eyebrow("Set name").foregroundStyle(StudioTheme.textTertiary)
                    TextField("Neon", text: $setName)
                        .textFieldStyle(StudioFieldStyle())

                    if let sheet {
                        Text("\(sheet.width) × \(sheet.height) px")
                            .font(StudioTheme.mono)
                            .foregroundStyle(StudioTheme.textSecondary)
                    }
                    if let layout {
                        Text("\(layout.columns) across × \(layout.rows) down · \(layout.cellCount) cells")
                            .font(StudioTheme.mono)
                            .foregroundStyle(StudioTheme.accent)
                        let named = layout.flattened.filter { !$0.isEmpty }
                        let matched = named.filter { SpriteSheet.app(named: $0) != nil }.count
                        Text("\(matched) of \(named.count) names match an app. The rest import as artwork you can put on any tile.")
                            .font(.system(size: 10))
                            .foregroundStyle(StudioTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Paste the names below to set the grid.")
                            .font(.system(size: 10))
                            .foregroundStyle(StudioTheme.textDim)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 5) {
                StudioTheme.eyebrow("Names").foregroundStyle(StudioTheme.textTertiary)
                TextEditor(text: $namesText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(StudioTheme.text)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 165)
                    .background(StudioTheme.well, in: RoundedRectangle(cornerRadius: StudioTheme.radius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: StudioTheme.radius, style: .continuous)
                            .strokeBorder(StudioTheme.headerEdge, lineWidth: 1)
                    }
                Text("A markdown table works as pasted, pipes and bold and all. A blank cell skips that icon.")
                    .font(.system(size: 10))
                    .foregroundStyle(StudioTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let failure {
                Text(failure)
                    .font(StudioTheme.small)
                    .foregroundStyle(Color(hex: 0xff8f6b))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.studio)
                    .keyboardShortcut(.cancelAction)
                Button(busy ? "Importing..." : "Import") { runImport() }
                    .buttonStyle(.studioProminent)
                    .disabled(!canImport)
            }
        }
        .padding(20)
        .frame(width: 620)
        .background(StudioTheme.panel)
        .environment(\.colorScheme, .dark)
        .tint(StudioTheme.accent)
    }

    private var sheetWell: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(StudioTheme.well)
            .frame(width: 164, height: 164)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        sheet == nil ? StudioTheme.controlEdge : StudioTheme.accent,
                        style: StrokeStyle(lineWidth: 1.5, dash: sheet == nil ? [6, 4] : [])
                    )
            }
            .overlay {
                if let sheet {
                    Image(decorative: sheet, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(7)
                } else {
                    VStack(spacing: 7) {
                        Image(systemName: "square.grid.3x3")
                            .font(.system(size: 20))
                        Text("Drop a sheet")
                            .font(StudioTheme.small)
                        Text("or click")
                            .font(.system(size: 10))
                            .foregroundStyle(StudioTheme.textDim)
                    }
                    .foregroundStyle(StudioTheme.textTertiary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { chooseSheet() }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in load(url) }
                }
                return true
            }
    }

    private func chooseSheet() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    private func load(_ url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            failure = "Could not read \(url.lastPathComponent) as an image."
            return
        }
        sheetURL = url
        sheet = image
        failure = nil
        if setName.isEmpty {
            setName = url.deletingPathExtension().lastPathComponent
        }
    }

    private func runImport() {
        guard let sheet, let layout else { return }
        busy = true
        failure = nil
        // The prefix keys every file this sheet writes, so importing a second
        // sheet with the same labels does not overwrite the first one's icons.
        let prefix = SpriteSheet.skinName(for: setName.isEmpty ? "sheet" : setName, prefix: "sheet")
            .replacingOccurrences(of: ".png", with: "")
        do {
            let report = try SpriteSheet.importSheet(
                sheet,
                layout: layout,
                prefix: prefix,
                into: try SkinLibrary()
            )
            var set = SkinSet(name: setName.isEmpty ? "Sheet" : setName)
            set.entries = report.entries
            onImport(set)
            dismiss()
        } catch {
            busy = false
            failure = "Could not import \(sheetURL?.lastPathComponent ?? "the sheet"): \(error)"
        }
    }
}
