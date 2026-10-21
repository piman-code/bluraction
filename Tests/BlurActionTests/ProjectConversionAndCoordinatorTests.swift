import Testing
import Foundation
import CoreGraphics
@testable import BlurAction

/// Project conversion rules and the tracking/find coordinators, without a window, media or Vision.
@MainActor
struct ProjectConversionAndCoordinatorTests {
    private func region(_ x: CGFloat, range: ClosedRange<Double> = 0...0, group: UUID? = nil) -> RegionEditing.Pair {
        var effect = RegionEffect.alwaysOn()
        effect.timeRange = range
        effect.groupID = group
        return (.rectangle(id: UUID(), origin: CGPoint(x: x, y: 0.25), size: CGSize(width: 0.25, height: 0.5)), effect)
    }

    private func drawing(range: ClosedRange<Double> = 0...0, group: UUID? = nil) -> DrawingAnnotation {
        var drawing = DrawingAnnotation(kind: .line, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.5, y: 0.5)])
        drawing.timeRange = range
        drawing.groupID = group
        return drawing
    }

    @Test func clippingKeepsTheWholeVideoSentinelAndRangesInsideTheVideo() {
        #expect(ProjectConversion.clipped(0...0, toDuration: 5) == 0...0)
        #expect(ProjectConversion.clipped(1...4, toDuration: 5) == 1...4)
        #expect(ProjectConversion.clipped(1...9, toDuration: 5) == 1...5)
        #expect(ProjectConversion.clipped(7...9, toDuration: 5) == 5...5, "a range past the end collapses onto the end")
        #expect(ProjectConversion.clipped(1...9, toDuration: nil) == 1...9, "images and unclipped templates keep their times")
    }

    @Test func normalizingAndApplyingRoundTripsGeometryAndKeepsIDs() {
        let size = CGSize(width: 800, height: 400)
        let pair = region(0.25)
        let canvasPairs = RegionEditing.scaled([pair], from: ProjectConversion.unit, to: size)
        let project = ProjectFile(mediaPath: "clip.mov",
                                  regions: ProjectConversion.normalizedRegions(canvasPairs, from: size),
                                  drawings: ProjectConversion.normalizedDrawings([drawing()].map { $0.scaled(from: ProjectConversion.unit, to: size) }, from: size))
        #expect(project.regions.first?.shape.boundingRect.minX ?? 0 == 0.25)
        let applied = ProjectConversion.appliedItems(project, canvasSize: size, clipDuration: nil)
        #expect(applied.regions.map(\.shape.id) == [pair.shape.id])
        #expect(applied.regions.first?.shape.boundingRect == canvasPairs.first?.shape.boundingRect)
        #expect(applied.drawings.count == 1)
        #expect(ProjectConversion.regions(canvasPairs).first?.shape.boundingRect == canvasPairs.first?.shape.boundingRect,
                "unscaled regions keep canvas coordinates")
    }

    @Test func applyingClipsTimesOnlyWhenAsked() {
        let project = ProjectFile(mediaPath: "clip.mov", regions: [region(0, range: 2...20)].map { ProjectFile.Region(shape: $0.shape, effect: $0.effect) },
                                  drawings: [drawing(range: 3...30)])
        let clipped = ProjectConversion.appliedItems(project, canvasSize: CGSize(width: 10, height: 10), clipDuration: 10)
        #expect(clipped.regions.first?.effect.timeRange == 2...10)
        #expect(clipped.drawings.first?.timeRange == 3...10)
        let kept = ProjectConversion.appliedItems(project, canvasSize: CGSize(width: 10, height: 10), clipDuration: nil)
        #expect(kept.regions.first?.effect.timeRange == 2...20)
    }

    @Test func importingGivesNewIDsAndRemapsEachGroupConsistently() {
        let groupA = UUID(), groupB = UUID()
        let pairs = [region(0, group: groupA), region(0.25, group: groupA), region(0.5, group: groupB), region(0.75)]
        let drawings = [drawing(group: groupA), drawing()]
        let project = ProjectFile(mediaPath: "clip.mov", regions: pairs.map { ProjectFile.Region(shape: $0.shape, effect: $0.effect) },
                                  drawings: drawings)
        let imported = ProjectConversion.importedItems(project, canvasSize: CGSize(width: 100, height: 100), clipDuration: nil)
        #expect(Set(imported.regions.map(\.shape.id)).isDisjoint(with: pairs.map(\.shape.id)))
        #expect(Set(imported.drawings.map(\.id)).isDisjoint(with: drawings.map(\.id)))
        let groups = imported.regions.map(\.effect.groupID)
        #expect(groups[0] != nil && groups[0] != groupA)
        #expect(groups[0] == groups[1], "members of one old group share one new group")
        #expect(groups[2] != nil && groups[2] != groups[0] && groups[2] != groupB)
        #expect(groups[3] == nil)
        #expect(imported.drawings[0].groupID == groups[0], "drawings join the same new group as regions")
        #expect(imported.drawings[1].groupID == nil)
        #expect(imported.regions[1].shape.boundingRect.minX == 25, "geometry is scaled to the canvas")
        if case .rectangle = imported.regions[0].shape {} else { Issue.record("shape kind is kept") }
    }

    @Test func importingClipsTimesPastTheVideoEnd() {
        let project = ProjectFile(mediaPath: "clip.mov", regions: [region(0, range: 4...12)].map { ProjectFile.Region(shape: $0.shape, effect: $0.effect) },
                                  drawings: [drawing(range: 0...0)])
        let imported = ProjectConversion.importedItems(project, canvasSize: CGSize(width: 10, height: 10), clipDuration: 6)
        #expect(imported.regions.first?.effect.timeRange == 4...6)
        #expect(imported.drawings.first?.timeRange == 0...0)
    }

    @Test func findContextMatchesWithinOneMillisecondOnTheSameScreen() {
        let url = URL(fileURLWithPath: "/tmp/clip.mov")
        typealias Context = FindCoordinator.FindContext
        #expect(Context(url: url, page: nil, time: 1) == Context(url: url, page: nil, time: 1.0005))
        #expect(Context(url: url, page: nil, time: 1) != Context(url: url, page: nil, time: 1.01))
        #expect(Context(url: url, page: nil, time: nil) != Context(url: url, page: nil, time: 0))
        #expect(Context(url: url, page: 0, time: nil) != Context(url: url, page: 1, time: nil))
    }

    @Test func foundIDsOnlyCountOnTheFindsPageAndStillPresent() {
        let finding = FindCoordinator()
        let url = URL(fileURLWithPath: "/tmp/a.png"), a = UUID(), b = UUID(), c = UUID()
        finding.lastFound = ([a, b, c], url, 1)
        #expect(finding.foundIDs(url: url, page: 1, present: [c, a]) == [a, c])
        #expect(finding.foundIDs(url: url, page: 0, present: [a, b, c]).isEmpty)
        #expect(finding.foundIDs(url: URL(fileURLWithPath: "/tmp/b.png"), page: 1, present: [a]).isEmpty)
    }

    @Test func replacingTheSimpleDetectorDropsTheDetailedOne() {
        let finding = FindCoordinator()
        #expect(finding.autoDetectDetailed != nil)
        finding.autoDetect = { _, _ in [] }
        #expect(finding.autoDetectDetailed == nil)
    }

    @Test func cancelAllStopsEveryFindHandle() {
        let finding = FindCoordinator()
        finding.trackPhrases = { _, _, _, _, _, _ in throw CancellationError() }
        let started = finding.startPhraseTracking(["학부모"], url: URL(fileURLWithPath: "/tmp/none.mov"), duration: 1) { _ in }
        finding.cancelAll()
        #expect(started.cancellation.isCancelled)
        #expect(started.task.isCancelled)
        #expect(finding.phraseTrackingCancellation === started.cancellation)
    }

    @Test func trackingRunMergesBothDirectionsAndMarksCancellation() async {
        let tracking = TrackingCoordinator()
        let id = UUID(), box = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        tracking.trackObjects = { _, from, until, boxes, options, _, _ in
            let times = options.direction == .backward ? [from - 1, from - 0.5] : [from + 0.5, until]
            return boxes.map { start in
                ObjectTracker.Outcome(samples: times.map { ObjectTracker.Sample(time: $0, box: start) },
                                      lostTarget: options.direction == .forward, cancelled: false)
            }
        }
        #expect(!tracking.isTracking)
        let cancellation = tracking.begin()
        #expect(tracking.isTracking && !tracking.trackingStopRequested)
        let request = TrackingCoordinator.Request(url: URL(fileURLWithPath: "/tmp/none.mov"), start: 2, end: 4, choice: .both,
                                                  items: [id], boxes: [box], options: ObjectTracker.Options(), refinementKinds: [:])
        guard case .success(let refined) = await tracking.run(request, cancellation: cancellation, report: { _ in }) else {
            Issue.record("tracking failed"); return
        }
        #expect(refined.outcomes[id]?.samples.map(\.time) == [1, 1.5, 2.5, 4])
        #expect(refined.outcomes[id]?.lostTarget == true)
        #expect(refined.outcomes[id]?.cancelled == false)
        #expect(refined.evidence.isEmpty)
        cancellation.cancel()
        #expect(tracking.trackingStopRequested)
        let stopped = await tracking.run(request, cancellation: cancellation, report: { _ in })
        if case .success(let value) = stopped { #expect(value.outcomes[id]?.cancelled == true) }
        else { Issue.record("a cancelled run still reports what it recorded") }
        tracking.end()
        #expect(!tracking.isTracking)
    }
}
