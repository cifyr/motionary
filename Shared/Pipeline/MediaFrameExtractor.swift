import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

enum MediaImportError: Error, CustomStringConvertible {
    case unreadable(url: URL, underlying: Error?)
    case noVideoTrack(url: URL)
    case notAnimatable(url: URL, kind: String)
    case emptySource(url: URL)
    case tooFewFrames(found: Int, needed: Int, url: URL)
    case renderFailed(frameIndex: Int)

    var description: String {
        switch self {
        case .unreadable(let url, let underlying):
            "media: could not read \(url.lastPathComponent)\(underlying.map { ": \($0)" } ?? "")"
        case .noVideoTrack(let url):
            "media: \(url.lastPathComponent) has no video track"
        case .notAnimatable(let url, let kind):
            "media: \(url.lastPathComponent) is a \(kind); Motionary needs a video or an animated GIF"
        case .emptySource(let url):
            "media: \(url.lastPathComponent) contains no frames"
        case .tooFewFrames(let found, let needed, let url):
            "media: \(url.lastPathComponent) yielded \(found) frames but the loop needs \(needed)"
        case .renderFailed(let index):
            "media: could not rasterise frame \(index)"
        }
    }
}

/// What kind of file a design was imported from.
enum MediaKind: String, Codable, Sendable {
    case video
    case gif

    /// Decided by content rather than extension, because a GIF exported from
    /// Photos can arrive with any filename.
    static func detect(at url: URL) -> MediaKind {
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let magic = try? handle.read(upToCount: 6), magic.starts(with: Data("GIF8".utf8)) {
                return .gif
            }
        }
        return url.pathExtension.lowercased() == "gif" ? .gif : .video
    }
}

struct MediaSummary: Sendable {
    let kind: MediaKind
    let frameCount: Int
    let nominalFrameRate: Double
    let duration: TimeInterval
    let naturalSize: CGSize
}

/// How the imported media sits on the screen, on top of the aspect-fill that
/// every source gets by default.
///
/// A clip shot in portrait already fills the screen, but a square GIF does not,
/// so the size and position have to be adjustable before the frames are baked
/// into the font payload.
struct MediaTransform: Codable, Equatable, Sendable {
    /// Multiplier on the aspect-fill baseline.
    var scale: Double = 1
    /// Screen-pixel offset from centred.
    var offset: CGPoint = .zero
    /// Fills the screen with the media's edge colour instead of black.
    var fillsBackground: Bool = true

    static let identity = MediaTransform()

    var isIdentity: Bool { self == .identity }
}

/// Decodes a video or an animated GIF into full-screen composed frames.
///
/// Both sources go through one composition step so the wallpaper, the widget
/// crop, and the preview video all share a coordinate space regardless of what
/// was imported.
struct MediaFrameExtractor {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "MediaImport")

    let url: URL
    let screenSize: CGSize
    let transform: MediaTransform

    init(
        url: URL,
        screenSize: CGSize = DeviceGeometry.screenPixelSize,
        transform: MediaTransform = .identity
    ) {
        self.url = url
        self.screenSize = screenSize
        self.transform = transform
    }

    var kind: MediaKind { MediaKind.detect(at: url) }

    func summary() async throws -> MediaSummary {
        switch kind {
        case .video: try await videoSummary()
        case .gif: try gifSummary()
        }
    }

    /// One frame straight from the source, with no composition applied.
    ///
    /// The editor needs the raw pixels so it can apply the placement live while
    /// the user drags, rather than showing the last build's baked wallpaper.
    func posterFrame(at index: Int = 0) async throws -> CGImage {
        switch kind {
        case .video:
            guard let frame = try await videoFrames(startFrame: index, count: 1, progress: nil).first else {
                throw MediaImportError.emptySource(url: url)
            }
            return frame
        case .gif:
            guard let frame = try gifFrames(startFrame: index, count: 1, progress: nil).first else {
                throw MediaImportError.emptySource(url: url)
            }
            return frame
        }
    }

    /// Where the source lands on screen for a given transform, in screen
    /// pixels. Shared with the editor so its preview matches what a build
    /// bakes, rather than reimplementing the arithmetic and drifting from it.
    static func placement(
        sourceSize: CGSize,
        screenSize: CGSize,
        transform: MediaTransform
    ) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return .zero }
        let base = max(screenSize.width / sourceSize.width, screenSize.height / sourceSize.height)
        let scale = base * max(transform.scale, 0.05)
        let drawn = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        return CGRect(
            x: (screenSize.width - drawn.width) / 2 + transform.offset.x,
            y: (screenSize.height - drawn.height) / 2 + transform.offset.y,
            width: drawn.width,
            height: drawn.height
        )
    }

    /// How strongly the backdrop shows through behind a shrunken source.
    static let backdropOpacity: CGFloat = 0.45

    /// The aspect-fill rect used behind a shrunken source, in screen pixels.
    static func backdropPlacement(sourceSize: CGSize, screenSize: CGSize) -> CGRect {
        placement(
            sourceSize: sourceSize,
            screenSize: screenSize,
            transform: MediaTransform(scale: 1, offset: .zero, fillsBackground: false)
        )
    }

    /// Decodes `count` consecutive frames starting at `startFrame`, each
    /// composed onto the calibrated screen.
    func composedFrames(
        startFrame: Int,
        count: Int,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [CGImage] {
        let raw: [CGImage]
        switch kind {
        case .video:
            raw = try await videoFrames(startFrame: startFrame, count: count, progress: progress)
        case .gif:
            raw = try gifFrames(startFrame: startFrame, count: count, progress: progress)
        }

        guard raw.count == count else {
            throw MediaImportError.tooFewFrames(found: raw.count, needed: count, url: url)
        }
        return try raw.enumerated().map { try compose($0.element, frameIndex: $0.offset) }
    }

    // MARK: - Video

    private func videoSummary() async throws -> MediaSummary {
        let asset = AVURLAsset(url: url)
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw MediaImportError.noVideoTrack(url: url)
            }
            let (rate, range, size) = try await track.load(.nominalFrameRate, .timeRange, .naturalSize)
            let seconds = range.duration.seconds
            let fps = rate > 0 ? Double(rate) : 30
            return MediaSummary(
                kind: .video,
                frameCount: Int((fps * seconds).rounded()),
                nominalFrameRate: fps,
                duration: seconds,
                naturalSize: size
            )
        } catch let error as MediaImportError {
            throw error
        } catch {
            throw MediaImportError.unreadable(url: url, underlying: error)
        }
    }

    private func videoFrames(
        startFrame: Int,
        count: Int,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> [CGImage] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaImportError.noVideoTrack(url: url)
        }
        let rate = try await track.load(.nominalFrameRate)
        let fps = rate > 0 ? Double(rate) : 30

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: screenSize.width * 2, height: screenSize.height * 2)

        var frames: [CGImage] = []
        frames.reserveCapacity(count)
        for index in 0 ..< count {
            let time = CMTime(seconds: Double(startFrame + index) / fps, preferredTimescale: 600)
            do {
                let (image, _) = try await generator.image(at: time)
                frames.append(image)
            } catch {
                // A clip can end a frame or two before its declared duration;
                // stop cleanly rather than failing the whole import.
                Self.logger.error("frame \(index) at \(time.seconds)s failed: \(String(describing: error), privacy: .public)")
                break
            }
            progress?(Double(index + 1) / Double(count))
        }
        return frames
    }

    // MARK: - GIF

    private func imageSource() throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw MediaImportError.unreadable(url: url, underlying: nil)
        }
        return source
    }

    private func gifSummary() throws -> MediaSummary {
        let source = try imageSource()
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw MediaImportError.emptySource(url: url) }
        guard count > 1 else {
            throw MediaImportError.notAnimatable(url: url, kind: "still image")
        }

        let delays = frameDelays(in: source)
        let duration = delays.reduce(0, +)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Double ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Double ?? 0

        return MediaSummary(
            kind: .gif,
            frameCount: count,
            nominalFrameRate: duration > 0 ? Double(count) / duration : 10,
            duration: duration,
            naturalSize: CGSize(width: width, height: height)
        )
    }

    /// GIF frames carry individual delays, so the source is resampled onto the
    /// even timeline the rest of the pipeline assumes.
    private func gifFrames(
        startFrame: Int,
        count: Int,
        progress: (@Sendable (Double) -> Void)?
    ) throws -> [CGImage] {
        let source = try imageSource()
        let total = CGImageSourceGetCount(source)
        guard total > 0 else { throw MediaImportError.emptySource(url: url) }

        let delays = frameDelays(in: source)
        let duration = max(delays.reduce(0, +), 0.0001)
        let sourceFPS = Double(total) / duration

        // Cumulative start time of each frame, for mapping a sample time back
        // to whichever frame is on screen then.
        var starts: [TimeInterval] = []
        var running: TimeInterval = 0
        for delay in delays {
            starts.append(running)
            running += delay
        }

        var frames: [CGImage] = []
        frames.reserveCapacity(count)
        for index in 0 ..< count {
            let time = Double(startFrame + index) / sourceFPS
            let wrapped = duration > 0 ? time.truncatingRemainder(dividingBy: duration) : 0
            let frameIndex = starts.lastIndex { $0 <= wrapped } ?? 0
            guard let image = CGImageSourceCreateImageAtIndex(source, frameIndex, nil) else {
                throw MediaImportError.renderFailed(frameIndex: frameIndex)
            }
            frames.append(image)
            progress?(Double(index + 1) / Double(count))
        }
        Self.logger.info("decoded \(frames.count) GIF frames from \(total) source frames over \(duration)s")
        return frames
    }

    private func frameDelays(in source: CGImageSource) -> [TimeInterval] {
        (0 ..< CGImageSourceGetCount(source)).map { index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let unclamped = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
            let clamped = gif?[kCGImagePropertyGIFDelayTime] as? Double
            let delay = unclamped ?? clamped ?? 0.1
            // Browsers treat a zero or near-zero delay as 100ms; matching that
            // keeps a GIF's timing looking the way it does everywhere else.
            return delay < 0.011 ? 0.1 : delay
        }
    }

    // MARK: - Composition

    /// Aspect-fill onto the screen the way iOS scales a wallpaper, then apply
    /// the design's own scale and offset.
    private func compose(_ image: CGImage, frameIndex: Int) throws -> CGImage {
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
            throw MediaImportError.renderFailed(frameIndex: frameIndex)
        }

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: screenSize))
        context.interpolationQuality = .high

        let source = CGSize(width: image.width, height: image.height)
        let placed = Self.placement(sourceSize: source, screenSize: screenSize, transform: transform)

        /// CGContext is bottom-left origin; the shared placement is top-left.
        func flipped(_ rect: CGRect) -> CGRect {
            CGRect(
                x: rect.minX,
                y: screenSize.height - rect.maxY,
                width: rect.width,
                height: rect.height
            )
        }

        // A scaled-down source leaves the screen uncovered; a dim blow-up of
        // the same frame reads better behind it than a black band.
        if transform.fillsBackground, placed.width < screenSize.width || placed.height < screenSize.height {
            context.saveGState()
            context.setAlpha(Self.backdropOpacity)
            context.draw(image, in: flipped(Self.backdropPlacement(sourceSize: source, screenSize: screenSize)))
            context.restoreGState()
        }

        context.draw(image, in: flipped(placed))

        guard let composed = context.makeImage() else {
            throw MediaImportError.renderFailed(frameIndex: frameIndex)
        }
        return composed
    }
}
