import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

/// Turns one sheet of icons plus a table of names into a skin set.
///
/// The table is the layout as well as the labels, so nothing has to be counted:
/// seven columns of names is seven columns of icons. What comes out is a set
/// the phone can swap within, plus every unmatched icon still in the library
/// to be put on a tile by hand.
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
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Import a sprite sheet").font(.headline)
                Text("One picture of icons on a grid, and the names that go with them. The names decide the grid: seven columns of names cuts the sheet into seven columns.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                sheetWell
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Set name", text: $setName)
                        .textFieldStyle(.roundedBorder)
                    if let sheet {
                        Text("\(sheet.width) × \(sheet.height) px")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let layout {
                        Text("\(layout.columns) across × \(layout.rows) down · \(layout.cellCount) cells")
                            .font(.caption.monospacedDigit())
                        let matched = layout.flattened.filter { !$0.isEmpty && SpriteSheet.app(named: $0) != nil }.count
                        let named = layout.flattened.filter { !$0.isEmpty }.count
                        Text("\(matched) of \(named) names match an app. The rest import as artwork you can put on any tile.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Paste the names below to set the grid.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Names").font(.caption.weight(.semibold))
                TextEditor(text: $namesText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 170)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.3))
                    }
                Text("A markdown table works as pasted, pipes and bold and all. A blank cell skips that icon.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(busy ? "Importing..." : "Import") { runImport() }
                    .disabled(!canImport)
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    private var sheetWell: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(
                sheet == nil ? Color.secondary.opacity(0.4) : Color.accentColor,
                style: StrokeStyle(lineWidth: 1.5, dash: sheet == nil ? [6, 4] : [])
            )
            .frame(width: 160, height: 160)
            .overlay {
                if let sheet {
                    Image(decorative: sheet, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(6)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "square.grid.3x3").font(.title2)
                        Text("Drop a sheet").font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }
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
