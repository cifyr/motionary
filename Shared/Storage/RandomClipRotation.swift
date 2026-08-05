import Foundation

/// Computes the automatic clip choice without mutable runtime state.
///
/// The widget and app are independently scheduled, so storing a random value
/// when one wakes would make them disagree. A deterministic shuffled sequence
/// gives both the same answer for the same design and time bucket, while still
/// avoiding an immediate repeat.
enum RandomClipRotation {
    static func choice(in manifest: BuildManifest, at date: Date) -> BuildManifest.ClipChoice? {
        let clips = manifest.clipSequence
        guard manifest.effectiveRandomClipSchedule != .off, clips.count > 1 else { return nil }

        let bucket = bucket(for: manifest, at: date)
        let selected = index(for: manifest.designID, bucket: bucket, count: clips.count)
        let previous = index(for: manifest.designID, bucket: bucket - 1, count: clips.count)
        // A random sequence is allowed to repeat mathematically, but seeing
        // the same clip on consecutive boundaries feels broken. Move this
        // bucket one or more places when its raw draw repeats the last one.
        let adjusted = selected == previous
            ? (selected + 1 + Int(hash(manifest.designID, bucket, salt: 1) % UInt64(clips.count - 1))) % clips.count
            : selected
        return clips[adjusted]
    }

    static func nextTransition(after date: Date, in manifest: BuildManifest) -> Date? {
        guard manifest.effectiveRandomClipSchedule != .off, manifest.clipSequence.count > 1 else { return nil }
        let interval = interval(for: manifest)
        let now = date.timeIntervalSince1970
        let next = (floor(now / interval) + 1) * interval
        return Date(timeIntervalSince1970: next)
    }

    static func interval(for manifest: BuildManifest) -> TimeInterval {
        switch manifest.effectiveRandomClipSchedule {
        case .off: return .infinity
        case .hour: return 60 * 60
        case .loopBoundary:
            let frames = ([manifest.loopFrameCount] + manifest.builtVariants.compactMap(\.loopFrameCount))
                .filter { $0 > 0 }
            let shared = frames.reduce(1) { partial, frame in
                let divisor = gcd(partial, frame)
                let candidate = partial / divisor * frame
                // A least common multiple can explode for unrelated clips.
                // Five minutes is still a meaningful shared boundary; beyond
                // that, the longest loop is a predictable and safe cadence.
                return candidate <= manifest.framesPerSecond * 300 ? candidate : max(partial, frame)
            }
            return Double(max(shared, 1)) / Double(max(manifest.framesPerSecond, 1))
        }
    }

    private static func bucket(for manifest: BuildManifest, at date: Date) -> Int64 {
        let interval = interval(for: manifest)
        guard interval.isFinite, interval > 0 else { return 0 }
        return Int64(floor(date.timeIntervalSince1970 / interval))
    }

    private static func index(for id: UUID, bucket: Int64, count: Int) -> Int {
        Int(hash(id, bucket, salt: 0) % UInt64(count))
    }

    private static func hash(_ id: UUID, _ bucket: Int64, salt: UInt64) -> UInt64 {
        var value: UInt64 = 1_469_598_103_934_665_603 ^ salt
        for byte in (id.uuidString + ":" + String(bucket)).utf8 {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
        return value
    }

    private static func gcd(_ lhs: Int, _ rhs: Int) -> Int {
        var a = abs(lhs)
        var b = abs(rhs)
        while b != 0 {
            (a, b) = (b, a % b)
        }
        return max(a, 1)
    }
}
