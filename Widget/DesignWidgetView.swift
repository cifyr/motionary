import CoreText
import SwiftUI
import WidgetKit
import os

/// Renders the current design, preferring one you imported and falling back to
/// the design bundled with the app.
///
/// The fallback is the point. A widget that draws nothing looks identical to a
/// widget that is broken, and this one spent a long night black. If an imported
/// design cannot be drawn — not built yet, fonts that will not register — the
/// bundled one still can, so the Home Screen always shows something real and
/// the report says which was used.
struct DesignWidgetView: View {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "Widget")

    @Environment(\.widgetFamily) private var family
    let entry: DesignEntry

    var body: some View {
        content
            .background {
                GeometryReader { geometry in
                    Color.clear.onAppear { Self.lastRenderedSize = geometry.size }
                }
            }
            .widgetAccentable(false)
            .containerBackground(for: .widget) { Color.black }
    }

    /// Where a renderable design came from, and everything needed to draw it.
    private struct Source {
        let manifest: BuildManifest
        let backdrop: Image?
        let fontsUsable: Bool
        let origin: String
        let scope: String
        let name: String
    }

    @ViewBuilder
    private var content: some View {
        if EdgeLab.isEnabled {
            // Filled to the widget's own bounds rather than cut from the screen
            // composition: the question it answers is what the system does to
            // those bounds.
            EdgeLabView()
        } else if FontLab.isEnabled, let lab = lab() {
            lab
        } else if let source = bundled() {
            let _ = record(source: source)
            // The phone's slot choices, applied at render time: the occupant is
            // live SwiftUI over the frozen animation, so it is the one part of
            // a design that can change without a rebuild.
            let authored = Dictionary(
                source.manifest.placedTiles.map { ($0.id, $0.appID) },
                uniquingKeysWith: { first, _ in first }
            )
            CompositionView(
                manifest: source.manifest,
                // Spots the phone filled included: an added tile is live
                // SwiftUI over the frozen animation exactly like an authored
                // one, so the widget draws both without a rebuild.
                tiles: SlotChoices.effectiveTiles(manifest: source.manifest),
                // The rendered rect, not the cut frame: only the viewport's
                // origin positions content, and the system's origin is 2px left
                // of the frame a design is cut to.
                viewport: DeviceGeometry.renderedWidgetRect,
                wallpaper: source.backdrop,
                wallpaperRect: source.manifest.backdropRect,
                isAnimated: source.fontsUsable,
                assets: source.manifest.placedAssets,
                assetImage: { asset in
                    PrebuiltDesign.pictureURL(assetID: asset.id)
                        .flatMap {
                            ImageLoader.load(
                                at: $0,
                                maxPixelSize: Int(max(asset.size.width, asset.size.height))
                            )
                        }
                        .map { Image(decorative: $0, scale: 1) }
                }
            ) { tile, side in
                // Through the app rather than straight to the destination: a
                // Link from an extension to a third-party scheme is
                // unreliable, so the app takes the tap and forwards it.
                Link(destination: LaunchLink.url(for: tile)) {
                    TileView(
                        tile: tile,
                        side: side,
                        iconImage: SlotArtwork.image(
                            for: tile,
                            designID: source.manifest.designID,
                            authoredAppID: authored[tile.id] ?? tile.appID,
                            side: side
                        )
                    )
                }
            }
        } else {
            let _ = record(source: nil)
            PlaceholderView(message: "Open Motionary and add a clip.")
        }
    }

    /// The font lab, when it is switched on and there is an imported design
    /// whose lane fonts it can try to deliver nine different ways.
    private func lab() -> FontLabView? {
        guard let store = try? DesignStore() else { return nil }
        // Logged step by step: the widget came back black with not even a
        // label drawn, which means the extension stopped somewhere before the
        // view existed. A black rectangle cannot say where.
        WidgetRenderLog.append("lab  enter \(MemoryFootprint.megabytes)MB")
        let importedManifest = ActiveDesign.resolve(in: store)
            .flatMap { try? store.loadManifest(id: $0.id) }
        guard let manifest = importedManifest ?? PrebuiltDesign.manifest else {
            WidgetRenderLog.append("lab  no manifest")
            return nil
        }

        WidgetRenderLog.append("lab  manifest \(MemoryFootprint.megabytes)MB")
        let outcomes = FontLab.run(manifest: manifest, store: store)
        WidgetRenderLog.append("""
        lab  prepared \(outcomes.filter(\.isDrawable).count)/\(outcomes.count) \
        \(MemoryFootprint.megabytes)MB
        """)
        FontLab.record(outcomes, store: store)
        return FontLabView(
            manifest: manifest,
            outcomes: outcomes,
            // Same viewport as the real render, so the lab is not a second
            // renderer positioned differently from the one it stands in for.
            viewport: DeviceGeometry.renderedWidgetRect
        )
    }

    /// The design compiled into this build, and the only kind there is.
    ///
    /// There used to be a second source: a design generated on the phone into
    /// the app group, which this preferred. That feature is gone - a design has
    /// to be in the extension's bundle at install time to animate at all - but
    /// preferring it outlived it, so a phone that had ever generated one showed
    /// that leftover forever: not the design the app was showing, not animated
    /// because its fonts were never bundled, and deaf to switching, because the
    /// selected id never matched anything in the store and the fallback always
    /// returned the same stale design.
    private func bundled() -> Source? {
        // Whichever the app last chose, so the Home Screen follows a swipe.
        guard let entry = PrebuiltDesign.selected(), var manifest = entry.manifest else { return nil }
        var backdropURL = entry.backdropURL
        var name = entry.name
        // The phone's chosen clip variant, applied by swapping which font
        // family and backdrop the same composition draws. Guarded on the
        // fonts actually being bundled: a stale choice must degrade to the
        // primary clip, not to a widget whose lanes resolve and draw nothing.
        if let variant = VariantChoice.resolved(in: manifest),
           PrebuiltDesign.fontsAreBundled(familyBase: variant.fontFamilyBase) {
            manifest.fontFamilyBase = variant.fontFamilyBase
            manifest.totalFontBytes = variant.totalFontBytes
            // Variants keep their own lengths; a manifest from before that
            // carries nil and the design's loop stands in.
            manifest.loopFrameCount = variant.loopFrameCount ?? manifest.loopFrameCount
            backdropURL = entry.backdropURL(variant: variant.id) ?? backdropURL
            name = "\(entry.name) (\(variant.name))"
        }
        let fonts = PrebuiltDesign.fontReport(for: manifest)
        guard let url = backdropURL ?? entry.wallpaperURL else { return nil }
        let longest = manifest.backdropRect.map { Int(max($0.width, $0.height)) }
            ?? Int(max(manifest.screenSize.width, manifest.screenSize.height))
        return Source(
            manifest: manifest,
            backdrop: ImageLoader.load(at: url, maxPixelSize: longest).map { Image(decorative: $0, scale: 1) },
            fontsUsable: fonts.resolvable == fonts.requested,
            origin: "bundled",
            scope: "UIAppFonts",
            name: name
        )
    }

    @discardableResult
    private func record(source: Source?) -> Bool {
        var status = WidgetStatus()
        status.family = "\(family)"
        status.familyRawValue = family.rawValue
        status.renderedSize = Self.lastRenderedSize
        status.containerReachable = (try? DesignStore()) != nil

        let blinkName = FontSetGenerator.blinkFontResourceName
        status.blinkFontResolved = CTFontCopyPostScriptName(
            CTFontCreateWithName(blinkName as CFString, 12, nil)
        ) as String == blinkName

        if let source {
            status.outcome = source.backdrop == nil
                ? "ok, but the picture did not load"
                : (source.fontsUsable ? "ok" : "ok, but still - the fonts would not draw")
            status.manifestFound = true
            status.designName = "\(source.name) (\(source.origin))"
            status.designID = source.manifest.designID.uuidString
            status.designSize = WidgetSizeOption.fullScreen.title
            status.storePath = "\(source.origin) via \(source.scope)"
            status.buildGeneration = source.manifest.buildGeneration
            status.laneCount = source.manifest.laneCount
            status.framesPerSecond = source.manifest.framesPerSecond
            status.loopFrameCount = source.manifest.loopFrameCount
            status.animationCrop = source.manifest.animationCrop
            status.widgetRect = DeviceGeometry.widgetRect
            status.screenSize = source.manifest.screenSize
            status.manifestFontBytes = source.manifest.totalFontBytes
            status.lanesRequested = source.manifest.laneCount
            status.lanesResolvable = source.fontsUsable ? source.manifest.laneCount : 0
            status.lanesRegistered = status.lanesResolvable
            status.backdropExists = source.backdrop != nil
        } else {
            status.outcome = "nothing to draw: no imported design and no bundled one"
        }

        status.memoryFootprintMB = MemoryFootprint.megabytes
        WidgetStatusLog.write(status)
        WidgetRenderLog.append("""
        \(status.succeeded ? "OK  " : "FAIL") \(entry.isPreview ? "GALLERY" : "PLACED ") \
        \(source?.origin ?? "none")/\(source?.scope ?? "-") \
        anim=\(source?.fontsUsable == true) \
        \(Int((Self.lastRenderedSize.width * DeviceGeometry.scale).rounded()))x\
        \(Int((Self.lastRenderedSize.height * DeviceGeometry.scale).rounded()))px \
        \(status.memoryFootprintMB)MB
        """)
        return true
    }

    /// The real size the system gave the widget, captured while drawing.
    nonisolated(unsafe) static var lastRenderedSize: CGSize = .zero
}

private struct PlaceholderView: View {
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.yellow)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .unredacted()
    }
}
