import SwiftUI

/// What the app opens into: the active design filling the screen, so launching
/// Motionary looks like the Home Screen the widget is imitating.
///
/// Tiles launch directly here rather than going through the widget's deep-link
/// bridge, because the app is already frontmost.
struct HomeView: View {
    @EnvironmentObject private var library: DesignLibrary
    @EnvironmentObject private var router: ExternalAppRouter

    @State private var showingLibrary = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let design = library.activeDesign, let store = library.store {
                composition(design: design, store: store)
            } else {
                WelcomeView(hasStorageFailure: library.loadFailure != nil)
            }

            SettingsButton { showingLibrary = true }
        }
        .ignoresSafeArea()
        .statusBarHidden(library.activeDesign != nil)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showingLibrary) {
            LibraryView()
                .environmentObject(library)
                .environmentObject(router)
        }
        .alert("Launch failed", isPresented: Binding(
            get: { router.lastFailure != nil },
            set: { if !$0 { router.lastFailure = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(router.lastFailure ?? "")
        }
    }

    private func composition(design: DesignDocument, store: DesignStore) -> some View {
        let videoURL = store.previewVideoURL(for: design.id)
        let wallpaperURL = store.wallpaperURL(for: design.id)

        return LoopingCompositionView(
            screenSize: DeviceGeometry.screenPixelSize,
            viewport: CGRect(origin: .zero, size: DeviceGeometry.screenPixelSize),
            tiles: design.tiles,
            videoURL: FileManager.default.fileExists(atPath: videoURL.path) ? videoURL : nil,
            wallpaper: UIImage(contentsOfFile: wallpaperURL.path).map { Image(uiImage: $0) },
            scaleMode: .device
        ) { tile, side in
            Button {
                router.launch(appID: tile.appID)
            } label: {
                TileView(tile: tile, side: side)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(AppCatalog.app(id: tile.appID)?.name ?? tile.appID)")
        }
        .ignoresSafeArea()
    }
}

private struct SettingsButton: View {
    let action: () -> Void

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button(action: action) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
                }
                .accessibilityLabel("Designs and settings")
            }
        }
        .padding(.trailing, 20)
        .padding(.bottom, 34)
    }
}

private struct WelcomeView: View {
    let hasStorageFailure: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 46))
                .foregroundStyle(.white.opacity(0.85))
            Text("Motionary")
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
            Text(hasStorageFailure
                 ? "Storage is unavailable. Open settings for details."
                 : "Import a looping video, place your apps on it, and build an animated Home Screen widget.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 40)
            Text("Tap the gear to get started")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.45))
                .padding(.top, 6)
        }
    }
}
