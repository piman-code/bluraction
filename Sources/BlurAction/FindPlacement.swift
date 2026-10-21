import Foundation
import CoreGraphics

/// Pure helpers for placing covers from an auto-find. No editor state.
enum FindPlacement {
    /// A fitted cover from detection evidence in canvas-normalized `box` coordinates,
    /// or nil when the evidence is unusable.
    static func automaticCover(kind: AutomaticCover.Kind, points: [CGPoint], box: CGRect,
                               sourceSize: CGSize) -> AutomaticCover? {
        guard box.width > 0, box.height > 0, !points.isEmpty else { return nil }
        let local = points.map { CGPoint(x: ($0.x - box.minX) / box.width, y: ($0.y - box.minY) / box.height) }
        let value = AutomaticCover(kind: kind, evidencePoints: local, sourceSize: sourceSize,
                                   baseNormalizedSize: box.size)
        return value.isValid ? value : nil
    }

    /// Points spread over the cover this find would make (an oval for faces, the box for text);
    /// the place is skipped only when existing areas' actual shapes hold every one (a sliver left showing gets covered).
    /// `covering` are the displayed shapes of active areas without eraser marks, in canvas coordinates.
    static func isAlreadyCovered(_ detection: AutoDetector.Detection, target: AutoDetector.Target,
                                 canvasSize size: CGSize, sourceSize: CGSize, covering: [RegionShape]) -> Bool {
        guard !covering.isEmpty else { return false }
        let box = detection.generousBox
        let rect = CGRect(x: box.minX * size.width, y: box.minY * size.height, width: box.width * size.width, height: box.height * size.height)
        let base: RegionShape = target == .faces ? .ellipse(id: UUID(), origin: rect.origin, size: rect.size)
            : .rectangle(id: UUID(), origin: rect.origin, size: rect.size)
        let proposed = detection.reliable ? automaticCover(kind: target == .faces ? .face : .text,
            points: detection.evidencePoints, box: box, sourceSize: sourceSize)?.shape(base: base, rect: rect, time: nil, reviews: []) : nil
        let area = proposed?.boundingRect ?? rect
        var inside = 0, total = 0
        for row in 0..<12 {
            for column in 0..<12 {
                let u = (Double(column) + 0.5) / 12, v = (Double(row) + 0.5) / 12
                if proposed == nil && target == .faces, (u - 0.5) * (u - 0.5) + (v - 0.5) * (v - 0.5) > 0.25 { continue }
                let point = CGPoint(x: area.minX + u * area.width, y: area.minY + v * area.height)
                if let proposed, !proposed.contains(point: point, threshold: 0) { continue }
                total += 1
                if covering.contains(where: { $0.contains(point: point, threshold: 0.5) }) { inside += 1 }
            }
        }
        return total > 0 && inside == total
    }
}
