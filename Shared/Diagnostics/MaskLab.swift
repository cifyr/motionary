import Foundation
import UIKit
import os

/// Asks the one question an App Store build depends on: does a live timer mask
/// gate a picture that was not in the bundle at install time?
///
/// The engine animates by masking stacked `Text` in generated fonts, and a font
/// only draws in a widget if it shipped inside the extension - which is the
/// whole reason a design is compiled on a Mac. Two things are separately
/// established: `Image(uiImage:)` built from runtime `Data` survives the
/// archive, and a live mask gates a composited subtree. Nobody has put them
/// together. If a live mask gates a picture read from the app group, a design
/// can be delivered to an installed app instead of built into one, and the Mac
/// stops being a compiler.
///
/// The bands are drawn with the production masking, not a simplification of it,
/// so a pass means the engine works rather than that masking does.
enum MaskLab {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "MaskLab")
    private static let flagKey = "maskLabEnabled"

    static var isEnabled: Bool {
        get { UserDefaults(suiteName: DesignStore.appGroupIdentifier)?.bool(forKey: flagKey) ?? false }
        set {
            UserDefaults(suiteName: DesignStore.appGroupIdentifier)?.set(newValue, forKey: flagKey)
            logger.info("mask lab \(newValue ? "on" : "off")")
        }
    }

    static func launchOverride(in arguments: [String]) -> Bool? {
        if arguments.contains("-MotionaryMaskLabOn") { return true }
        if arguments.contains("-MotionaryMaskLabOff") { return false }
        return nil
    }

    /// Which band the picture comes from, so a black widget can be told apart
    /// from a mask that gates nothing.
    enum Band: String, CaseIterable, Sendable {
        /// The finding under test: a JPEG written to the app group after
        /// install, decoded here, masked live.
        case image
        /// The same masks over a flat colour. Separates "the mask does not gate
        /// pictures" from "the mask does not gate anything but text".
        case colour
        /// The control. Text under a live mask is what the shipping engine
        /// does, so if this band is dead the lab is wrong, not the finding.
        case text

        var label: String {
            switch self {
            case .image: "IMAGE (runtime)"
            case .colour: "COLOUR"
            case .text: "TEXT (control)"
            }
        }
    }

    // MARK: - Phase

    /// Which lanes each card is masked into.
    ///
    /// The mask isolates one lane only within a half of the stack, so the stack
    /// is halved and the second half gated as a group - the same arrangement
    /// `CompositionView` uses. Each card takes a contiguous run of lanes in
    /// both halves, which is what turns a 1/16s flicker into a step slow enough
    /// to photograph: with 32 lanes and 4 cards, a card holds for a quarter
    /// second and the four of them cycle twice in the two-second lane wrap.
    struct Phasing: Equatable, Sendable {
        let laneCount: Int
        let cardCount: Int

        init(laneCount: Int = 32, cardCount: Int = 4) {
            self.laneCount = laneCount
            self.cardCount = cardCount
        }

        var framesPerSecond: Int { laneCount / 2 }
        var frameDuration: TimeInterval { 1 / Double(framesPerSecond) }
        var lanesPerHalf: Int { laneCount / 2 }
        /// Zero when the cards do not divide the half evenly, which the view
        /// treats as a lab that cannot be drawn rather than drawing a stack
        /// with silent gaps in it.
        var lanesPerCard: Int { lanesPerHalf % cardCount == 0 ? lanesPerHalf / cardCount : 0 }
        var isValid: Bool { lanesPerCard > 0 }

        /// How long one card stays up, and how long the whole rotation takes.
        var cardDuration: TimeInterval { Double(lanesPerCard) * frameDuration }
        var cycleDuration: TimeInterval { Double(laneCount) * frameDuration }

        func lanes(card: Int, half: Int) -> Range<Int> {
            let start = half * lanesPerHalf + card * lanesPerCard
            return start ..< (start + lanesPerCard)
        }

        /// The offset that makes this lane's mask the opaque one, negated the
        /// same way the composition negates it.
        func blinkOffset(lane: Int) -> TimeInterval {
            Double(-lane) * frameDuration
        }
    }

    static let phasing = Phasing()

    // MARK: - Frames

    /// Small on purpose. The archive is capped on pixel area per image and the
    /// extension is killed a little above 45MB, and this stack holds one
    /// decoded copy per lane rather than per card.
    static let cardPixelSize = CGSize(width: 240, height: 160)

    private static let folderName = "masklab"
    private static let colours: [UIColor] = [
        UIColor(red: 0.85, green: 0.16, blue: 0.15, alpha: 1),
        UIColor(red: 0.13, green: 0.55, blue: 0.86, alpha: 1),
        UIColor(red: 0.18, green: 0.68, blue: 0.31, alpha: 1),
        UIColor(red: 0.95, green: 0.72, blue: 0.09, alpha: 1),
    ]

    static func colour(card: Int) -> UIColor { colours[card % colours.count] }

    private static func folder() throws -> URL {
        let root = try DesignStore().root.deletingLastPathComponent()
        let folder = root.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: DesignStore.directoryAttributes
        )
        return folder
    }

    static func cardURL(_ card: Int) throws -> URL {
        try folder().appendingPathComponent("card-\(card).jpg")
    }

    /// Writes the cards the widget will read.
    ///
    /// Drawn here and now rather than shipped as assets: a picture that came
    /// out of the bundle would answer a question nobody is asking. Rewritten on
    /// every launch so a stale card cannot stand in for a working one.
    @discardableResult
    static func stageCards(_ phasing: Phasing = phasing) -> [String] {
        var notes: [String] = []
        for card in 0 ..< phasing.cardCount {
            do {
                let url = try cardURL(card)
                let data = try cardJPEG(card: card)
                try data.write(to: url, options: DesignStore.writingOptions)
                notes.append("card \(card): \(data.count / 1024)KB at \(url.lastPathComponent)")
            } catch {
                notes.append("card \(card): \(error)")
                logger.error("could not stage card \(card): \(String(describing: error), privacy: .public)")
            }
        }
        return notes
    }

    private enum CardError: Error, CustomStringConvertible {
        case encodeFailed(card: Int)

        var description: String {
            switch self {
            case .encodeFailed(let card): "card \(card) would not JPEG-encode"
            }
        }
    }

    /// A big digit on a flat colour: legible in a photograph of a Home Screen,
    /// which is how this gets read.
    private static func cardJPEG(card: Int) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: cardPixelSize)
        let image = renderer.image { context in
            colour(card: card).setFill()
            context.fill(CGRect(origin: .zero, size: cardPixelSize))

            let text = "\(card + 1)"
            let font = UIFont.systemFont(ofSize: cardPixelSize.height * 0.7, weight: .heavy)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(
                at: CGPoint(
                    x: (cardPixelSize.width - size.width) / 2,
                    y: (cardPixelSize.height - size.height) / 2
                ),
                withAttributes: attributes
            )
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            throw CardError.encodeFailed(card: card)
        }
        return data
    }

    /// Decoded once per render and shared by every lane that shows it, because
    /// the stack references one card from `lanesPerCard` places and decoding it
    /// that many times is memory the extension does not have.
    static func loadCards(_ phasing: Phasing = phasing) -> (images: [UIImage], notes: [String]) {
        var images: [UIImage] = []
        var notes: [String] = []
        for card in 0 ..< phasing.cardCount {
            do {
                let url = try cardURL(card)
                let data = try Data(contentsOf: url)
                guard let image = UIImage(data: data) else {
                    notes.append("card \(card): \(data.count)B would not decode")
                    continue
                }
                images.append(image)
                notes.append("card \(card): \(data.count / 1024)KB \(Int(image.size.width))x\(Int(image.size.height))")
            } catch {
                notes.append("card \(card): \(error)")
            }
        }
        return (images, notes)
    }

    // MARK: - Reporting

    private static let reportFilename = "mask-lab.txt"

    private static func reportURL(in store: DesignStore) -> URL {
        store.root.deletingLastPathComponent().appendingPathComponent(reportFilename)
    }

    static func record(_ notes: [String], store: DesignStore) {
        let text = (["recorded \(Date().formatted(date: .omitted, time: .standard))"] + notes)
            .joined(separator: "\n")
        do {
            try Data(text.utf8).write(to: reportURL(in: store), options: DesignStore.writingOptions)
        } catch {
            logger.error("could not record the lab: \(String(describing: error), privacy: .public)")
        }
    }

    static func report(store: DesignStore) -> String? {
        (try? Data(contentsOf: reportURL(in: store))).flatMap { String(data: $0, encoding: .utf8) }
    }
}
