import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Custom icon artwork, imported once and reusable on any tile.
///
/// Kept outside the project tree and outside any one design: skins are the
/// user's, not a design's, and re-picking the same eleven files for every clip
/// would be the whole feature's cost paid repeatedly.
struct SkinLibrary {
    /// Big enough for the largest tile on a 3x screen without resampling, and
    /// small enough that a widget can decode several inside its memory cap.
    static let renderedSide = 512

    let root: URL

    init() throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        root = support
            .appendingPathComponent("Motionary", isDirectory: true)
            .appendingPathComponent("Skins", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    struct Skin: Identifiable, Hashable, Sendable {
        /// Filename inside the library, which is what a tile stores.
        let id: String
        let url: URL
    }

    func all() -> [Skin] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return files
            .filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { Skin(id: $0.lastPathComponent, url: $0) }
    }

    func url(for name: String) -> URL { root.appendingPathComponent(name) }

    /// Imports artwork, trimming its border and squaring it up.
    ///
    /// Generated icon art usually arrives padded - the eleven this was built
    /// for are 1024x1536 with the icon floating in white - so importing them
    /// as-is would letterbox every tile. Returns the names it added.
    @discardableResult
    func importing(_ urls: [URL]) throws -> [String] {
        var added: [String] = []
        for url in urls {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { continue }

            // Keyed before trimming: a green screen is a border colour the
            // trimmer would only cut from the edges, leaving it filling every
            // gap inside the artwork.
            let keyed = Self.keyingOut(image) ?? image
            let trimmed = Self.trimmed(keyed) ?? keyed
            let squared = Self.squared(trimmed) ?? trimmed
            guard let scaled = Self.scaled(squared, to: Self.renderedSide) else { continue }

            let name = Self.name(for: url)
            try Self.writePNG(scaled, to: self.url(for: name))
            added.append(name)
        }
        return added
    }

    /// Imports artwork already in memory, under a name the caller chooses.
    ///
    /// The same keying, trimming, squaring and scaling a file import gets, so
    /// a cell cut out of a sprite sheet ends up indistinguishable from the
    /// same icon imported on its own.
    func importing(_ image: CGImage, named name: String) throws {
        let keyed = Self.keyingOut(image) ?? image
        let trimmed = Self.trimmed(keyed) ?? keyed
        let squared = Self.squared(trimmed) ?? trimmed
        guard let scaled = Self.scaled(squared, to: Self.renderedSide) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try Self.writePNG(scaled, to: url(for: name))
    }

    /// A stable, readable filename, so importing the same file twice replaces
    /// rather than accumulates.
    private static func name(for url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let safe = base.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
        return "\(safe.prefix(48).lowercased()).png"
    }

    // MARK: - Image work

    private static func pixels(_ image: CGImage) -> (data: [UInt8], width: Int, height: Int)? {
        let width = image.width
        let height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (data, width, height)
    }

    /// Makes a saturated background colour transparent, wherever it appears.
    ///
    /// Icon art often arrives on a green screen. Trimming alone would cut it
    /// from the edges and leave it filling the gaps inside the artwork, so it
    /// has to be keyed out instead.
    ///
    /// Only saturated backgrounds are keyed. White and parchment paddings are
    /// the trimmer's job, and keying those would eat any pale part of the
    /// picture - the corner colour decides which case this is.
    /// Import-time keying for skins, which get no inspector of their own.
    ///
    /// The work is `ChromaKey`'s. This keyer used to read its key from pixel 0
    /// and measure across R, G and B together, which meant a lit backdrop only
    /// keyed where it matched that one corner, and every antialiased edge
    /// stayed opaque with a green rim. See Shared/Pipeline/ChromaKey.swift.
    static func keyingOut(_ image: CGImage) -> CGImage? {
        ChromaKey.apply(to: image, settings: .default)
    }

    /// Crops away a uniform border, whether it is transparent or a flat colour.
    ///
    /// The corner pixel is taken as the border colour rather than assuming
    /// white or assuming alpha, because generated art comes both ways and
    /// guessing wrong either trims the artwork or trims nothing.
    static func trimmed(_ image: CGImage, tolerance: Int = 18) -> CGImage? {
        guard let (data, width, height) = pixels(image), width > 2, height > 2 else { return nil }

        func sample(_ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
            let index = (y * width + x) * 4
            return (Int(data[index]), Int(data[index + 1]), Int(data[index + 2]), Int(data[index + 3]))
        }
        let border = sample(0, 0)

        func isBorder(_ x: Int, _ y: Int) -> Bool {
            let pixel = sample(x, y)
            // Anything transparent counts as border whatever its colour, since
            // premultiplied transparent pixels carry meaningless components.
            if pixel.3 < 12, border.3 < 12 { return true }
            return abs(pixel.0 - border.0) <= tolerance
                && abs(pixel.1 - border.1) <= tolerance
                && abs(pixel.2 - border.2) <= tolerance
                && abs(pixel.3 - border.3) <= tolerance
        }

        var top = 0
        var bottom = height - 1
        var left = 0
        var right = width - 1
        while top < bottom, (0 ..< width).allSatisfy({ isBorder($0, top) }) { top += 1 }
        while bottom > top, (0 ..< width).allSatisfy({ isBorder($0, bottom) }) { bottom -= 1 }
        while left < right, (top ... bottom).allSatisfy({ isBorder(left, $0) }) { left += 1 }
        while right > left, (top ... bottom).allSatisfy({ isBorder(right, $0) }) { right -= 1 }

        let rect = CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        guard rect.width > 8, rect.height > 8, rect.width < CGFloat(width) || rect.height < CGFloat(height) else {
            return nil
        }
        return image.cropping(to: rect)
    }

    /// Pads the short side so the artwork is square and keeps its proportions.
    /// A tile is square, so a non-square skin would otherwise be stretched.
    static func squared(_ image: CGImage) -> CGImage? {
        let side = max(image.width, image.height)
        guard image.width != image.height else { return image }
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(
            x: (side - image.width) / 2,
            y: (side - image.height) / 2,
            width: image.width,
            height: image.height
        ))
        return context.makeImage()
    }

    static func scaled(_ image: CGImage, to side: Int) -> CGImage? {
        guard image.width != side || image.height != side else { return image }
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try (data as Data).write(to: url, options: .atomic)
    }
}
