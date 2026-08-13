import XCTest

/// The run screen's steps are the only account of a four-minute wait, so the
/// mapping from a phase to a step has to be right or the screen misreports
/// where the time is going.
final class StudioRunTests: XCTestCase {
    func testABuildWalksItsStepsInOrder() {
        let run = StudioRun.building("Spidey Swing")
        XCTAssertEqual(run.step(for: .reading), 0)
        XCTAssertEqual(run.step(for: .rendering), 1)
        XCTAssertEqual(run.step(for: .bundling), 2)
        XCTAssertEqual(run.step(for: .installing("Installing on the phone")), 3)
        XCTAssertEqual(run.steps.count, 4)
    }

    /// Install all renders nothing: it starts at the bundle, so its first step
    /// has to be the bundle rather than a clip it will never read.
    func testInstallingStartsAtTheBundle() {
        let run = StudioRun.installing(count: 3)
        XCTAssertEqual(run.step(for: .bundling), 0)
        XCTAssertEqual(run.step(for: .installing("Regenerating the Xcode project")), 1)
        XCTAssertEqual(run.step(for: .installing("Installing on the phone")), 2)
        XCTAssertEqual(run.steps.count, 3)
    }

    func testEveryPhaseAddressesARealStep() {
        let phases: [StudioRun.Phase] = [
            .reading, .rendering, .bundling,
            .installing("Regenerating the Xcode project"),
            .installing("Installing on the phone")
        ]
        for run in [StudioRun.opening("clip.mov"), .building("clip"), .installing(count: 2)] {
            for phase in phases {
                let step = run.step(for: phase)
                XCTAssertTrue(
                    run.steps.indices.contains(step),
                    "\(run) put \(phase) at step \(step), outside its \(run.steps.count) steps"
                )
            }
        }
    }

    /// Steps only ever move forward, so a run cannot appear to go backwards
    /// while it is working.
    func testStepsNeverGoBackwards() {
        let run = StudioRun.building("clip")
        let order: [StudioRun.Phase] = [.reading, .rendering, .bundling, .installing("Installing on the phone")]
        let steps = order.map(run.step(for:))
        XCTAssertEqual(steps, steps.sorted())
    }

    func testTheTitleCountsDesignsRatherThanNamingOne() {
        XCTAssertEqual(StudioRun.installing(count: 1).title, "Installing 1 design")
        XCTAssertEqual(StudioRun.installing(count: 3).title, "Installing 3 designs")
    }
}
