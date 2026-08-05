import Foundation

/// A frame-exact program for the timer font table. Every segment is a whole
/// clip; the solver neither trims a clip nor repeats one across a boundary.
enum ClipProgram {
    struct Clip: Equatable, Sendable {
        let id: UUID?
        let frameCount: Int
    }

    struct Segment: Codable, Equatable, Sendable {
        let clipID: UUID?
        let startFrame: Int
        let frameCount: Int
    }

    static func shuffled(clips: [Clip], totalFrames: Int, seed: UUID) -> [Segment]? {
        let usable = clips.filter { $0.frameCount > 0 && $0.frameCount <= totalFrames }
        guard usable.count > 1, usable.count < Int.bitWidth, totalFrames > 0 else { return nil }
        let fullMask = (1 << usable.count) - 1
        struct State: Hashable { let remaining: Int; let previous: Int; let first: Int; let bag: Int }
        var failed = Set<State>()

        func order(remaining: Int, bag: Int) -> [Int] {
            usable.indices.sorted {
                rank(seed: seed, remaining: remaining, bag: bag, index: $0)
                    < rank(seed: seed, remaining: remaining, bag: bag, index: $1)
            }
        }

        func solve(remaining: Int, previous: Int, first: Int, bag: Int) -> [Int]? {
            if remaining == 0 { return [] }
            let available = bag == 0 ? fullMask : bag
            let state = State(remaining: remaining, previous: previous, first: first, bag: available)
            guard !failed.contains(state) else { return nil }
            for index in order(remaining: remaining, bag: available) {
                let bit = 1 << index
                guard available & bit != 0, index != previous,
                      usable[index].frameCount <= remaining,
                      !(usable[index].frameCount == remaining && index == first)
                else { continue }
                if let tail = solve(
                    remaining: remaining - usable[index].frameCount,
                    previous: index,
                    first: first < 0 ? index : first,
                    bag: available & ~bit
                ) { return [index] + tail }
            }
            failed.insert(state)
            return nil
        }

        guard let indices = solve(remaining: totalFrames, previous: -1, first: -1, bag: fullMask),
              indices.count > 1 else { return nil }
        var cursor = 0
        return indices.map { index in
            defer { cursor += usable[index].frameCount }
            return Segment(clipID: usable[index].id, startFrame: cursor, frameCount: usable[index].frameCount)
        }
    }

    private static func rank(seed: UUID, remaining: Int, bag: Int, index: Int) -> UInt64 {
        var value: UInt64 = 1_469_598_103_934_665_603
        for byte in "\(seed.uuidString):\(remaining):\(bag):\(index)".utf8 {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
        return value
    }
}
