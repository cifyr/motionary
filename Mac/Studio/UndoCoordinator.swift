import Foundation

/// Snapshot undo for the layout editor.
///
/// Mutations arrive as whole-document changes through `onChange`, which fires
/// after the fact - too late to use `UndoManager`'s own per-event grouping. So
/// undo is snapshots: each registration restores the document as it stood
/// before a burst of changes, and a burst is time-bounded because a drag
/// mutates the document on every tick.
///
/// `@unchecked` because `registerUndo` demands a Sendable target; everything
/// here runs on the main thread - SwiftUI's onChange and the window's undo
/// manager both live there.
final class UndoCoordinator: @unchecked Sendable {
    /// Writes a snapshot back into the editor's state.
    var apply: ((DesignDocument) -> Void)?
    /// Reads the state a revert registers as its own counterpart.
    var current: (() -> DesignDocument)?

    /// Seconds under which consecutive changes fold into one undo step. The
    /// first change of a burst carries the state worth returning to.
    private let coalescing: TimeInterval
    private var lastRegistration = Date.distantPast
    private var suppressNext = false
    private weak var undoManager: UndoManager?

    init(coalescing: TimeInterval = 0.8) {
        self.coalescing = coalescing
    }

    func designChanged(from old: DesignDocument, undoManager: UndoManager?) {
        // The change a revert itself made. Registering it as a fresh undo
        // would turn Cmd-Z into a toggle between the last two states instead
        // of a walk back through them.
        if suppressNext {
            suppressNext = false
            return
        }
        self.undoManager = undoManager
        let now = Date()
        guard now.timeIntervalSince(lastRegistration) >= coalescing else { return }
        lastRegistration = now
        register(snapshot: old, with: undoManager)
    }

    private func register(snapshot: DesignDocument, with undoManager: UndoManager?) {
        undoManager?.registerUndo(withTarget: self) { coordinator in
            coordinator.revert(to: snapshot)
        }
        undoManager?.setActionName("Layout Change")
    }

    private func revert(to snapshot: DesignDocument) {
        // The counterpart is registered here, eagerly, because it has to land
        // while the manager is mid-undo to end up on the redo stack - the
        // editor's own onChange arrives a view update too late to say so.
        if let current = current?() {
            register(snapshot: current, with: undoManager)
        }
        suppressNext = true
        apply?(snapshot)
    }
}
