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

    /// Which card each lane shows.
    ///
    /// Cards take contiguous runs of lanes across the whole stack, so the same
    /// shape covers both jobs this lab has. Four cards over 32 lanes holds each
    /// one for half a second, which is slow enough to photograph. One card per
    /// lane is a real design: every frame distinct, every frame decoded, which
    /// is the arrangement whose cost has to be measured rather than guessed.
    struct Phasing: Equatable, Sendable {
        let laneCount: Int
        let cardCount: Int
        /// The long side of a card in pixels. The cost being measured is per
        /// frame and the cap that bites first is on pixel area, so this is the
        /// other axis of the sweep.
        let cardPixels: Int
        /// How far apart the lanes are phased, in milliseconds. Zero means the
        /// frame duration, which is what the shipped engine uses.
        ///
        /// A whole second is the interesting setting: the mask substitutes on
        /// the timer's seconds digits, so second-scale offsets are what decides
        /// whether a loop can be longer than the mask's own period.
        let spacingMilliseconds: Int
        /// The mask font under test.
        let maskFont: String

        init(
            laneCount: Int = 32,
            cardCount: Int = 4,
            cardPixels: Int = 240,
            spacingMilliseconds: Int = 0,
            maskFont: String = FontSetGenerator.blinkFontResourceName
        ) {
            self.laneCount = laneCount
            self.cardCount = cardCount
            self.cardPixels = cardPixels
            self.spacingMilliseconds = spacingMilliseconds
            self.maskFont = maskFont
        }

        var spacing: TimeInterval {
            spacingMilliseconds > 0 ? Double(spacingMilliseconds) / 1000 : frameDuration
        }

        var framesPerSecond: Int { laneCount / 2 }
        var frameDuration: TimeInterval { 1 / Double(framesPerSecond) }
        var lanesPerHalf: Int { laneCount / 2 }
        /// Zero when the cards do not divide the stack evenly, which the view
        /// treats as a lab that cannot be drawn rather than drawing a stack
        /// with silent gaps in it.
        var lanesPerCard: Int {
            guard cardCount > 0, laneCount % cardCount == 0 else { return 0 }
            return laneCount / cardCount
        }
        var isValid: Bool { lanesPerCard > 0 }

        /// How long one card stays up, and how long the whole rotation takes.
        var cardDuration: TimeInterval { Double(lanesPerCard) * frameDuration }
        var cycleDuration: TimeInterval { Double(laneCount) * frameDuration }

        func lanes(card: Int) -> Range<Int> {
            let start = card * lanesPerCard
            return start ..< (start + lanesPerCard)
        }

        func card(forLane lane: Int) -> Int {
            guard lanesPerCard > 0 else { return 0 }
            return lane / lanesPerCard
        }

        /// Lanes belonging to one half of the stack, because a mask isolates a
        /// single lane only within a half and the second half is gated as a
        /// group.
        func lanes(half: Int) -> Range<Int> {
            (half * lanesPerHalf) ..< ((half + 1) * lanesPerHalf)
        }

        /// The offset that makes this lane's mask the opaque one, negated the
        /// same way the composition negates it.
        func blinkOffset(lane: Int) -> TimeInterval {
            Double(-lane) * spacing
        }
    }

    private static let phasingKey = "maskLabPhasing"

    /// Persisted, because the extension is a different process from the app
    /// that was launched with the arguments.
    static var phasing: Phasing {
        get {
            let defaults = UserDefaults(suiteName: DesignStore.appGroupIdentifier)
            guard let raw = defaults?.string(forKey: phasingKey) else { return Phasing() }
            let fields = raw.split(separator: ",")
            let parts = fields.compactMap { Int($0) }
            guard parts.count >= 3 else { return Phasing() }
            return Phasing(
                laneCount: parts[0],
                cardCount: parts[1],
                cardPixels: parts[2],
                spacingMilliseconds: parts.count > 3 ? parts[3] : 0,
                maskFont: fields.count > 4 ? String(fields[4]) : FontSetGenerator.blinkFontResourceName
            )
        }
        set {
            UserDefaults(suiteName: DesignStore.appGroupIdentifier)?.set(
                "\(newValue.laneCount),\(newValue.cardCount),\(newValue.cardPixels),"
                    + "\(newValue.spacingMilliseconds),\(newValue.maskFont)",
                forKey: phasingKey
            )
            logger.info("mask lab \(newValue.cardCount) cards at \(newValue.cardPixels)px over \(newValue.laneCount) lanes")
        }
    }

    /// `-MotionaryMaskLabStack <lanes>,<cards>,<pixels>`, so a sweep can be
    /// driven from a script rather than by rebuilding for each point.
    static func launchPhasing(in arguments: [String]) -> Phasing? {
        guard let flag = arguments.firstIndex(of: "-MotionaryMaskLabStack"),
              arguments.index(after: flag) < arguments.endIndex
        else { return nil }
        let fields = arguments[arguments.index(after: flag)].split(separator: ",")
        let parts = fields.compactMap { Int($0) }
        guard parts.count >= 3 else { return nil }
        let phasing = Phasing(
            laneCount: parts[0],
            cardCount: parts[1],
            cardPixels: parts[2],
            spacingMilliseconds: parts.count > 3 ? parts[3] : 0,
            maskFont: fields.count > 4 ? String(fields[4]) : FontSetGenerator.blinkFontResourceName
        )
        return phasing.isValid ? phasing : nil
    }

    // MARK: - Frames

    /// A 3:2 card, sized in real pixels rather than points: the caps that bite
    /// are on pixel area and on the extension's own footprint, and a measurement
    /// taken in points would be off by the screen scale on one device and not
    /// another.
    static func cardPixelSize(_ phasing: Phasing) -> CGSize {
        CGSize(width: phasing.cardPixels, height: (phasing.cardPixels * 2) / 3)
    }

    private static let folderName = "masklab"

    /// Four fixed colours while there are four cards, so a photograph can be
    /// read without a key; a hue ramp beyond that, where the point is the cost
    /// rather than the picture.
    private static let namedColours: [UIColor] = [
        UIColor(red: 0.85, green: 0.16, blue: 0.15, alpha: 1),
        UIColor(red: 0.13, green: 0.55, blue: 0.86, alpha: 1),
        UIColor(red: 0.18, green: 0.68, blue: 0.31, alpha: 1),
        UIColor(red: 0.95, green: 0.72, blue: 0.09, alpha: 1),
    ]

    static func colour(card: Int, of count: Int = 4) -> UIColor {
        guard count > namedColours.count else { return namedColours[card % namedColours.count] }
        return UIColor(
            hue: CGFloat(card % count) / CGFloat(count),
            saturation: 0.85,
            brightness: 0.9,
            alpha: 1
        )
    }

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
    static func stageCards(_ phasing: Phasing) -> [String] {
        var notes: [String] = []
        // Left over from a wider sweep, and a card the stack no longer asks for
        // still costs nothing - but one it does ask for and finds stale is a
        // measurement of the wrong thing.
        try? FileManager.default.removeItem(at: folder())
        for card in 0 ..< phasing.cardCount {
            do {
                let url = try cardURL(card)
                let data = try cardJPEG(card: card, phasing: phasing)
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
    private static func cardJPEG(card: Int, phasing: Phasing) throws -> Data {
        let cardPixelSize = cardPixelSize(phasing)
        // Scale 1, so a card is the number of pixels it was asked for rather
        // than three times that on a phone and once on a Mac.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: cardPixelSize, format: format)
        let image = renderer.image { context in
            colour(card: card, of: phasing.cardCount).setFill()
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
    static func loadCards(_ phasing: Phasing) -> (images: [UIImage], notes: [String]) {
        var images: [UIImage] = []
        var notes: [String] = []
        var bytes = 0
        for card in 0 ..< phasing.cardCount {
            do {
                let url = try cardURL(card)
                let data = try Data(contentsOf: url)
                guard let image = UIImage(data: data) else {
                    notes.append("card \(card): \(data.count)B would not decode")
                    continue
                }
                bytes += data.count
                images.append(image)
            } catch {
                notes.append("card \(card): \(error)")
            }
        }
        let side = images.first.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "-"
        // One line rather than one per card: at 64 cards the per-card list is
        // longer than the log keeps, and it pushes out the render it explains.
        notes.insert(
            "\(images.count)/\(phasing.cardCount) cards, \(side), \(bytes / 1024)KB on disk",
            at: 0
        )
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
