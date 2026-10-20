import Foundation
import CoreGraphics

/// Canvas coordinates use a bottom-left origin. Base geometry never follows playback.
enum RegionEditing {
    typealias Pair = (shape: RegionShape, effect: RegionEffect)

    static func displayed(_ pair: Pair, at time: Double?) -> RegionShape {
        pair.effect.shape(pair.shape, at: time)
    }

    static func inserting(_ frame: RegionKeyframe, into frames: [RegionKeyframe]) -> [RegionKeyframe] {
        MotionTrack.inserting(frame, into: frames)
    }

    /// `recording` is the motion-recording switch: an edit at time t becomes a position at t.
    /// With it off, an edit moves the whole recorded path (or the static region).
    static func updating(_ shapes: [RegionShape], in pairs: [Pair], time: Double?, recording: Bool,
                         anchorTime: Double? = nil, anchorPairs: [Pair]? = nil,
                         creationTime: Double? = nil, videoDuration: Double? = nil) -> [Pair] {
        let byID = Dictionary(pairs.map { ($0.shape.id, $0) }, uniquingKeysWith: { first, _ in first })
        return shapes.map { requestedShape in
            var shape = requestedShape
            guard var old = byID[shape.id] else {
                return (shape, .created(at: creationTime ?? time, videoDuration: videoDuration))
            }
            let shown = displayed(old, at: time)
            guard shape != shown else { return old }
            // A manual edit takes ownership of the shown geometry. Convert the recorded
            // boxes before dropping automatic metadata so playback cannot reapply padding.
            if old.effect.automaticCover != nil {
                let original = old
                let rotatingTrack = !(original.effect.automaticCover?.evidenceKeyframes.isEmpty ?? true)
                    && !original.effect.keyframes.isEmpty
                let materialized: RegionShape
                if rotatingTrack {
                    // Rect motion cannot preserve a changing polygon orientation. Keep a
                    // containing rectangle at every recorded anchor when handing over to
                    // manual editing, rather than freezing the first polygon and clipping
                    // later rotations. The requested edit takes effect at its chosen time.
                    let initialBounds = original.shape.boundingRect.union(original.effect.shape(original.shape, at: nil).boundingRect)
                    materialized = .rectangle(id: original.shape.id, origin: initialBounds.origin, size: initialBounds.size)
                    let times = Set(original.effect.keyframes.map(\.time)
                        + (original.effect.automaticCover?.evidenceKeyframes.map(\.time) ?? []))
                    old.effect.keyframes = times.sorted().map { time in
                        let tracked = original.shape.interpolatedRect(at: time, baseRect: original.shape.boundingRect, keyframes: original.effect.keyframes)
                        let bounds = tracked.union(original.effect.shape(original.shape, at: time).boundingRect)
                        return RegionKeyframe(time: time, rect: bounds)
                    }
                    let generousAtEdit = time.map { original.shape.interpolatedRect(at: $0, baseRect: original.shape.boundingRect, keyframes: original.effect.keyframes) } ?? original.shape.boundingRect
                    let editedBounds = MotionTrack.shifted(generousAtEdit.union(shown.boundingRect), from: shown.boundingRect, to: shape.boundingRect)
                    shape = .rectangle(id: shape.id, origin: editedBounds.origin, size: editedBounds.size)
                } else {
                    materialized = original.effect.shape(original.shape, at: nil)
                    old.effect.keyframes = original.effect.keyframes.map { frame in
                        RegionKeyframe(time: frame.time, rect: original.effect.shape(original.shape, at: frame.time).boundingRect)
                    }
                }
                if let time, time.isFinite, !old.effect.keyframes.isEmpty, !rotatingTrack {
                    old.effect.keyframes = inserting(RegionKeyframe(time: time, rect: shown.boundingRect), into: old.effect.keyframes)
                }
                old.effect.erasures = old.effect.erasures.map { $0.mapped(from: old.shape.boundingRect, to: materialized.boundingRect) }
                old.shape = materialized
                old.effect.automaticCover = nil
            }
            // Holes live in the base box; whenever the base changes they follow it.
            func rebased(_ base: RegionShape, _ effect: RegionEffect) -> Pair {
                var effect = effect
                effect.erasures = effect.erasures.map { $0.mapped(from: old.shape.boundingRect, to: base.boundingRect) }
                return (base, effect)
            }
            guard let t = time, t.isFinite else { return rebased(shape, old.effect) }
            let from = shown.boundingRect, to = shape.boundingRect
            var effect = old.effect
            guard recording else {
                guard !effect.keyframes.isEmpty else { return rebased(shape, effect) }
                // Whole-path edit: keep the recorded motion and apply this change to every position.
                effect.keyframes = effect.keyframes.map {
                    RegionKeyframe(time: $0.time, rect: MotionTrack.shifted($0.rect, from: from, to: to))
                }
                return rebased(shape.replacing(rect: MotionTrack.shifted(old.shape.boundingRect, from: from, to: to)), effect)
            }
            let start = effect.appliesToEntireVideo ? 0 : effect.timeRange.lowerBound
            let anchor = anchorTime.flatMap { at in
                anchorPairs?.first(where: { $0.shape.id == shape.id }).map { (time: at, rect: displayed($0, at: at).boundingRect) }
            }
            guard let frames = MotionTrack.recording(keyframes: effect.keyframes, from: from, to: to,
                                                     time: t, start: start, anchor: anchor) else {
                return rebased(shape, effect) // First edit at the start time just repositions the region.
            }
            effect.keyframes = frames
            if case .polygon = shape, case .polygon = old.shape {
                // Rect keyframes represent affine movement, not topology. Preserve vertex edits
                // by mapping the edited polygon back into the stable base rectangle.
                return (shape.replacing(rect: old.shape.boundingRect), effect)
            }
            return (old.shape, effect)
        }
    }

    static func scaled(_ pairs: [Pair], from old: CGSize, to new: CGSize) -> [Pair] {
        guard old.width > 0, old.height > 0, new.width > 0, new.height > 0 else { return pairs }
        let sx = new.width / old.width, sy = new.height / old.height
        func rect(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * sx, y: r.minY * sy, width: r.width * sx, height: r.height * sy)
        }
        return pairs.map { pair in
            let shape: RegionShape
            if case .polygon(let id, let points) = pair.shape {
                shape = .polygon(id: id, points: points.map { CGPoint(x: $0.x * sx, y: $0.y * sy) })
            } else { shape = pair.shape.replacing(rect: rect(pair.shape.boundingRect)) }
            var effect = pair.effect
            effect.keyframes = effect.keyframes.map { RegionKeyframe(time: $0.time, rect: rect($0.rect)) }
            effect.erasures = effect.erasures.map { $0.scaled(sx: sx, sy: sy, width: DrawingAnnotation.widthScale(sx: sx, sy: sy)) }
            return (shape, effect)
        }
    }

    static func equal(_ a: [Pair], _ b: [Pair]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.shape == $1.shape && $0.effect == $1.effect }
    }
}
