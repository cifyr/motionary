import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import os

enum VideoImportError: Error, CustomStringConvertible {
    case noVideoTrack(url: URL)
    case unreadable(url: URL, underlying: Error)
    case tooFewFrames(found: Int, needed: Int, url: URL)
    case renderFailed(frameIndex: Int)

    var description: String {
        switch self {
        case .noVideoTrack(let url):
            "video: \(url.lastPathComponent) has no video track"
        case .unreadable(let url, let underlying):
            "video: could not read \(url.lastPathComponent): \(underlying)"
        case .tooFewFrames(let found, let needed, let url):
            "video: \(url.lastPathComponent) yielded \(found) frames but the loop needs \(needed)"
        case .renderFailed(let index):
            "video: could not rasterise frame \(index)"
        }
    }
}

/// Decodes a source clip into full-screen composed frames.
///
/// Every frame is aspect-filled to the calibrated screen so the composition,
/// the exported wallpaper, and the widget crop share one coordinate space.
struct VideoFrameExtractor {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "VideoImport")

    let url: URL
    let screenSize: CGSize

    init(url: URL, screenSize: CGSize = DeviceGeometry.screenPixelSize) {
        self.url = url
        self.screenSize = screenSize
    }

    struct Summary: Sendable {
        let frameCount: Int
        let nominalFrameRate: Float
        let duration: TimeInterval
        let naturalSize: CGSize
    }

    func summary() async throws -> Summary {
        let asset = AVURLAsset(url: url)
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw VideoImportError.noVideoTrack(url: url)
            }
            let (rate, duration, size) = try await track.load(.nominalFrameRate, .timeRange, .naturalSize)
            let seconds = duration.duration.seconds
            return Summary(
                frameCount: Int((Double(rate) * seconds).rounded()),
                nominalFrameRate: rate,
                duration: seconds,
                naturalSize: size
            )
        } catch let error as VideoImportError {
            throw error
        } catch {
            throw VideoImportError.unreadable(url: url, underlying: error)
        }
    }

    /// Decodes `count` consecutive frames starting at `startFrame`, each
    /// composed onto the calibrated screen and shifted by `verticalShift`
    /// pixels (negative moves the artwork up).
    func composedFrames(
        startFrame: Int,
        count: Int,
        verticalShift: CGFloat = 0,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [CGImage] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoImportError.noVideoTrack(url: url)
        }
        let nominalRate = try await track.load(.nominalFrameRate)
        let frameRate = nominalRate > 0 ? Double(nominalRate) : 30

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: screenSize.width * 2, height: screenSize.height * 2)

        let times = (0 ..< count).map { index in
            CMTime(seconds: Double(startFrame + index) / frameRate, preferredTimescale: 600)
        }

        var frames: [CGImage] = []
        frames.reserveCapacity(count)
        for (index, time) in times.enumerated() {
            do {
                let (image, _) = try await generator.image(at: time)
                frames.append(try compose(image, verticalShift: verticalShift, frameIndex: index))
            } catch let error as VideoImportError {
                throw error
            } catch {
                // A clip can end a frame or two before its declared duration;
                // stop cleanly rather than failing the whole import.
                Self.logger.error("frame \(index) at \(time.seconds)s failed: \(String(describing: error), privacy: .public)")
                break
            }
            progress?(Double(index + 1) / Double(count))
        }

        guard frames.count == count else {
            throw VideoImportError.tooFewFrames(found: frames.count, needed: count, url: url)
        }
        Self.logger.info("decoded \(frames.count) frames from \(self.url.lastPathComponent, privacy: .public)")
        return frames
    }

    /// Aspect-fill onto the screen, matching how iOS scales a Home Screen
    /// wallpaper, then apply the vertical alignment shift.
    private func compose(_ image: CGImage, verticalShift: CGFloat, frameIndex: Int) throws -> CGImage {
        let width = Int(screenSize.width)
        let height = Int(screenSize.height)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw VideoImportError.renderFailed(frameIndex: frameIndex)
        }

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: screenSize))
        context.interpolationQuality = .high

        let source = CGSize(width: image.width, height: image.height)
        let scale = max(screenSize.width / source.width, screenSize.height / source.height)
        let scaled = CGSize(width: source.width * scale, height: source.height * scale)
        // CGContext is bottom-left origin, so a shift that moves artwork up on
        // screen is a positive y offset here.
        let origin = CGPoint(
            x: (screenSize.width - scaled.width) / 2,
            y: (screenSize.height - scaled.height) / 2 + verticalShift
        )
        context.draw(image, in: CGRect(origin: origin, size: scaled))

        guard let composed = context.makeImage() else {
            throw VideoImportError.renderFailed(frameIndex: frameIndex)
        }
        return composed
    }
}
