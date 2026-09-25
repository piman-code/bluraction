import CoreGraphics

/// Time-based rectangle tracks shared by blur regions and drawings (canvas bottom-left coords).
enum MotionTrack {
    /// Keyframes closer than this are the same moment. Far below one frame even at 240 fps,
    /// so stepping frame by frame never overwrites the previous frame's position.
    static let sameTime = 0.001

    /// Linear interpolation between keyframes; before the first keyframe the base rect holds.
    static func rect(at t: Double, base: CGRect, keyframes: [RegionKeyframe]) -> CGRect {
        guard t.isFinite else { return base }
        // Stable ordering makes duplicate timestamps deterministic: last supplied wins.
        let frames = keyframes.enumerated().filter { $0.element.time.isFinite }
            .sorted { $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time }
            .map(\.element)
        guard let first = frames.first, t >= first.time else { return base }
        guard let a = frames.last(where: { $0.time <= t }) else { return base }
        guard let b = frames.first(where: { $0.time > t }) else { return a.rect }
        let u = CGFloat((t - a.time) / (b.time - a.time))
        return CGRect(x: a.rect.minX + (b.rect.minX - a.rect.minX) * u,
                      y: a.rect.minY + (b.rect.minY - a.rect.minY) * u,
                      width: a.rect.width + (b.rect.width - a.rect.width) * u,
                      height: a.rect.height + (b.rect.height - a.rect.height) * u)
    }

    /// Map a point between bounding boxes. A zero-extent axis (a straight line) only translates.
    static func map(_ p: CGPoint, from old: CGRect, to new: CGRect) -> CGPoint {
        CGPoint(x: new.minX + (old.width > 0 ? (p.x - old.minX) / old.width * new.width : p.x - old.minX),
                y: new.minY + (old.height > 0 ? (p.y - old.minY) / old.height * new.height : p.y - old.minY))
    }

    /// Apply the position/size change `from → to` to another rect of the same track,
    /// so editing with motion recording off moves the whole recorded path.
    static func shifted(_ r: CGRect, from: CGRect, to: CGRect) -> CGRect {
        // A zero extent (straight line) stays zero; any other extent never collapses below 1pt.
        func size(_ value: CGFloat, _ delta: CGFloat) -> CGFloat { value == 0 ? 0 : max(1, value + delta) }
        return CGRect(x: r.minX + to.minX - from.minX, y: r.minY + to.minY - from.minY,
                      width: size(r.width, to.width - from.width), height: size(r.height, to.height - from.height))
    }

    static func inserting(_ frame: RegionKeyframe, into frames: [RegionKeyframe]) -> [RegionKeyframe] {
        var result = frames.filter { abs($0.time - frame.time) >= sameTime }
        result.append(frame)
        return result.sorted { $0.time < $1.time }
    }

    /// Keyframes for an edit that changes the displayed rect from `from` to `to` at time `t`.
    /// - A first edit at the item's start time just repositions it (returns nil: edit the base).
    /// - A first edit later holds the pre-edit placement from `start`, so the item glides to `t`.
    /// - During playback `anchor` (gesture start) keeps the waiting time before a drag stationary.
    static func recording(keyframes: [RegionKeyframe], from: CGRect, to: CGRect, time t: Double, start: Double,
                          anchor: (time: Double, rect: CGRect)?) -> [RegionKeyframe]? {
        var frames = keyframes
        let hasPlaybackAnchor = anchor.map { $0.time.isFinite && $0.time < t } ?? false
        if frames.isEmpty {
            guard hasPlaybackAnchor || t - start >= sameTime else { return nil }
            if t - start >= sameTime {
                frames = inserting(RegionKeyframe(time: max(0, start), rect: from), into: frames)
            }
        }
        if hasPlaybackAnchor, let anchor {
            frames = inserting(RegionKeyframe(time: max(0, anchor.time), rect: anchor.rect), into: frames)
        }
        return inserting(RegionKeyframe(time: max(0, t), rect: to), into: frames)
    }
}
