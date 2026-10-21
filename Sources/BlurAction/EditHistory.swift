import Foundation
import CoreGraphics

/// Undo/redo for the editor: snapshots of cover regions and drawings, plus the mouse
/// gesture in progress. One user action pushes one snapshot. A mouse gesture pushes
/// its starting state when it ends, and only if something changed.
struct EditHistory {
    struct Snapshot {
        var pairs: [RegionEditing.Pair]
        var annotations: [DrawingAnnotation]
    }

    static let limit = 50
    /// Continuous controls (color panel drags) with the same key within this many
    /// seconds share one undo step.
    static let coalescingInterval: TimeInterval = 1

    private(set) var undo: [Snapshot] = []
    private(set) var redo: [Snapshot] = []
    /// The state when the current mouse gesture began; nil outside a gesture.
    private(set) var gestureSnapshot: [RegionEditing.Pair]?
    private(set) var gestureAnnotations: [DrawingAnnotation]?
    private(set) var gestureStartTime: Double?
    private var coalescedEdit: (key: String, at: Date)?

    /// Records `current` as an undo step before a mutation.
    mutating func checkpoint(_ current: Snapshot, coalescing key: String? = nil, now: Date = Date()) {
        if let key, let last = coalescedEdit, last.key == key, now.timeIntervalSince(last.at) < Self.coalescingInterval {
            coalescedEdit = (key, now)
            return
        }
        coalescedEdit = key.map { ($0, now) }
        pushUndo(current)
        redo.removeAll()
    }

    /// Does nothing while a gesture is already in progress.
    mutating func beginGesture(_ current: Snapshot, time: Double?) {
        guard gestureSnapshot == nil else { return }
        gestureSnapshot = current.pairs
        gestureAnnotations = current.annotations
        gestureStartTime = time
    }

    mutating func endGesture(current: Snapshot) {
        guard let before = gestureSnapshot else { return }
        let beforeAnnotations = gestureAnnotations ?? current.annotations
        gestureSnapshot = nil
        gestureAnnotations = nil
        gestureStartTime = nil
        if !RegionEditing.equal(before, current.pairs) || beforeAnnotations != current.annotations {
            coalescedEdit = nil
            pushUndo(Snapshot(pairs: before, annotations: beforeAnnotations))
            redo.removeAll()
        }
    }

    /// Returns the state to restore, or nil when there is nothing to undo.
    mutating func undo(current: Snapshot) -> Snapshot? {
        guard let previous = undo.popLast() else { return nil }
        coalescedEdit = nil
        redo.append(current)
        return previous
    }

    /// Returns the state to restore, or nil when there is nothing to redo.
    /// Like the original editor, redo does not apply the undo limit.
    mutating func redo(current: Snapshot) -> Snapshot? {
        guard let next = redo.popLast() else { return nil }
        coalescedEdit = nil
        undo.append(current)
        return next
    }

    /// Keeps every stored snapshot in step with a canvas resize.
    mutating func rescale(from old: CGSize, to new: CGSize) {
        func scaled(_ s: Snapshot) -> Snapshot {
            Snapshot(pairs: RegionEditing.scaled(s.pairs, from: old, to: new),
                     annotations: s.annotations.map { $0.scaled(from: old, to: new) })
        }
        undo = undo.map(scaled)
        redo = redo.map(scaled)
        if let snapshot = gestureSnapshot {
            gestureSnapshot = RegionEditing.scaled(snapshot, from: old, to: new)
        }
        gestureAnnotations = gestureAnnotations?.map { $0.scaled(from: old, to: new) }
    }

    /// Clears undo and redo (opening a project into the current document).
    mutating func clearSteps() {
        undo.removeAll()
        redo.removeAll()
    }

    /// Clears undo, redo and the gesture snapshot when a new document starts loading.
    mutating func clearForNewDocument() {
        clearSteps()
        gestureSnapshot = nil
        gestureAnnotations = nil
    }

    /// Restores a page's saved steps when switching pages.
    mutating func replaceSteps(undo: [Snapshot], redo: [Snapshot]) {
        self.undo = undo
        self.redo = redo
    }

    private mutating func pushUndo(_ snapshot: Snapshot) {
        undo.append(snapshot)
        if undo.count > Self.limit { undo.removeFirst() }
    }
}
