import XCTest

/// Snapshot undo with hand-rolled redo bookkeeping: the counterpart has to be
/// registered mid-undo to land on the redo stack, and the editor's own change
/// notification must not re-register what a revert just did.
final class UndoCoordinatorTests: XCTestCase {
    private var manager: UndoManager!
    private var coordinator: UndoCoordinator!
    private var state: DesignDocument!

    private func design(_ name: String) -> DesignDocument {
        DesignDocument.new(name: name, sourceVideoName: "source.mp4")
    }

    /// Drives the coordinator the way the editor does: mutate, then report the
    /// change with the prior state.
    private func change(to name: String) {
        let old = state!
        state = design(name)
        coordinator.designChanged(from: old, undoManager: manager)
    }

    override func setUp() {
        super.setUp()
        manager = UndoManager()
        coordinator = UndoCoordinator(coalescing: 0)
        state = design("A")
        coordinator.apply = { [weak self] in self?.state = $0 }
        coordinator.current = { [weak self] in self?.state ?? DesignDocument.new(name: "?", sourceVideoName: "?") }
    }

    func testUndoRestoresTheEarlierDesign() {
        change(to: "B")
        XCTAssertTrue(manager.canUndo)

        manager.undo()
        XCTAssertEqual(state.name, "A")
    }

    func testRedoRestoresWhatUndoTookAway() {
        change(to: "B")
        manager.undo()
        XCTAssertTrue(manager.canRedo, "the revert must register its counterpart mid-undo")

        manager.redo()
        XCTAssertEqual(state.name, "B")
    }

    /// After a revert, the editor's onChange still fires with the change the
    /// revert made. Registering it would turn Cmd-Z into a toggle between the
    /// last two states instead of a walk back through them.
    func testARevertsOwnChangeIsNotAFreshUndo() {
        change(to: "B")
        manager.undo()

        // What the editor reports after the revert lands.
        coordinator.designChanged(from: design("B"), undoManager: manager)
        XCTAssertFalse(manager.canUndo, "the revert's own change re-registered as an undo")
    }

    /// A drag mutates the design every tick; one gesture should be one step,
    /// restoring the state before the burst.
    func testABurstCoalescesIntoOneStepBackToItsStart() {
        coordinator = UndoCoordinator(coalescing: 10)
        coordinator.apply = { [weak self] in self?.state = $0 }
        coordinator.current = { [weak self] in self?.state ?? DesignDocument.new(name: "?", sourceVideoName: "?") }

        change(to: "B")
        change(to: "C")
        change(to: "D")

        manager.undo()
        XCTAssertEqual(state.name, "A", "undo should return to the state before the burst")
        XCTAssertFalse(manager.canUndo, "the burst registered more than one step")
    }
}
