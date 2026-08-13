import CoreGraphics
import Foundation

/// Where one sprite belongs inside the animated crop, as fractions of it.
///
/// A cut-out design ships each frame cropped to the pixels that are actually in
/// it, which is a few kilobytes rather than a full copy of the still scene - so
/// each frame has to record where it goes. Normalised rather than in pixels so
/// it survives the sprite being shrunk to fit the archive, and so the widget can
/// place it at whatever size it is drawn at rather than the screen the frames
/// were cut for.
struct FrameRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(rect: CGRect) {
        x = rect.minX
        y = rect.minY
        width = rect.width
        height = rect.height
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
