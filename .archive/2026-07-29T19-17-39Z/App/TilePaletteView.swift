import SwiftUI

struct TilePaletteView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    let onSelect: (CatalogApp) -> Void

    private var results: [CatalogApp] {
        guard !search.isEmpty else { return AppCatalog.all }
        return AppCatalog.all.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(CatalogApp.Category.allCases) { category in
                    let apps = results.filter { $0.category == category }
                    if !apps.isEmpty {
                        Section(category.rawValue) {
                            ForEach(apps) { app in
                                Button {
                                    onSelect(app)
                                    dismiss()
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: app.symbol)
                                            .font(.body)
                                            .foregroundStyle(.white)
                                            .frame(width: 30, height: 30)
                                            .background(app.tint.opacity(0.8), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(app.name).foregroundStyle(.primary)
                                            Text(app.scheme ?? app.webFallback ?? "")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search apps")
            .navigationTitle("Add app")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
