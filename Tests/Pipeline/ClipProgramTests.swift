import XCTest

final class ClipProgramTests: XCTestCase {
    private let seed = UUID(uuidString: "A0A0A0A0-1111-2222-3333-444444444444")!

    func testSpideyStyleBagPlaysAllThreeClipsOnce() throws {
        let ids = [UUID(), UUID(), UUID()]
        let program = try XCTUnwrap(ClipProgram.shuffled(
            clips: ids.map { .init(id: $0, frameCount: 320) },
            totalFrames: 960,
            seed: seed
        ))
        XCTAssertEqual(program.count, 3)
        XCTAssertEqual(Set(program.compactMap(\.clipID)), Set(ids))
        XCTAssertEqual(program.map(\.frameCount), [320, 320, 320])
    }

    func testNoAdjacentSegmentRepeatsIncludingTheWrap() throws {
        let program = try XCTUnwrap(ClipProgram.shuffled(
            clips: [UUID(), UUID(), UUID()].map { .init(id: $0, frameCount: 160) },
            totalFrames: 960,
            seed: seed
        ))
        let wrapped = program + [try XCTUnwrap(program.first)]
        for pair in zip(wrapped, wrapped.dropFirst()) {
            XCTAssertNotEqual(pair.0.clipID, pair.1.clipID)
        }
    }

    func testSegmentsFillTheFrameTableWithoutCuttingAClip() throws {
        let clips = [
            ClipProgram.Clip(id: UUID(), frameCount: 240),
            ClipProgram.Clip(id: UUID(), frameCount: 160),
            ClipProgram.Clip(id: UUID(), frameCount: 80),
        ]
        let program = try XCTUnwrap(ClipProgram.shuffled(clips: clips, totalFrames: 960, seed: seed))
        XCTAssertEqual(program.reduce(0) { $0 + $1.frameCount }, 960)
        XCTAssertEqual(program.map(\.startFrame), program.indices.map { index in
            program[..<index].reduce(0) { $0 + $1.frameCount }
        })
        let lengths = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0.frameCount) })
        XCTAssertTrue(program.allSatisfy { lengths[$0.clipID] == $0.frameCount })
    }

    func testOneClipDoesNotCreateAnAutomaticProgram() {
        XCTAssertNil(ClipProgram.shuffled(
            clips: [.init(id: nil, frameCount: 320)],
            totalFrames: 960,
            seed: seed
        ))
    }
}
