import Testing
import AppKit
@testable import BlurAction

/// Undo rules without a window: limit, coalescing, gestures, redo and resize.
struct EditHistoryTests {
    /// Made once so equal counts give equal snapshots (each drawing has its own UUID).
    private let lines = (0..<70).map { i in
        DrawingAnnotation(kind: .line, points: [CGPoint(x: i, y: 0), CGPoint(x: i, y: 10)], color: .red, lineWidth: 2)
    }

    /// A snapshot told apart by the number of drawings it holds.
    private func snapshot(_ drawings: Int) -> EditHistory.Snapshot {
        EditHistory.Snapshot(pairs: [], annotations: Array(lines.prefix(drawings)))
    }

    @Test func checkpointKeepsTheLastFiftyStepsAndClearsRedo() {
        var history = EditHistory()
        for n in 0..<60 { history.checkpoint(snapshot(n)) }
        #expect(history.undo.count == EditHistory.limit)
        #expect(history.undo.first?.annotations.count == 10)
        _ = history.undo(current: snapshot(60))
        #expect(history.redo.count == 1)
        history.checkpoint(snapshot(61))
        #expect(history.redo.isEmpty)
    }

    @Test func sameKeyWithinOneSecondIsOneStep() {
        var history = EditHistory()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        history.checkpoint(snapshot(0), coalescing: "color-a", now: start)
        history.checkpoint(snapshot(1), coalescing: "color-a", now: start.addingTimeInterval(0.5))
        history.checkpoint(snapshot(2), coalescing: "color-a", now: start.addingTimeInterval(0.9))
        #expect(history.undo.count == 1)
        // The window restarts at each coalesced edit, so 1.4 s after the first is still within 1 s of the last.
        history.checkpoint(snapshot(3), coalescing: "color-a", now: start.addingTimeInterval(1.4))
        #expect(history.undo.count == 1)
        history.checkpoint(snapshot(4), coalescing: "color-a", now: start.addingTimeInterval(2.5))
        history.checkpoint(snapshot(5), coalescing: "color-b", now: start.addingTimeInterval(2.6))
        #expect(history.undo.count == 3)
    }

    @Test func undoEndsCoalescingSoTheNextEditIsItsOwnStep() {
        var history = EditHistory()
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        history.checkpoint(snapshot(0), coalescing: "k", now: now)
        _ = history.undo(current: snapshot(1))
        history.checkpoint(snapshot(0), coalescing: "k", now: now.addingTimeInterval(0.1))
        #expect(history.undo.count == 1)
        #expect(history.redo.isEmpty)
    }

    @Test func gesturePushesItsStartOnlyWhenSomethingChanged() {
        var history = EditHistory()
        history.beginGesture(snapshot(1), time: 2.5)
        #expect(history.gestureStartTime == 2.5)
        history.beginGesture(snapshot(9), time: 7)
        #expect(history.gestureAnnotations?.count == 1, "a second begin inside a gesture is ignored")
        history.endGesture(current: snapshot(1))
        #expect(history.undo.isEmpty && history.gestureSnapshot == nil && history.gestureStartTime == nil)

        history.beginGesture(snapshot(1), time: nil)
        history.endGesture(current: snapshot(2))
        #expect(history.undo.count == 1 && history.undo.last?.annotations.count == 1)
    }

    @Test func undoAndRedoSwapStatesAndReportEmptyStacks() {
        var history = EditHistory()
        #expect(history.undo(current: snapshot(0)) == nil)
        #expect(history.redo(current: snapshot(0)) == nil)
        history.checkpoint(snapshot(1))
        #expect(history.undo(current: snapshot(2))?.annotations.count == 1)
        #expect(history.redo(current: snapshot(1))?.annotations.count == 2)
        #expect(history.undo.count == 1 && history.redo.isEmpty)
    }

    @Test func clearingForANewDocumentDropsStepsAndTheGestureSnapshot() {
        var history = EditHistory()
        history.checkpoint(snapshot(1))
        history.beginGesture(snapshot(2), time: 3)
        history.clearForNewDocument()
        #expect(history.undo.isEmpty && history.redo.isEmpty)
        #expect(history.gestureSnapshot == nil && history.gestureAnnotations == nil)
    }

    @Test func rescaleMovesEveryStoredSnapshot() {
        var history = EditHistory()
        history.checkpoint(snapshot(1))
        history.beginGesture(snapshot(1), time: nil)
        history.rescale(from: CGSize(width: 100, height: 100), to: CGSize(width: 200, height: 200))
        #expect(history.undo[0].annotations[0].points[1].y == 20)
        #expect(history.gestureAnnotations?[0].points[1].y == 20)
    }
}
