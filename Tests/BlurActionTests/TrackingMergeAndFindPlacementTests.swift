import Testing
import Foundation
import CoreGraphics
@testable import BlurAction

/// Pure tracking-merge and find-placement rules, without a window or Vision.
struct TrackingMergeAndFindPlacementTests {
    private func key(_ time: Double, _ x: CGFloat = 0) -> RegionKeyframe {
        RegionKeyframe(time: time, rect: CGRect(x: x, y: 0, width: 10, height: 10))
    }

    @Test func extendedMovesTheStartBackButKeepsTheWholeVideoSentinel() {
        #expect(TrackingMerge.extended(0...0, from: -3) == 0...0)
        #expect(TrackingMerge.extended(2...5, from: 1) == 1...5)
        #expect(TrackingMerge.extended(2...5, from: -1) == 0...5)
        #expect(TrackingMerge.extended(2...5, from: 3) == 2...5)
    }

    @Test func trackingReplacesKeysOnlyInsideTheTrackedSpan() {
        let old = [key(0.5, 1), key(1.5, 2), key(2.5, 3), key(4, 4)]
        let result = TrackingMerge.keyframes(old, base: .zero, anchor: CGRect(x: 9, y: 0, width: 10, height: 10),
                                             tracked: [key(2, 20), key(3, 30)], start: 1, repairEnd: nil)
        #expect(result.map(\.time) == [0.5, 1, 2, 3, 4])
        #expect(result.first { $0.time == 1 }?.rect.minX == 9, "the anchor sits at the start")
        #expect(result.first { $0.time == 4 }?.rect.minX == 4, "keys after the span are kept")
    }

    @Test func repairKeepsKeysOutsideTheReviewAndPinsTheOldPathAtItsEdges() {
        let old = [key(0, 0), key(1, 10), key(2, 20), key(5, 50)]
        let result = TrackingMerge.keyframes(old, base: CGRect(x: 0, y: 0, width: 10, height: 10),
                                             anchor: CGRect(x: 100, y: 0, width: 10, height: 10),
                                             tracked: [key(1.5, 150), key(2, 200), key(4, 400)], start: 1, repairEnd: 2)
        #expect(result.contains { $0.time == 0 && $0.rect.minX == 0 })
        #expect(result.contains { $0.time == 5 && $0.rect.minX == 50 })
        #expect(result.contains { $0.time == (1.0).nextDown }, "old path is pinned just before the review")
        #expect(result.contains { $0.time == (2.0).nextUp }, "old path is pinned just after the review")
        #expect(!result.contains { $0.time == 4 }, "tracking past the review end is not used")
        #expect(result.first { $0.time == 2 }?.rect.minX == 200)
        #expect(result.map(\.time) == result.map(\.time).sorted())
    }

    @Test func refinementGapsReportFramesWithoutEvidence() {
        let fps = 10.0
        let samples = stride(from: 0.0, through: 1.0, by: 0.1).map { ObjectTracker.Sample(time: $0, box: .zero) }
        let all = samples.map { PhraseTracker.CoverEvidence(time: $0.time, points: [], generousBox: .zero) }
        #expect(TrackingMerge.refinementGaps(samples: samples, anchors: all, start: 0, end: 1, fps: fps).isEmpty)

        let missingMiddle = all.filter { abs($0.time - 0.5) > 0.01 }
        let gaps = TrackingMerge.refinementGaps(samples: samples, anchors: missingMiddle, start: 0, end: 1, fps: fps)
        #expect(gaps.count == 1)
        #expect(abs(gaps[0].start - 0.4) < 1e-9 && abs(gaps[0].end - 0.6) < 1e-9)
        #expect(gaps[0].reason == .recognitionGap)

        let none = TrackingMerge.refinementGaps(samples: [], anchors: [], start: 2, end: 3, fps: fps)
        #expect(none.count == 1 && none[0].start == 2 && none[0].end == 3)
    }

    @Test func fittedCoverUsesValidAnchorsAndFallsBackToGenerous() {
        let fit = AutomaticCover(kind: .text, evidencePoints: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0.5, y: 1)],
                                 sourceSize: CGSize(width: 1920, height: 1080), baseNormalizedSize: CGSize(width: 0.2, height: 0.1))
        let box = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)
        let points = [CGPoint(x: 0.12, y: 0.12), CGPoint(x: 0.28, y: 0.12), CGPoint(x: 0.2, y: 0.19)]
        let anchors = [
            PhraseTracker.CoverEvidence(time: 2, points: points, generousBox: box),
            PhraseTracker.CoverEvidence(time: 1, points: points, generousBox: box),
            PhraseTracker.CoverEvidence(time: 1.5, points: points, generousBox: .zero),
        ]
        let fitted = TrackingMerge.fittedCover(fit, anchors: anchors)
        #expect(fitted.evidenceKeyframes.map(\.time) == [1, 2])
        #expect(fitted.mode == .recommended)
        #expect(abs(fitted.evidenceKeyframes[0].points[0].x - 0.1) < 1e-9)

        let fallback = TrackingMerge.fittedCover(fit, anchors: [PhraseTracker.CoverEvidence(time: 1, points: points, generousBox: .zero)])
        #expect(fallback.evidenceKeyframes.isEmpty && fallback.mode == .generous)
    }

    @Test func findSkipsOnlyPlacesThatExistingShapesCoverCompletely() {
        let size = CGSize(width: 1000, height: 500)
        let detection = AutoDetector.Detection(generousBox: CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2),
                                               target: .text, evidencePoints: [], reliable: false)
        let whole: RegionShape = .rectangle(id: UUID(), origin: CGPoint(x: 150, y: 50), size: CGSize(width: 300, height: 200))
        let half: RegionShape = .rectangle(id: UUID(), origin: CGPoint(x: 200, y: 100), size: CGSize(width: 100, height: 100))
        func covered(_ shapes: [RegionShape], _ target: AutoDetector.Target = .text) -> Bool {
            FindPlacement.isAlreadyCovered(detection, target: target, canvasSize: size,
                                           sourceSize: CGSize(width: 1920, height: 1080), covering: shapes)
        }
        #expect(!covered([]))
        #expect(covered([whole]))
        #expect(!covered([half]), "a sliver left showing still gets a cover")
        #expect(covered([whole], .faces))
    }

    @Test func automaticCoverNeedsAUsableBoxAndEvidence() {
        let source = CGSize(width: 1920, height: 1080)
        let points = [CGPoint(x: 0.12, y: 0.12), CGPoint(x: 0.28, y: 0.12), CGPoint(x: 0.2, y: 0.19)]
        #expect(FindPlacement.automaticCover(kind: .text, points: points, box: .zero, sourceSize: source) == nil)
        #expect(FindPlacement.automaticCover(kind: .text, points: [], box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1), sourceSize: source) == nil)
        let made = FindPlacement.automaticCover(kind: .face, points: points, box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1), sourceSize: source)
        #expect(made?.kind == .face && made?.sourceSize == source)
    }
}
