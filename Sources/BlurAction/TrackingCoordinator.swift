import Foundation
import CoreGraphics

/// The running automatic tracking: its cancellation handle, the review being repaired, and the
/// injected tracker, plus the background work that tracks and refines. It holds no reference to
/// the editor; the editor validates items, locks the UI and applies the results.
@MainActor
final class TrackingCoordinator {
    typealias TrackObjects = (URL, Double, Double, [CGRect], ObjectTracker.Options, ObjectTracker.Cancellation,
                              @escaping (Double) -> Void) async throws -> [ObjectTracker.Outcome]

    struct RefinedTracking {
        var outcomes: [UUID: ObjectTracker.Outcome]
        var evidence: [UUID: [PhraseTracker.CoverEvidence]]
    }

    /// What to track: items with their start boxes (normalized), from `start` toward `end`.
    struct Request {
        var url: URL
        var start: Double
        var end: Double
        var choice: MainWindowController.TrackChoice
        var items: [UUID]
        var boxes: [CGRect]
        var options: ObjectTracker.Options
        /// Items whose automatic cover is re-fitted to detection evidence along the tracked path.
        var refinementKinds: [UUID: AutoDetector.Target]
    }

    private(set) var trackingCancellation: ObjectTracker.Cancellation?
    var repairingReview: (region: UUID, review: UUID, end: Double)?
    var trackObjects: TrackObjects = {
        try await ObjectTracker.trackMany(url: $0, from: $1, until: $2, boxes: $3, options: $4,
                                          cancellation: $5, progress: $6)
    }

    var isTracking: Bool { trackingCancellation != nil }
    /// True once a running tracking task has been asked to stop (window close or 취소).
    var trackingStopRequested: Bool { trackingCancellation?.isCancelled ?? false }

    /// Marks tracking as running and returns its cancellation handle.
    func begin() -> ObjectTracker.Cancellation {
        let cancellation = ObjectTracker.Cancellation()
        trackingCancellation = cancellation
        return cancellation
    }

    func end() { trackingCancellation = nil }

    /// Tracks backward and/or forward, then refines automatic covers, off the main actor.
    func run(_ request: Request, cancellation: ObjectTracker.Cancellation,
             report: @escaping @Sendable (Double) -> Void) async -> Result<RefinedTracking, Error> {
        let run = trackObjects
        let (url, start, end, choice) = (request.url, request.start, request.end, request.choice)
        let (items, boxes, options, refinementKinds) = (request.items, request.boxes, request.options, request.refinementKinds)
        let initial = Dictionary(uniqueKeysWithValues: zip(items, boxes))
        return await Task.detached(priority: .userInitiated) { () -> Result<RefinedTracking, Error> in
            do {
                var backward: [ObjectTracker.Outcome]?, forward: [ObjectTracker.Outcome]?
                if choice != .forward {
                    var back = options
                    back.direction = .backward
                    backward = try await run(url, start, 0, boxes, back, cancellation) { report(choice == .both ? $0 / 2 : $0) }
                }
                if choice != .backward, !cancellation.isCancelled {
                    var ahead = options
                    ahead.direction = .forward
                    forward = try await run(url, start, end, boxes, ahead, cancellation) { report(choice == .both ? 0.5 + $0 / 2 : $0) }
                }
                var outcomes: [UUID: ObjectTracker.Outcome] = [:]
                for (index, id) in items.enumerated() {
                    let samples = ((backward?[index].samples ?? []) + (forward?[index].samples ?? [])).sorted { $0.time < $1.time }
                    outcomes[id] = ObjectTracker.Outcome(samples: samples,
                                                         lostTarget: (backward?[index].lostTarget ?? false) || (forward?[index].lostTarget ?? false),
                                                         cancelled: cancellation.isCancelled)
                }
                var evidence: [UUID: [PhraseTracker.CoverEvidence]] = [:]
                if !cancellation.isCancelled {
                    for target in AutoDetector.Target.allCases {
                        let ids = items.filter { refinementKinds[$0] == target }
                        guard !ids.isEmpty else { continue }
                        let samples = ids.map { id -> [ObjectTracker.Sample] in
                            let list = outcomes[id]?.samples ?? []
                            return ([ObjectTracker.Sample(time: start, box: initial[id] ?? .zero)] + list)
                                .sorted { $0.time < $1.time }
                        }
                        do {
                            let refined = try await AutoDetector.refineTracks(url: url, target: target,
                                tracks: samples, cancellation: cancellation)
                            for (id, anchors) in zip(ids, refined) { evidence[id] = anchors }
                        } catch PageWorkspace.WorkspaceError.sourceChanged { throw PageWorkspace.WorkspaceError.sourceChanged }
                        catch { // Optional refinement must not discard an already recorded tracking path.
                            for id in ids { evidence[id] = [] }
                        }
                    }
                }
                if cancellation.isCancelled {
                    for id in items { outcomes[id]?.cancelled = true }
                    evidence = [:]
                }
                return .success(RefinedTracking(outcomes: outcomes, evidence: evidence))
            } catch { return .failure(error) }
        }.value
    }
}
