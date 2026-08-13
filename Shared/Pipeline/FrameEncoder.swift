import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum FrameEncoderError: Error, CustomStringConvertible {
    case cropOutOfBounds(crop: CGRect, imageSize: CGSize)
    case cropEmpty
    case jpegEncodeFailed(frameIndex: Int, cropSize: CGSize)
    case pngEncodeFailed

    var description: String {
        switch self {
        case .cropOutOfBounds(let crop, let size):
            "encode: crop \(crop.debugDescription) falls outside a \(size.debugDescription) frame"
        case .cropEmpty:
            "encode: the animated crop is empty; nothing would move"
        case .jpegEncodeFailed(let index, let size):
            "encode: JPEG encode failed for frame \(index) at \(size.debugDescription)"
        case .pngEncodeFailed:
            "encode: PNG encode failed for the wallpaper export"
        }
    }
}

/// Crops composed frames and encodes them for embedding in the glyph payload.
struct FrameEncoder {
    let crop: CGRect
    let quality: Double
    /// When present, apply the measured Home Screen edge correction to animated
    /// pixels too. This matters when the motion crop reaches the widget's top or
    /// bottom band: those pixels replace the corrected static backdrop.
    var widgetRect: CGRect? = nil

    /// Base64 JPEG for every frame, ready to inline as a data URI.
    func encodedFrames(_ frames: [CGImage]) throws -> [String] {
        try frameData(frames).map { $0.base64EncodedString() }
    }

    /// The same frames as files rather than as text.
    ///
    /// A design built as pictures writes these straight out; one built as fonts
    /// base64s them into glyphs. Same crop, same tint, same edge correction -
    /// the two bodies of a design have to be the same picture, or switching
    /// between them would move the scene against the wallpaper behind it.
    func frameData(_ frames: [CGImage]) throws -> [Data] {
        guard crop.width >= 1, crop.height >= 1 else { throw FrameEncoderError.cropEmpty }

        return try frames.enumerated().map { index, frame in
            let bounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
            guard bounds.contains(crop) else {
                throw FrameEncoderError.cropOutOfBounds(
                    crop: crop,
                    imageSize: CGSize(width: frame.width, height: frame.height)
                )
            }
            guard let cropped = frame.cropping(to: crop) else {
                throw FrameEncoderError.cropOutOfBounds(
                    crop: crop,
                    imageSize: CGSize(width: frame.width, height: frame.height)
                )
            }
            // The animated region is most of what the widget shows, so it needs
            // the same colour match as the backdrop under it - otherwise the two
            // agree with each other and both disagree with the wallpaper.
            var prepared = WidgetTint.applied(to: cropped)
            if let widgetRect, EdgeCompensation.overlaps(crop, widgetRect: widgetRect) {
                prepared = EdgeCompensation.applied(
                    to: prepared,
                    originY: Int(crop.minY),
                    widgetRect: widgetRect
                )
            }
            guard let data = Self.jpegData(prepared, quality: quality) else {
                throw FrameEncoderError.jpegEncodeFailed(frameIndex: index, cropSize: crop.size)
            }
            return data
        }
    }

    /// One frame's moving pixels, and where in the crop they belong.
    ///
    /// The rect is normalised to the animated crop, so it survives the frames
    /// being shrunk and the widget being a different size from the screen they
    /// were cut for.
    struct Sprite: Sendable {
        let data: Data
        let rect: CGRect
    }

    /// Every frame reduced to the box its own opaque pixels occupy.
    ///
    /// A cut-out clip is a small figure over nothing. Encoded whole, each frame
    /// carries the crop's full area - and every frame's is the same still
    /// scene, so the byte budget goes on 320 copies of one gradient and the
    /// frames have to be shrunk to fit, which is what made them soft. Encoded
    /// as its own bounding box, a frame is a few kilobytes at full resolution.
    ///
    /// PNG rather than JPEG: the alpha edge is the whole point, and JPEG has no
    /// alpha at all.
    ///
    /// A frame with nothing opaque in it - the figure has swung off the crop -
    /// gets a one-pixel transparent sprite rather than nothing, so the lane it
    /// belongs to still exists and the stack keeps its shape.
    func sprites(_ frames: [CGImage], shrink: Double = 1) throws -> [Sprite] {
        guard crop.width >= 1, crop.height >= 1 else { throw FrameEncoderError.cropEmpty }

        return try frames.map { frame in
            let bounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
            guard bounds.contains(crop), let cropped = frame.cropping(to: crop) else {
                throw FrameEncoderError.cropOutOfBounds(
                    crop: crop, imageSize: CGSize(width: frame.width, height: frame.height)
                )
            }
            var prepared = WidgetTint.applied(to: cropped)
            if let widgetRect, EdgeCompensation.overlaps(crop, widgetRect: widgetRect) {
                prepared = EdgeCompensation.applied(
                    to: prepared, originY: Int(crop.minY), widgetRect: widgetRect
                )
            }
            guard let box = Self.opaqueBounds(of: prepared), let sprite = prepared.cropping(to: box) else {
                return Sprite(
                    data: try Self.pngData(Self.blankPixel()),
                    rect: CGRect(x: 0, y: 0, width: 0.001, height: 0.001)
                )
            }
            let scaled = shrink < 1 ? (Self.resized(sprite, scale: shrink) ?? sprite) : sprite
            return Sprite(
                data: try Self.pngData(scaled),
                rect: CGRect(
                    x: box.minX / crop.width,
                    y: box.minY / crop.height,
                    width: box.width / crop.width,
                    height: box.height / crop.height
                )
            )
        }
    }

    /// Every frame as an opaque patch big enough to hide the lanes still
    /// showing beneath it.
    ///
    /// The stack works by occlusion. The mask is solid for a whole second, so
    /// about `window` lanes are unmasked at once and the topmost is simply the
    /// one that covers the others - which a full-crop opaque frame does for
    /// free. Cut down to its own contents and made transparent, a frame hides
    /// nothing and every still-solid lane shows at once, which is a trail of
    /// figures rather than one.
    ///
    /// So the cut is to the union of what the neighbouring lanes drew, and the
    /// patch is opaque: small enough to be worth cutting - about a tenth of the
    /// crop on a clip whose figure moves the way Spidey's does - and still able
    /// to cover them. Symmetric rather than backwards-only because the solid
    /// run straddles the ends of the stack at the wrap, where the oldest lane
    /// is the one on top.
    func occludingPatches(
        _ frames: [CGImage],
        plate: CGImage,
        window: Int,
        shrink: Double = 1
    ) throws -> [Sprite] {
        guard crop.width >= 1, crop.height >= 1 else { throw FrameEncoderError.cropEmpty }
        guard let ground = plate.cropping(to: crop) else {
            throw FrameEncoderError.cropOutOfBounds(
                crop: crop, imageSize: CGSize(width: plate.width, height: plate.height)
            )
        }
        let backdrop = WidgetTint.applied(to: ground)

        let prepared = try frames.map { frame -> CGImage in
            guard let cropped = frame.cropping(to: crop) else {
                throw FrameEncoderError.cropOutOfBounds(
                    crop: crop, imageSize: CGSize(width: frame.width, height: frame.height)
                )
            }
            // Tint only. The edge correction is applied to the finished patch
            // instead: it draws through an opaque context, so running it here
            // would flatten the transparency this needs to find the box - which
            // it silently did the moment the crop grew to touch the widget's
            // edge bands, and every patch came back the size of the crop.
            return WidgetTint.applied(to: cropped)
        }
        let boxes = prepared.map { Self.opaqueBounds(of: $0) }
        let count = prepared.count

        return try prepared.indices.map { index in
            // The lanes that can be solid while this one is on top, wrapped,
            // because the stack is a cycle.
            var union: CGRect?
            for step in -window ... window {
                let neighbour = ((index + step) % count + count) % count
                guard let box = boxes[neighbour] else { continue }
                union = union.map { $0.union(box) } ?? box
            }
            let full = CGRect(x: 0, y: 0, width: crop.width, height: crop.height)
            let box = (union ?? CGRect(x: 0, y: 0, width: 1, height: 1)).intersection(full)
            guard !box.isEmpty, let patch = prepared[index].cropping(to: box),
                  let ground = backdrop.cropping(to: box)
            else { throw FrameEncoderError.cropEmpty }

            var flattened = Self.over(patch, ground: ground)
            // Now that it is opaque, and against its own place in the widget
            // rather than the crop's origin.
            if let widgetRect, EdgeCompensation.overlaps(crop, widgetRect: widgetRect) {
                flattened = EdgeCompensation.applied(
                    to: flattened,
                    originY: Int(crop.minY + box.minY),
                    widgetRect: widgetRect
                )
            }
            let scaled = shrink < 1 ? (Self.resized(flattened, scale: shrink) ?? flattened) : flattened
            guard let data = Self.jpegData(scaled, quality: quality) else {
                throw FrameEncoderError.jpegEncodeFailed(frameIndex: index, cropSize: box.size)
            }
            return Sprite(
                data: data,
                rect: CGRect(
                    x: box.minX / crop.width, y: box.minY / crop.height,
                    width: box.width / crop.width, height: box.height / crop.height
                )
            )
        }
    }

    /// A transparent patch on its piece of the still scene, opaque afterwards.
    static func over(_ image: CGImage, ground: CGImage) -> CGImage {
        guard let context = CGContext(
            data: nil, width: ground.width, height: ground.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }
        let bounds = CGRect(x: 0, y: 0, width: ground.width, height: ground.height)
        context.draw(ground, in: bounds)
        context.draw(image, in: bounds)
        return context.makeImage() ?? image
    }

    /// The box the image's non-transparent pixels sit in, or nil when there are
    /// none.
    ///
    /// Scanned at a stride and then padded, because the exact edge does not
    /// matter and a full scan of 320 frames at 1.26M pixels each is 400 million
    /// reads for a box that is then rounded anyway.
    static func opaqueBounds(of image: CGImage, stride: Int = 2, pad: Int = 3) -> CGRect? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in Swift.stride(from: 0, to: height, by: stride) {
            let row = y * width * 4
            for x in Swift.stride(from: 0, to: width, by: stride) where pixels[row + x * 4 + 3] > 8 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        let x0 = max(0, minX - pad), y0 = max(0, minY - pad)
        let x1 = min(width, maxX + pad + 1), y1 = min(height, maxY + pad + 1)
        // CGImage is top-left origin here because the context was drawn into in
        // image order, which is the order the rect is wanted in.
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    private static func blankPixel() -> CGImage {
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        return context!.makeImage()!
    }

    static func resized(_ image: CGImage, scale: Double) -> CGImage? {
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    static func pngData(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { throw FrameEncoderError.pngEncodeFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FrameEncoderError.pngEncodeFailed }
        return output as Data
    }

    /// The backdrop, in whichever of PNG and JPEG comes out smaller, with the
    /// extension that names what it is.
    ///
    /// Only the backdrop gets the choice: it is one still, where the animation
    /// is `lanes x 15` copies of a frame and has to stay lossy to fit at all.
    ///
    /// A flat or synthetic background encodes exactly and about seven times
    /// smaller as PNG - measured on a grey gradient, 8.5KB against 60KB - while
    /// a photograph does not, so the smaller file is the lossless one exactly
    /// when lossless is affordable. It matters beyond the bytes: JPEG at 0.95
    /// was leaving the backdrop about two levels off the wallpaper it has to be
    /// continuous with, and up to thirteen in places, and quantisation eats the
    /// edge correction, whose whole shape is a step of up to 79 units across
    /// two or three rows.
    static func backdropData(_ image: CGImage, quality: Double) throws -> (data: Data, ext: String) {
        let png = try? pngData(image)
        let jpeg = jpegData(image, quality: quality)
        switch (png, jpeg) {
        case let (png?, jpeg?):
            return png.count <= jpeg.count ? (png, "png") : (jpeg, "jpg")
        case let (png?, nil):
            return (png, "png")
        case let (nil, jpeg?):
            return (jpeg, "jpg")
        case (nil, nil):
            throw FrameEncoderError.pngEncodeFailed
        }
    }
}

/// Predicts what a build will cost before it runs.
///
/// Each unique frame is embedded once per glyph selection, so the payload is
/// `laneCount x 15` copies of one encoded frame, not one copy per frame. That
/// multiplier is why a modest crop change moves tens of megabytes.
/// Settings chosen to look as good as the memory ceiling allows.
struct QualityPlan: Sendable, Equatable {
    let smoothness: MotionSmoothness
    let quality: Double
    let estimatedBytes: Int

    var summary: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(estimatedBytes), countStyle: .file)
        return "\(smoothness.framesPerSecond) fps · quality \(Int(quality * 100))% · \(size)"
    }
}

struct PayloadBudget {
    /// Measured on an iPhone 17 Pro rather than guessed. A jetsam report caught
    /// the Onewheel build peaking at 43.3MB and drawing correctly, while a
    /// 74.8MB Motionary set peaked at 46.7MB and had its render dropped — which
    /// is what a black widget looks like from outside. 45MB sits just above the
    /// figure known to work.
    static let recommendedMaximumBytes = 45 * 1024 * 1024
    static let hardMaximumBytes = 120 * 1024 * 1024

    let spec: TimerFontSpec
    let averageEncodedFrameBytes: Int

    var glyphSelections: Int { spec.laneCount * spec.framesPerLane }

    /// gzip recovers little from an already-compressed JPEG, so the base64
    /// expansion is the dominant term.
    var estimatedTotalBytes: Int {
        Int(Double(glyphSelections) * Double(averageEncodedFrameBytes) * 1.37) + spec.laneCount * 8_000
    }

    var isWithinRecommended: Bool { estimatedTotalBytes <= Self.recommendedMaximumBytes }
    var exceedsHardLimit: Bool { estimatedTotalBytes > Self.hardMaximumBytes }

    var formattedEstimate: String {
        ByteCountFormatter.string(fromByteCount: Int64(estimatedTotalBytes), countStyle: .file)
    }

    /// The best-looking settings that still fit the measured budget.
    ///
    /// Smoothness is tried from smoothest downwards and the first level that
    /// keeps JPEG quality respectable wins. Below that threshold, trading
    /// frames per second for image quality reads better on a wallpaper than
    /// the reverse — a crisp 16fps loop beats a mushy 32fps one.
    static func bestPlan(samples: [CGImage], crop: CGRect) -> QualityPlan? {
        guard !samples.isEmpty else { return nil }
        var fallback: QualityPlan?
        for smoothness in [MotionSmoothness.standard, .balanced, .light] {
            let spec = TimerFontSpec(smoothness: smoothness)
            guard let quality = suggestedQuality(
                spec: spec, samples: samples, crop: crop, startingAt: 0.88
            ) else { continue }

            let plan = QualityPlan(
                smoothness: smoothness,
                quality: quality,
                estimatedBytes: PayloadBudget(
                    spec: spec,
                    averageEncodedFrameBytes: averageBytes(of: samples, crop: crop, quality: quality)
                ).estimatedTotalBytes
            )
            if quality >= 0.55 { return plan }
            if fallback == nil || quality > fallback!.quality { fallback = plan }
        }
        return fallback
    }

    /// Averaged over several frames rather than taken from one.
    ///
    /// A single frame is a poor estimate: if the one sampled happens to be
    /// busier than the rest, every setting looks more expensive than it is and
    /// the planner gives away frame rate it did not need to.
    private static func averageBytes(of samples: [CGImage], crop: CGRect, quality: Double) -> Int {
        var total = 0
        var counted = 0
        for sample in samples {
            guard let cropped = sample.cropping(to: crop),
                  let data = FrameEncoder.jpegData(cropped, quality: quality)
            else { continue }
            total += data.count
            counted += 1
        }
        return counted > 0 ? total / counted : 0
    }

    /// Largest JPEG quality that keeps a crop inside the recommended budget,
    /// or nil when the crop itself has to shrink instead.
    static func suggestedQuality(
        spec: TimerFontSpec,
        samples: [CGImage],
        crop: CGRect,
        startingAt quality: Double = 0.62
    ) -> Double? {
        guard !samples.isEmpty else { return nil }
        var candidate = quality
        while candidate >= 0.3 {
            let average = averageBytes(of: samples, crop: crop, quality: candidate)
            guard average > 0 else { return nil }
            if PayloadBudget(spec: spec, averageEncodedFrameBytes: average).isWithinRecommended {
                return candidate
            }
            candidate -= 0.06
        }
        return nil
    }
}
