import CoreGraphics
import Foundation

/// Which animation a design draws with.
///
/// A property of the design rather than a build flag, because the two are not
/// interchangeable and both have to keep working: the lane fonts are the only
/// route to a loop longer than two seconds, and the runtime frames are the only
/// route that does not need a Mac.
enum AnimationSource: String, Codable, CaseIterable, Sendable {
    /// Generated OT-SVG colour-glyph fonts compiled into the extension's
    /// bundle. 30-second cycle, up to 32fps, needs Motionary Studio.
    case laneFonts
    /// Pictures written into the app group at runtime, revealed by the bundled
    /// blink font. Two-second cycle, nothing to compile, made on the phone.
    case runtimeImages

    var title: String {
        switch self {
        case .laneFonts: "Lane fonts"
        case .runtimeImages: "Runtime frames"
        }
    }
}

/// Where a runtime-frame design's pictures live and how to read them back.
///
/// Written into the build manifest so the widget needs nothing but the manifest
/// to know what to load. Every number here was needed by a render that got one
/// of them wrong: a frame count that disagreed with the files on disk drew a
/// gap, and a rect that was assumed full-screen put the animation in the wrong
/// place on a pre-cropped picture.
struct RuntimeFrameSequence: Codable, Equatable, Sendable {
    enum Layout: String, Codable, CaseIterable, Sendable {
        /// One file per frame, decoded on its own.
        case separate
        /// Every frame in one tall strip, decoded once and shown through a
        /// moving window. Same pixel count; one allocation instead of N.
        case sheet

        var title: String {
            switch self {
            case .separate: "Separate frames"
            case .sheet: "Sprite sheet"
            }
        }
    }

    var framesPerSecond: Int
    var layout: Layout
    /// Pixel size of one frame, which is also the crop it was cut from.
    var frameSize: CGSize
    /// Screen-space rect the frames cover, so the widget can place them the
    /// same way it places a pre-cropped backdrop.
    var rect: CGRect
    /// How many times the source loop plays inside the two-second cycle.
    var sourceRepeats: Int
    /// The playback speed that made those repeats land on the cycle exactly.
    var speed: Double
    /// Total bytes of frame files written, for the report.
    var totalFrameBytes: Int

    var frameCount: Int { BlinkCycle.frameCount(framesPerSecond: framesPerSecond) }

    /// How long one repetition of the source lasts on screen.
    var loopDuration: TimeInterval { BlinkCycle.cycleDuration / Double(max(1, sourceRepeats)) }

    var summary: String {
        String(
            format: "%d frames at %dfps, %dx%d, %@, %.1fMB",
            frameCount,
            framesPerSecond,
            Int(frameSize.width),
            Int(frameSize.height),
            layout.rawValue,
            Double(totalFrameBytes) / 1_048_576
        )
    }

    // MARK: - Sheet limits

    /// Longest side a sheet may reach.
    ///
    /// Not arbitrary and not about memory: a `CGImage` past this does not draw.
    /// The GPU texture limit on current devices is 16384 in each direction, and
    /// a strip that exceeds it comes back blank with nothing anywhere saying
    /// why - which is the failure mode this whole project keeps hitting.
    static let maximumSheetSide = 16_384

    /// A sheet is decoded whole, in one allocation, inside a process that is
    /// killed a little above 45MB. 24 megapixels is 96MB at 4 bytes a pixel,
    /// already past it - so this is the point beyond which a sheet cannot
    /// possibly help, not a point at which it is comfortable.
    static let maximumSheetPixels = 24_000_000

    /// Whether a strip of this shape can be drawn at all.
    ///
    /// At full widget resolution it cannot: 1074x1632 frames stack past 16384
    /// after ten of them, so a 64-frame full-resolution design has no sheet
    /// form. That settles the sheet-versus-separate question on stronger
    /// grounds than a footprint comparison, and it is why the writer refuses
    /// rather than producing a blank widget.
    static func sheetIsDrawable(frameCount: Int, frameSize: CGSize) -> Bool {
        let height = Int(frameSize.height.rounded()) * frameCount
        let width = Int(frameSize.width.rounded())
        return height <= maximumSheetSide
            && width <= maximumSheetSide
            && width * height <= maximumSheetPixels
    }

    /// Why a sheet was refused, in words the import can show.
    static func sheetRefusal(frameCount: Int, frameSize: CGSize) -> String? {
        guard !sheetIsDrawable(frameCount: frameCount, frameSize: frameSize) else { return nil }
        let height = Int(frameSize.height.rounded()) * frameCount
        let width = Int(frameSize.width.rounded())
        return "a \(frameCount)-frame sheet of \(Int(frameSize.width))x\(Int(frameSize.height)) frames "
            + "is \(width)x\(height), past the \(maximumSheetSide)px a picture can be drawn at"
    }
}

extension DesignStore {
    /// Where a runtime-frame design's pictures live: a plain folder in the app
    /// group, written by the phone and never compiled into anything.
    func framesFolder(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("Frames", isDirectory: true)
    }

    func frameURL(for id: UUID, index: Int) -> URL {
        framesFolder(for: id).appendingPathComponent(String(format: "frame-%03d.jpg", index))
    }

    func frameSheetURL(for id: UUID) -> URL {
        framesFolder(for: id).appendingPathComponent("sheet.jpg")
    }

    /// Empties the frame folder before a rewrite, so frames from a longer
    /// previous loop cannot linger and be drawn in slots that no longer exist.
    func clearFrames(for id: UUID) throws {
        let folder = framesFolder(for: id)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: Self.directoryAttributes
        )
    }

    /// How many frame files are actually there. The widget reports this against
    /// what the manifest claims, because a short folder draws a gap in the
    /// animation and looks like a broken mask.
    func frameFileCount(for id: UUID) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: framesFolder(for: id).path)) ?? []
        return names.filter { $0.hasPrefix("frame-") }.count
    }
}
