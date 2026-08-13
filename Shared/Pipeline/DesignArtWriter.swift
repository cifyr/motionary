import CoreGraphics
import Foundation
import os

/// Writes the still pictures a design needs beside its animation: the
/// wallpaper, the wallpaper without tiles, and the widget's own backdrop.
///
/// Shared rather than copied, because a design has two possible bodies now -
/// glyphs in fonts, or frames as pictures - and the stills have to come out
/// byte-identical either way. The backdrop is colour-matched and edge-corrected
/// against measurements of real hardware; a second implementation of that would
/// drift from this one silently, and the symptom is a seam between the widget
/// and the wallpaper that nobody can attribute.
struct DesignArtWriter {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "DesignArt")

    let store: DesignStore
    var tileArtwork: WallpaperComposer.ArtworkProvider = { _ in nil }
    var assetArtwork: WallpaperComposer.AssetProvider = { _ in nil }

    /// Padded, because the system hands over 1078x1645px where the cut frame is
    /// 1074x1632 and starts 2px further right: cropping to the exact frame
    /// would leave unpainted pixels on all four sides. The padding has to cover
    /// `DeviceGeometry.renderedWidgetRect`, which a test asserts.
    static let backdropPadding: CGFloat = 24

    static func backdropRect(widgetRect: CGRect) -> CGRect {
        widgetRect
            .insetBy(dx: -backdropPadding, dy: -backdropPadding)
            .intersection(CGRect(origin: .zero, size: DeviceGeometry.screenPixelSize))
            .integral
    }

    /// Returns the rect the widget backdrop covers, or nil when none was baked.
    @discardableResult
    func write(
        design: DesignDocument,
        poster: CGImage,
        variantID: UUID? = nil
    ) async throws -> CGRect? {
        if variantID == nil {
            // The wallpaper carries the tiles; the widget backdrop below does
            // not. The widget draws its own live tiles, and only inside its
            // frame - so a tile crossing that edge is completed by the
            // wallpaper behind it, and baking them into the backdrop too would
            // draw those halves twice.
            let withTiles = await WallpaperComposer.compose(
                frame: poster,
                tiles: design.tiles,
                assets: design.assets,
                screenSize: DeviceGeometry.screenPixelSize,
                artwork: tileArtwork,
                assetArtwork: assetArtwork
            )
            try FrameEncoder.pngData(withTiles)
                .write(to: store.wallpaperURL(for: design.id), options: DesignStore.writingOptions)

            // The same picture without the tiles, for the phone to bake its own
            // onto: which app occupies a slot is chosen there, and a wallpaper
            // baked with the authored occupants would continue the wrong icon
            // past the widget's edge after a swap. Assets stay baked - they are
            // not slot-dependent, and their source files never ship.
            let plain = await WallpaperComposer.compose(
                frame: poster,
                tiles: [],
                assets: design.assets,
                screenSize: DeviceGeometry.screenPixelSize,
                assetArtwork: assetArtwork
            )
            try FrameEncoder.pngData(plain)
                .write(to: store.plainWallpaperURL(for: design.id), options: DesignStore.writingOptions)
        }

        // The full screen costs about 12.6MB decompressed and the widget only
        // ever shows its own frame. On this phone the extension peaked at
        // 46.7MB against a working reference of 43.3MB and its render was
        // dropped, which is what a black widget looks like from outside.
        let rect = Self.backdropRect(widgetRect: design.widgetRect)
        guard !rect.isNull, let cropped = poster.cropping(to: rect) else { return nil }

        // The wallpaper above keeps the picture as it is; only the widget's own
        // copy gets the edge line taken out of it, because the line is only
        // drawn where the widget is. Colour first, then the edge: the edge
        // profile was measured against the wallpaper as displayed, so it
        // belongs on content that already matches the wallpaper's colour.
        let corrected = EdgeCompensation.applied(
            to: WidgetTint.applied(to: cropped),
            originY: Int(rect.minY),
            widgetRect: design.widgetRect
        )
        // Lossless whenever lossless is also the smaller file, which a flat
        // background is. The quality below only decides the other case: 0.95
        // rather than 0.9 because the correction above is a step of up to 79
        // units across two or three rows and quantisation smooths exactly that
        // - measured, 0.9 gave back 2-6 units of the line, 0.95 under 3.
        let (data, ext) = try FrameEncoder.backdropData(corrected, quality: 0.95)
        try store.writeWidgetBackdrop(data, ext: ext, for: design.id, variant: variantID)
        Self.logger.info("""
        widget backdrop \(Int(rect.width))x\(Int(rect.height)), \(data.count) bytes
        """)
        return rect
    }
}
