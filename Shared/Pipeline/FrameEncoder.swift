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

    /// Base64 JPEG for every frame, ready to inline as a data URI.
    func encodedFrames(_ frames: [CGImage]) throws -> [String] {
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
            guard let data = Self.jpegData(WidgetTint.applied(to: cropped), quality: quality) else {
                throw FrameEncoderError.jpegEncodeFailed(frameIndex: index, cropSize: crop.size)
            }
            return data.base64EncodedString()
        }
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
