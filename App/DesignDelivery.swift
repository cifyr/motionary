import Foundation
import os

/// Takes delivery of a design package on the phone.
///
/// A design used to reach a phone only by being compiled into the widget
/// extension and installed, because its frames were fonts. Frames that are
/// pictures need no install, so this is the whole receiving end: unpack into
/// the app group, make it the active design, and ask the widget to redraw.
///
/// Two ways in, and they are the same code. A file opened from Files, AirDrop
/// or a share sheet arrives as a URL; anything dropped into the app's own
/// Documents - which is what a script or a Mac with a cable can reach - is
/// picked up on the next launch.
enum DesignDelivery {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "Delivery")

    /// Where an unattended delivery is looked for. `Documents` rather than
    /// `Inbox`: the app's own Documents is the one directory on the phone that
    /// `devicectl` will both list and write, which is what makes a delivery
    /// testable without somebody tapping through a share sheet.
    static var dropBox: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    enum Outcome: Equatable, Sendable {
        case delivered(name: String, frames: Int)
        case nothingToDo
        case failed(String)

        var message: String {
            switch self {
            case .delivered(let name, let frames): "Delivered \(name), \(frames) frames"
            case .nothingToDo: "No package waiting"
            case .failed(let reason): reason
            }
        }
    }

    @discardableResult
    static func receive(at url: URL) -> Outcome {
        do {
            let store = try DesignStore()
            // Security-scoped because a file picked in Files belongs to another
            // process's sandbox; harmless for one this app wrote itself.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let data = try Data(contentsOf: url)
            let design = try DesignPackage.read(data, into: store)
            let frames = store.frameCount(for: design.id)
            // Selected on arrival: a design that was just sent to a phone is
            // the one the person who sent it wants to look at.
            ActiveDesign.identifier = design.id
            WidgetCenterBridge.reloadAll()
            logger.info("delivered \(design.name, privacy: .public), \(frames) frames")
            return .delivered(name: design.name, frames: frames)
        } catch {
            logger.error("delivery failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            return .failed("\(error)")
        }
    }

    /// Takes anything waiting in the drop box, newest first, and removes each
    /// package once it is in. Left in place, a package would be re-delivered on
    /// every launch and would keep overwriting whatever was chosen since.
    @discardableResult
    static func receiveWaiting() -> [Outcome] {
        guard let dropBox else { return [] }
        let waiting = ((try? FileManager.default.contentsOfDirectory(
            at: dropBox,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? [])
            .filter { $0.pathExtension == DesignPackage.fileExtension }
            .sorted { left, right in
                let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return leftDate < rightDate
            }

        return waiting.map { url in
            let outcome = receive(at: url)
            if case .delivered = outcome {
                try? FileManager.default.removeItem(at: url)
            }
            return outcome
        }
    }
}
