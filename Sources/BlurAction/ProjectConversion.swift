import Foundation
import CoreGraphics

/// Pure conversions between editor items and project contents. No editor state.
/// Project geometry is normalized to a 1×1 bottom-left canvas.
enum ProjectConversion {
    static let unit = CGSize(width: 1, height: 1)

    /// Cover regions as project regions, in the coordinates they already have.
    static func regions(_ pairs: [RegionEditing.Pair]) -> [ProjectFile.Region] {
        pairs.map { ProjectFile.Region(shape: $0.shape, effect: $0.effect) }
    }

    /// Cover regions scaled from the canvas to the 1×1 project canvas.
    static func normalizedRegions(_ pairs: [RegionEditing.Pair], from size: CGSize) -> [ProjectFile.Region] {
        regions(RegionEditing.scaled(pairs, from: size, to: unit))
    }

    /// Drawings scaled from the canvas to the 1×1 project canvas.
    static func normalizedDrawings(_ drawings: [DrawingAnnotation], from size: CGSize) -> [DrawingAnnotation] {
        drawings.map { $0.scaled(from: size, to: unit) }
    }

    /// A time range clipped to a video of `duration` seconds; nil means no clipping (images, or
    /// clipping turned off). The whole-video sentinel 0...0 and ranges inside the video are kept.
    static func clipped(_ range: ClosedRange<Double>, toDuration duration: Double?) -> ClosedRange<Double> {
        guard let duration, !(range.lowerBound == 0 && range.upperBound == 0), range.upperBound > duration else { return range }
        return min(range.lowerBound, duration)...duration
    }

    /// A project's items scaled onto a canvas of `size`, with times clipped to `clipDuration`.
    /// IDs and groups are kept (opening a project).
    static func appliedItems(_ project: ProjectFile, canvasSize size: CGSize,
                             clipDuration: Double?) -> (regions: [RegionEditing.Pair], drawings: [DrawingAnnotation]) {
        let regions = RegionEditing.scaled(project.regions.map { ($0.shape, $0.effect) }, from: unit, to: size).map { pair -> RegionEditing.Pair in
            var effect = pair.effect
            effect.timeRange = clipped(effect.timeRange, toDuration: clipDuration)
            return (pair.shape, effect)
        }
        let drawings = project.drawings.map { drawing -> DrawingAnnotation in
            var scaled = drawing.scaled(from: unit, to: size)
            scaled.timeRange = clipped(scaled.timeRange, toDuration: clipDuration)
            return scaled
        }
        return (regions, drawings)
    }

    /// A project's items as new items on a canvas of `size` (importing into a session): every item
    /// gets a new ID, each old group a new group ID shared by its members, and times are clipped
    /// to `clipDuration`.
    static func importedItems(_ project: ProjectFile, canvasSize size: CGSize,
                              clipDuration: Double?) -> (regions: [RegionEditing.Pair], drawings: [DrawingAnnotation]) {
        var groups: [UUID: UUID] = [:]
        func newGroup(_ id: UUID?) -> UUID? { id.map { old in groups[old] ?? { let new = UUID(); groups[old] = new; return new }() } }
        let regions = RegionEditing.scaled(project.regions.map { ($0.shape, $0.effect) }, from: unit, to: size).map { pair -> RegionEditing.Pair in
            let id = UUID()
            let shape: RegionShape
            switch pair.shape {
            case .rectangle(_, let o, let s): shape = .rectangle(id: id, origin: o, size: s)
            case .ellipse(_, let o, let s): shape = .ellipse(id: id, origin: o, size: s)
            case .polygon(_, let p): shape = .polygon(id: id, points: p)
            }
            var effect = pair.effect
            effect.groupID = newGroup(effect.groupID)
            effect.timeRange = clipped(effect.timeRange, toDuration: clipDuration)
            return (shape, effect)
        }
        let drawings = project.drawings.map { drawing -> DrawingAnnotation in
            var copy = drawing.scaled(from: unit, to: size)
            copy.id = UUID()
            copy.groupID = newGroup(drawing.groupID)
            copy.timeRange = clipped(copy.timeRange, toDuration: clipDuration)
            return copy
        }
        return (regions, drawings)
    }
}
