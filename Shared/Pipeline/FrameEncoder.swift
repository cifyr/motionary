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
            guard let data = Self.jpegData(cropped, quality: quality) else {
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
    static func bestPlan(sample: CGImage, crop: CGRect) -> QualityPlan? {
        var fallback: QualityPlan?
        for smoothness in [MotionSmoothness.standard, .balanced, .light] {
            let spec = TimerFontSpec(smoothness: smoothness)
            guard let quality = suggestedQuality(spec: spec, sample: sample, crop: crop, startingAt: 0.88),
                  let cropped = sample.cropping(to: crop),
                  let data = FrameEncoder.jpegData(cropped, quality: quality)
            else { continue }

            let plan = QualityPlan(
                smoothness: smoothness,
                quality: quality,
                estimatedBytes: PayloadBudget(
                    spec: spec, averageEncodedFrameBytes: data.count
                ).estimatedTotalBytes
            )
            if quality >= 0.55 { return plan }
            if fallback == nil || quality > fallback!.quality { fallback = plan }
        }
        return fallback
    }

    /// Largest JPEG quality that keeps a crop inside the recommended budget,
    /// or nil when the crop itself has to shrink instead.
    static func suggestedQuality(
        spec: TimerFontSpec,
        sample: CGImage,
        crop: CGRect,
        startingAt quality: Double = 0.62
    ) -> Double? {
        guard let cropped = sample.cropping(to: crop) else { return nil }
        var candidate = quality
        while candidate >= 0.3 {
            guard let data = FrameEncoder.jpegData(cropped, quality: candidate) else { return nil }
            let budget = PayloadBudget(spec: spec, averageEncodedFrameBytes: data.count)
            if budget.isWithinRecommended { return candidate }
            candidate -= 0.06
        }
        return nil
    }
}
