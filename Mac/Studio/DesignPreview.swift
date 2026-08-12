import AVFoundation
import AppKit
import SwiftUI

/// A design's picture, and the phone-shaped card the library shows it in.
///
/// The library used to be a list of names and dates, which is the one thing a
/// design is not: it is a picture. A built design already has its whole
/// composition on disk as the wallpaper it exports, and an unbuilt one has the
/// clip it was made from — so there is always something truer to show than a
/// filename.
enum DesignThumbnail {
    /// Decoded pictures are megabytes each and the library shows a dozen at
    /// once, so they are kept rather than re-read on every redraw.
    ///
    /// Only ever touched from the main actor, which is where views draw; the
    /// annotation says so rather than reaching for a lock the cache does not
    /// need.
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSImage>()

    /// The best picture available for a design, or nil when there is none yet.
    ///
    /// Order matters: the wallpaper is what the design actually looks like on a
    /// Home Screen, so it beats the source clip even though both exist once a
    /// design has been built.
    static func image(for design: DesignDocument, store: DesignStore) -> NSImage? {
        let key = design.id.uuidString as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let found = wallpaper(for: design, store: store) ?? firstFrame(for: design, store: store)
        if let found { cache.setObject(found, forKey: key) }
        return found
    }

    /// Dropped when a design is rebuilt, or the library would go on showing the
    /// composition from before the change.
    static func forget(_ id: UUID) {
        cache.removeObject(forKey: id.uuidString as NSString)
    }

    static func forgetAll() { cache.removeAllObjects() }

    private static func wallpaper(for design: DesignDocument, store: DesignStore) -> NSImage? {
        let url = store.wallpaperURL(for: design.id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    /// The first frame of the clip the design was made from.
    ///
    /// Still images and GIFs load directly; anything else goes through
    /// AVFoundation, which also covers the GIF case on newer systems but costs
    /// a generator to set up.
    private static func firstFrame(for design: DesignDocument, store: DesignStore) -> NSImage? {
        let url = store.sourceVideoURL(for: design)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        if let direct = NSImage(contentsOf: url), direct.isValid, direct.size.width > 0 {
            return direct
        }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}

/// One design, drawn as the thing it becomes.
///
/// The card is a phone: the composition inside a rounded screen, with the
/// widget frame marked on it. That mark is the whole point of the product —
/// inside it animates, outside it is wallpaper — so the library is where it
/// should first be legible, not something you discover in the editor.
struct DesignCard: View {
    let design: DesignDocument
    let store: DesignStore
    let model: DeviceModel
    var isStarter = false
    var isSelected = false
    let onOpen: () -> Void

    @State private var hovering = false

    private var isBuilt: Bool {
        FileManager.default.fileExists(atPath: store.manifestURL(for: design.id).path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            phone
            caption
        }
        .padding(10)
        .background(cardBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isSelected ? StudioTheme.accent : StudioTheme.panelEdge,
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onOpen)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(design.name), \(design.tiles.count) apps\(isBuilt ? ", built" : "")")
        .accessibilityAddTraits(.isButton)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(hovering ? StudioTheme.headerFill : StudioTheme.panel)
    }

    // MARK: - The phone

    private var phone: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / model.screenPixelSize.width
            ZStack {
                if let picture = DesignThumbnail.image(for: design, store: store) {
                    Image(nsImage: picture)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    empty
                }

                // Where the widget sits. Dashed, because it is a boundary
                // rather than an object - the same language the canvas uses.
                RoundedRectangle(cornerRadius: model.widgetCornerRadius * scale, style: .continuous)
                    .strokeBorder(
                        StudioTheme.accent.opacity(hovering ? 0.95 : 0.65),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                    )
                    .frame(
                        width: model.widgetPixelSize.width * scale,
                        height: model.widgetPixelSize.height * scale
                    )
                    .position(
                        x: model.widgetRect.midX * scale,
                        y: model.widgetRect.midY * scale
                    )
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.black.opacity(0.55), lineWidth: 1)
            }
        }
        .aspectRatio(model.screenPixelSize.width / model.screenPixelSize.height, contentMode: .fit)
    }

    private var empty: some View {
        ZStack {
            StudioTheme.well
            VStack(spacing: 6) {
                Image(systemName: "film")
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(StudioTheme.textDim)
                Text("No clip yet")
                    .font(StudioTheme.monoSmall)
                    .foregroundStyle(StudioTheme.textDim)
            }
        }
    }

    // MARK: - The caption

    private var caption: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if isStarter {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 8.5))
                        .foregroundStyle(StudioTheme.accentInk)
                        .help("A starter design that ships with Studio")
                }
                Text(design.name)
                    .font(StudioTheme.bodyStrong)
                    .foregroundStyle(StudioTheme.textBright)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Counts and sizes in mono, names in the UI face. Everything this
            // project argues about is a measurement, and the type says which
            // numbers were measured rather than chosen.
            Text(metadata)
                .font(StudioTheme.monoSmall)
                .foregroundStyle(StudioTheme.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metadata: String {
        var parts = ["\(design.tiles.count) app\(design.tiles.count == 1 ? "" : "s")"]
        if !design.assets.isEmpty { parts.append("\(design.assets.count) pic") }
        parts.append(isBuilt ? "built" : "not built")
        return parts.joined(separator: " · ")
    }
}
