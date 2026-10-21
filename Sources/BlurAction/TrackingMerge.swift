import Foundation
import CoreGraphics

/// Pure helpers for applying tracking results to a cover. No editor state.
enum TrackingMerge {
    /// Keyframes after tracking from `start`, anchored at `anchor`.
    /// With `repairEnd` (repairing one review interval), keys outside the repaired span stay
    /// exactly as they were. Otherwise tracked keys replace the old ones in their time span.
    static func keyframes(_ frames: [RegionKeyframe], base: CGRect, anchor: CGRect, tracked: [RegionKeyframe],
                          start: Double, repairEnd: Double?) -> [RegionKeyframe] {
        if let repairEnd {
            // Keep every original key outside the reviewed range. Just outside its exact
            // endpoints, restore the old interpolated path, so repair cannot warp nearby
            // unreviewed footage. Do not use inserting here: it merges near timestamps.
            let high = min(max(start, repairEnd), max(start, tracked.last?.time ?? start))
            var result = frames.filter { $0.time < start || $0.time > high }
            let before = start.nextDown, after = high.nextUp
            for boundary in [before, after] where boundary >= 0 && boundary.isFinite {
                if !result.contains(where: { $0.time == boundary }) {
                    result.append(.init(time: boundary, rect: MotionTrack.rect(at: boundary, base: base, keyframes: frames)))
                }
            }
            result.append(.init(time: start, rect: anchor))
            result += tracked.filter { $0.time > start && $0.time <= high }
            return result.sorted { $0.time < $1.time }
        }
        let low = min(start, tracked.first?.time ?? start), high = max(start, tracked.last?.time ?? start)
        var result = frames.filter { $0.time < low - MotionTrack.sameTime || $0.time > high + MotionTrack.sameTime }
        for frame in [RegionKeyframe(time: start, rect: anchor)] + tracked { result = MotionTrack.inserting(frame, into: result) }
        return result
    }

    /// Moves the start of `range` back to `earliest`, never before 0. The whole-video
    /// sentinel `0...0` stays as it is.
    static func extended(_ range: ClosedRange<Double>, from earliest: Double) -> ClosedRange<Double> {
        guard !(range.lowerBound == 0 && range.upperBound == 0), earliest < range.lowerBound else { return range }
        return max(0, earliest)...range.upperBound
    }

    /// Evidence keyframes from tracked anchors, local to each anchor's generous box.
    /// Invalid anchors are skipped; with none left the cover falls back to `generous`.
    static func fittedCover(_ fit: AutomaticCover, anchors: [PhraseTracker.CoverEvidence]) -> AutomaticCover {
        var result = fit
        var frames: [AutomaticCover.EvidenceKeyframe] = []
        for anchor in anchors.sorted(by: { $0.time < $1.time }) where anchor.generousBox.width > 0 && anchor.generousBox.height > 0 {
            let box = anchor.generousBox
            let points = anchor.points.map { CGPoint(x: ($0.x - box.minX) / box.width, y: ($0.y - box.minY) / box.height) }
            var test = fit; test.evidencePoints = points; test.evidenceKeyframes = []
            guard test.isValid else { continue }
            if frames.last?.time == anchor.time { frames.removeLast() }
            frames.append(.init(time: anchor.time, points: points))
        }
        result.evidenceKeyframes = frames
        if frames.isEmpty { result.mode = .generous }
        return result
    }

    /// Every interval used for a reduced video mask must have observed geometry at both
    /// frame endpoints. Missing/ambiguous evidence is a persisted review, never a silent guess.
    static func refinementGaps(samples: [ObjectTracker.Sample], anchors: [PhraseTracker.CoverEvidence],
                               start: Double, end: Double, fps: Double) -> [TrackingReview] {
        let times = anchors.map(\.time).sorted()
        let frame = 1 / max(1, fps)
        let ordered = samples.sorted { $0.time < $1.time }
        var missing: [ClosedRange<Double>] = []
        func present(_ t: Double) -> Bool { times.contains { abs($0 - t) < 1.0 / 6000 } }
        func add(_ low: Double, _ high: Double) {
            let low = max(start, low), high = min(end, high)
            guard high > low else { return }
            if let last = missing.last, low <= last.upperBound + 0.000001 {
                missing[missing.count - 1] = last.lowerBound...max(last.upperBound, high)
            } else { missing.append(low...high) }
        }
        if let first = ordered.first, first.time > start + 0.000001 { add(start, first.time) }
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            if !present(a.time) || !present(b.time) || b.time - a.time > frame * 1.5 { add(a.time, b.time) }
        }
        if let last = ordered.last {
            if !present(last.time) || end - last.time > frame * 1.5 { add(last.time, end) }
        } else { add(start, end) }
        return missing.map { TrackingReview(start: $0.lowerBound, end: $0.upperBound, reason: .recognitionGap) }
    }
}
