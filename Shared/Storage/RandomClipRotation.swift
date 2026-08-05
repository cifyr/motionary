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

        switch manifest.effectiveRandomClipSchedule {
        case .off:
            return nil
        case .hour:
            return clips[hourlyChoiceIndex(in: manifest, bucket: hourBucket(at: date))]
        case .loopBoundary:
            return loopRotation(in: manifest, at: date).clip
        }
    }

    static func nextTransition(after date: Date, in manifest: BuildManifest) -> Date? {
        guard manifest.effectiveRandomClipSchedule != .off, manifest.clipSequence.count > 1 else { return nil }
        switch manifest.effectiveRandomClipSchedule {
        case .off:
            return nil
        case .hour:
            let next = (floor(date.timeIntervalSince1970 / 3_600) + 1) * 3_600
            return Date(timeIntervalSince1970: next)
        case .loopBoundary:
            return loopRotation(in: manifest, at: date).nextTransition
        }
    }

    static func interval(for manifest: BuildManifest) -> TimeInterval {
        switch manifest.effectiveRandomClipSchedule {
        case .off: return .infinity
        case .hour: return 60 * 60
        case .loopBoundary:
            let frames = ([manifest.loopFrameCount] + manifest.builtVariants.compactMap(\.loopFrameCount))
                .filter { $0 > 0 }
            return Double(frames.min() ?? 1) / Double(max(manifest.framesPerSecond, 1))
        }
    }

    /// A daily seed bounds the amount of replay necessary to recover the
    /// current state, while every handoff inside the day still lands on the
    /// end of the clip that was actually playing.
    private static func loopRotation(in manifest: BuildManifest, at date: Date) -> LoopRotation {
        let clips = manifest.clipSequence
        let secondsPerDay: TimeInterval = 24 * 60 * 60
        let now = date.timeIntervalSince1970
        let dayBucket = Int64(floor(now / secondsPerDay))
        var start = floor(now / secondsPerDay) * secondsPerDay
        var previous: Int?
        var sequence = 0

        while true {
            let index = choiceIndex(in: manifest, bucket: dayBucket, sequence: sequence, previous: previous)
            let clip = clips[index]
            let duration = clipDuration(clip, manifest: manifest)
            let next = start + duration
            if now < next {
                return LoopRotation(
                    clip: clip,
                    nextTransition: Date(timeIntervalSince1970: next)
                )
            }
            previous = index
            sequence += 1
            start = next
        }
    }

    private static func clipDuration(_ clip: BuildManifest.ClipChoice, manifest: BuildManifest) -> TimeInterval {
        let frames = clip.variantID
            .flatMap { id in manifest.builtVariants.first { $0.id == id }?.loopFrameCount }
            ?? manifest.loopFrameCount
        return Double(max(frames, 1)) / Double(max(manifest.framesPerSecond, 1))
    }

    private static func choiceIndex(
        in manifest: BuildManifest,
        bucket: Int64,
        sequence: Int,
        previous: Int?
    ) -> Int {
        let count = manifest.clipSequence.count
        let selected = Int(hash(manifest.designID, bucket, salt: UInt64(sequence * 2)) % UInt64(count))
        guard selected == previous, count > 1 else { return selected }
        // A random sequence is allowed to repeat mathematically, but seeing
        // the same clip on consecutive boundaries feels broken. Move this
        // choice one or more places when its raw draw repeats the last one.
        return (selected + 1 + Int(hash(manifest.designID, bucket, salt: UInt64(sequence * 2 + 1)) % UInt64(count - 1))) % count
    }

    private static func hourBucket(at date: Date) -> Int64 {
        Int64(floor(date.timeIntervalSince1970 / 3_600))
    }

    /// A freshly shuffled order each group of hours. Rotating a shuffled group
    /// instead of independently hashing every hour means a boundary can never
    /// hand the user the same clip twice in a row.
    private static func hourlyChoiceIndex(in manifest: BuildManifest, bucket: Int64) -> Int {
        let count = manifest.clipSequence.count
        let span = Int64(count)
        let cycle = bucket / span
        let position = Int(bucket % span)
        return hourlyPermutation(in: manifest, cycle: cycle)[position]
    }

    private static func hourlyPermutation(in manifest: BuildManifest, cycle: Int64) -> [Int] {
        var result = rawHourlyPermutation(in: manifest, cycle: cycle)
        guard cycle > 0, result.count > 1 else { return result }
        // Only the first two entries can be swapped below, so the previous
        // cycle's last entry is its raw last entry too; no recursive replay is
        // needed to compare the two groups.
        let previousLast = rawHourlyPermutation(in: manifest, cycle: cycle - 1).last
        if result.first == previousLast {
            result.swapAt(0, 1)
        }
        return result
    }

    private static func rawHourlyPermutation(in manifest: BuildManifest, cycle: Int64) -> [Int] {
        var result = Array(0 ..< manifest.clipSequence.count)
        result.sort { lhs, rhs in
            let left = hash(manifest.designID, cycle, salt: UInt64(lhs + 10_000))
            let right = hash(manifest.designID, cycle, salt: UInt64(rhs + 10_000))
            return left == right ? lhs < rhs : left < right
        }
        return result
    }

    private static func hash(_ id: UUID, _ bucket: Int64, salt: UInt64) -> UInt64 {
        var value: UInt64 = 1_469_598_103_934_665_603 ^ salt
        for byte in (id.uuidString + ":" + String(bucket)).utf8 {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
        return value
    }

    private struct LoopRotation {
        let clip: BuildManifest.ClipChoice
        let nextTransition: Date
    }
}
