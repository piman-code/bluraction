import Foundation
import CoreGraphics

/// Detection evidence is local to the generous tracking box; screen resizing never changes
/// the source-pixel safety margin. The stored base shape remains the reversible fallback.
struct AutomaticCover: Codable, Equatable {
    enum Kind: String, Codable { case face, text }
    enum Mode: String, Codable { case recommended, generous }
    struct EvidenceKeyframe: Codable, Equatable {
        var time: Double
        var points: [CGPoint]
        private enum CodingKeys: String, CodingKey { case time, points }
        init(time: Double, points: [CGPoint]) { self.time = time; self.points = points }
        init(from decoder: Decoder) throws {
            try MacEditField.validate(decoder, allowed: ["time", "points"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            time = try c.decode(Double.self, forKey: .time)
            points = try c.decode([CGPoint].self, forKey: .points)
            guard time.isFinite && time >= 0 && AutomaticCover.validPoints(points) else { throw ProjectFile.ProjectError.invalidContent }
        }
    }
    /// Immutable matching intent, independent of the editable layer name.
    var phrases: [String] = []
    var evidenceKeyframes: [EvidenceKeyframe] = []
    var kind: Kind
    var evidencePoints: [CGPoint]
    var sourceSize: CGSize
    var baseNormalizedSize: CGSize
    var safetyMargin: Double = 8
    var mode: Mode = .recommended

    var isValid: Bool {
        Self.validPoints(evidencePoints)
            && phrases.count <= 64 && phrases.allSatisfy { !$0.isEmpty && $0.count <= 200 && PhraseCover.normalize($0) == $0 }
            && evidenceKeyframes.count <= 10_000
            && evidenceKeyframes.allSatisfy { $0.time.isFinite && $0.time >= 0 && Self.validPoints($0.points) }
            && zip(evidenceKeyframes, evidenceKeyframes.dropFirst()).allSatisfy { $0.time < $1.time }
            && [sourceSize.width, sourceSize.height].allSatisfy { $0.isFinite && (1...100_000).contains($0) }
            && [baseNormalizedSize.width, baseNormalizedSize.height].allSatisfy { $0.isFinite && $0 > 0 && $0 <= 4 }
            && safetyMargin.isFinite && (4...32).contains(safetyMargin)
            
    }

    private enum CodingKeys: String, CodingKey { case kind, evidencePoints, sourceSize, baseNormalizedSize, safetyMargin, mode, evidenceKeyframes, phrases }
    init(kind: Kind, evidencePoints: [CGPoint], sourceSize: CGSize, baseNormalizedSize: CGSize,
         safetyMargin: Double = 8, mode: Mode = .recommended, evidenceKeyframes: [EvidenceKeyframe] = []) {
        self.kind = kind; self.evidencePoints = evidencePoints; self.sourceSize = sourceSize
        self.baseNormalizedSize = baseNormalizedSize; self.safetyMargin = safetyMargin; self.mode = mode
        self.evidenceKeyframes = evidenceKeyframes
    }
    init(from decoder: Decoder) throws {
        try MacEditField.validate(decoder, allowed: ["kind", "evidencePoints", "sourceSize", "baseNormalizedSize", "safetyMargin", "mode", "evidenceKeyframes", "phrases"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        evidencePoints = try c.decode([CGPoint].self, forKey: .evidencePoints)
        sourceSize = try c.decode(CGSize.self, forKey: .sourceSize)
        baseNormalizedSize = try c.decode(CGSize.self, forKey: .baseNormalizedSize)
        safetyMargin = try c.decode(Double.self, forKey: .safetyMargin)
        mode = try c.decode(Mode.self, forKey: .mode)
        evidenceKeyframes = try c.decodeIfPresent([EvidenceKeyframe].self, forKey: .evidenceKeyframes) ?? []
        phrases = try c.decodeIfPresent([String].self, forKey: .phrases) ?? []
        guard isValid else { throw ProjectFile.ProjectError.invalidContent }
    }

    func shape(base: RegionShape, rect: CGRect, time: Double?, reviews: [TrackingReview]) -> RegionShape {
        let generous = base.replacing(rect: rect)
        guard mode == .recommended, isValid, rect.width > 0, rect.height > 0 else { return generous }
        // Work in original pixels, including the offset calculation, then map affinely to
        // the current tracking box. Non-square frames therefore keep a uniform pixel margin.
        let canvasSize = CGSize(width: base.boundingRect.width / baseNormalizedSize.width,
                                height: base.boundingRect.height / baseNormalizedSize.height)
        guard canvasSize.width > 0, canvasSize.height > 0 else { return generous }
        let pixelSize = CGSize(width: rect.width / canvasSize.width * sourceSize.width,
                               height: rect.height / canvasSize.height * sourceSize.height)
        let evidence = points(at: time).map { CGPoint(x: $0.x * pixelSize.width, y: $0.y * pixelSize.height) }
        func canvas(_ p: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + p.x / pixelSize.width * rect.width,
                    y: rect.minY + p.y / pixelSize.height * rect.height)
        }
        let recommendation: RegionShape
        switch kind {
        case .text:
            let padded = Self.offset(Self.hull(evidence), by: CGFloat(safetyMargin))
            guard padded.count >= 3 else { return generous }
            recommendation = .polygon(id: base.id, points: padded.map(canvas))
        case .face:
            // Enclose every supplied silhouette point. Widen the ellipse before adding
            // padding; simply fitting the bounding rectangle would expose its corners.
            let xs = evidence.map(\.x), ys = evidence.map(\.y)
            let center = CGPoint(x: (xs.min()! + xs.max()!) / 2, y: (ys.min()! + ys.max()!) / 2)
            let rx = max(0.001, (xs.max()! - xs.min()!) / 2), ry = max(0.001, (ys.max()! - ys.min()!) / 2)
            let factor = max(1, evidence.map { p in
                hypot((p.x - center.x) / rx, (p.y - center.y) / ry)
            }.max() ?? 1)
            let safetyScale = 1 + CGFloat(safetyMargin) / min(rx * factor, ry * factor)
            let paddedRX = rx * factor * safetyScale, paddedRY = ry * factor * safetyScale
            let origin = canvas(CGPoint(x: center.x - paddedRX, y: center.y - paddedRY))
            recommendation = .ellipse(id: base.id, origin: origin,
                size: CGSize(width: 2 * paddedRX / pixelSize.width * rect.width, height: 2 * paddedRY / pixelSize.height * rect.height))
        }
        guard let time, time.isFinite else { return recommendation }
        // Detection gaps expand immediately. Recover over two seconds with a shape
        // that contains the recommendation: ellipse for faces, rectangle for text.
        var fallback: Double = 0
        for review in reviews where review.status == .needsReview && review.isValid {
            if time >= review.start && time <= review.end { fallback = 1; break }
            if time > review.end && time < review.end + 2 { fallback = max(fallback, 1 - (time - review.end) / 2) }
        }
        guard fallback > 0 else { return recommendation }
        let tight = recommendation.boundingRect
        if kind == .face, case .ellipse = generous, case .ellipse = recommendation {
            let legacyRadii = CGSize(width: rect.width / 2, height: rect.height / 2)
            let targetRadii = CGSize(width: tight.width / 2, height: tight.height / 2)
            let targetCenter = CGPoint(x: tight.midX, y: tight.midY)
            let legacyCenter = CGPoint(x: rect.midX, y: rect.midY)
            // In the legacy ellipse's normalized metric, each target point has norm
            // <= center displacement + largest radius ratio (triangle inequality).
            func enclosingScale(center: CGPoint, radii: CGSize) -> CGFloat {
                max(1, hypot((targetCenter.x - center.x) / radii.width,
                             (targetCenter.y - center.y) / radii.height)
                    + max(targetRadii.width / radii.width, targetRadii.height / radii.height))
            }
            let wideScale = enclosingScale(center: legacyCenter, radii: legacyRadii)
            let f = CGFloat(fallback)
            let center = CGPoint(x: targetCenter.x + (legacyCenter.x - targetCenter.x) * f,
                                 y: targetCenter.y + (legacyCenter.y - targetCenter.y) * f)
            var radii = CGSize(width: targetRadii.width + (legacyRadii.width * wideScale - targetRadii.width) * f,
                               height: targetRadii.height + (legacyRadii.height * wideScale - targetRadii.height) * f)
            // Reapply the containment proof during recovery: interpolation alone can
            // clip the target when centers differ or axes have unequal scale.
            let recoveryScale = enclosingScale(center: center, radii: radii)
            radii.width *= recoveryScale; radii.height *= recoveryScale
            return .ellipse(id: base.id, origin: CGPoint(x: center.x - radii.width, y: center.y - radii.height),
                            size: CGSize(width: 2 * radii.width, height: 2 * radii.height))
        }
        let wide = rect.union(tight)
        let f = CGFloat(fallback)
        let bounds = CGRect(x: tight.minX + (wide.minX - tight.minX) * f,
                            y: tight.minY + (wide.minY - tight.minY) * f,
                            width: tight.width + (wide.width - tight.width) * f,
                            height: tight.height + (wide.height - tight.height) * f)
        return .rectangle(id: base.id, origin: bounds.origin, size: bounds.size)
    }

    private static func validPoints(_ points: [CGPoint]) -> Bool {
        (3...512).contains(points.count)
            && points.allSatisfy { $0.x.isFinite && $0.y.isFinite && (-2...3).contains($0.x) && (-2...3).contains($0.y) }
            && hull(points).count >= 3
    }
    private func points(at time: Double?) -> [CGPoint] {
        guard let time, !evidenceKeyframes.isEmpty else { return evidencePoints }
        if let exact = evidenceKeyframes.first(where: { abs($0.time - time) < 0.000001 }) { return exact.points }
        let before = evidenceKeyframes.last(where: { $0.time < time })
        let after = evidenceKeyframes.first(where: { $0.time > time })
        if let before, let after { return Self.hull(before.points + after.points) }
        return before?.points ?? after?.points ?? evidencePoints
    }

    private static func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }
    private static func hull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        var unique: [CGPoint] = []
        for p in sorted where unique.last != p { unique.append(p) }
        guard unique.count >= 3 else { return unique }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for p in unique {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower.last!, p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in unique.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper.last!, p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast()) + Array(upper.dropLast())
    }
    /// Intersection of adjacent outward-offset edges of a counter-clockwise convex hull.
    private static func offset(_ polygon: [CGPoint], by margin: CGFloat) -> [CGPoint] {
        guard polygon.count >= 3 else { return [] }
        var lines: [(point: CGPoint, direction: CGPoint)] = []
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            let d = CGPoint(x: b.x - a.x, y: b.y - a.y), length = hypot(d.x, d.y)
            guard length > 0.000001 else { return [] }
            lines.append((CGPoint(x: a.x + d.y / length * margin, y: a.y - d.x / length * margin), d))
        }
        return lines.indices.map { i in
            let previous = lines[(i + lines.count - 1) % lines.count], next = lines[i]
            let delta = CGPoint(x: next.point.x - previous.point.x, y: next.point.y - previous.point.y)
            let denominator = previous.direction.x * next.direction.y - previous.direction.y * next.direction.x
            guard abs(denominator) > 0.000001 else { return next.point }
            let t = (delta.x * next.direction.y - delta.y * next.direction.x) / denominator
            return CGPoint(x: previous.point.x + t * previous.direction.x, y: previous.point.y + t * previous.direction.y)
        }
    }
}
