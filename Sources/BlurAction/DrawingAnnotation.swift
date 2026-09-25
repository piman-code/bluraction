import AppKit
import CoreGraphics

/// Persistent stroke/shape annotation in the same bottom-left canvas space as blur regions.
/// `points` are the base geometry; on video, `keyframes` move its bounding box over time.
struct DrawingAnnotation: Equatable, Identifiable {
    enum Kind: Equatable { case rectangle, ellipse, line, freehand }

    var id: UUID
    var kind: Kind
    var points: [CGPoint]
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat
    var lineWidth: CGFloat
    /// 0 = outline only; otherwise the fill uses the stroke color at this opacity (lines never fill).
    var fillOpacity: CGFloat = 0
    /// Video time interval in seconds; `0...0` means the whole video (same sentinel as regions).
    var timeRange: ClosedRange<Double> = 0...0
    var keyframes: [RegionKeyframe] = []

    init(id: UUID = UUID(), kind: Kind, points: [CGPoint], color: NSColor = .systemYellow, lineWidth: CGFloat = 4,
         fillOpacity: CGFloat = 0) {
        self.id = id
        self.kind = kind
        let color = (color.usingColorSpace(.sRGB) ?? .systemYellow)
        self.red = color.redComponent; self.green = color.greenComponent
        self.blue = color.blueComponent; self.alpha = color.alphaComponent
        self.points = points
        self.lineWidth = lineWidth
        self.fillOpacity = fillOpacity
    }

    var color: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var isFilled: Bool { kind != .line && fillOpacity > 0 }

    mutating func setColor(_ color: NSColor) {
        guard let c = color.usingColorSpace(.sRGB) else { return }
        red = c.redComponent; green = c.greenComponent; blue = c.blueComponent; alpha = c.alphaComponent
    }

    var path: CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        switch kind {
        case .rectangle, .ellipse:
            guard points.count >= 2 else { return path }
            let rect = CGRect(x: min(first.x, points[1].x), y: min(first.y, points[1].y),
                              width: abs(points[1].x - first.x), height: abs(points[1].y - first.y))
            if kind == .rectangle { path.addRect(rect) } else { path.addEllipse(in: rect) }
        case .line:
            guard points.count >= 2 else { return path }
            path.move(to: first); path.addLine(to: points[1])
        case .freehand:
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
        }
        return path
    }

    /// Closed outline used for filling (a freehand stroke closes back to its first point).
    var fillPath: CGPath {
        guard kind == .freehand else { return path }
        let path = CGMutablePath(); path.addPath(self.path); path.closeSubpath()
        return path
    }

    var bounds: CGRect {
        guard let first = points.first else { return .zero }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
    }

    var appliesToEntireVideo: Bool { timeRange.lowerBound == 0 && timeRange.upperBound == 0 }

    func isVisible(at time: Double?) -> Bool {
        guard let time else { return true }
        guard time.isFinite else { return false }
        return appliesToEntireVideo || timeRange.contains(time)
    }

    /// Geometry at `time` (nil = still image: base geometry).
    func displayed(at time: Double?) -> DrawingAnnotation {
        guard let time, !keyframes.isEmpty else { return self }
        return replacingBounds(MotionTrack.rect(at: time, base: bounds, keyframes: keyframes))
    }

    func replacingBounds(_ rect: CGRect) -> DrawingAnnotation {
        let old = bounds
        var result = self
        result.points = points.map { MotionTrack.map($0, from: old, to: rect) }
        return result
    }

    func hitTest(_ point: CGPoint) -> Bool {
        if isFilled, fillPath.contains(point) { return true }
        return path.copy(strokingWithWidth: max(12, lineWidth + 8), lineCap: .round, lineJoin: .round, miterLimit: 1)
            .contains(point)
    }

    func scaled(from old: CGSize, to new: CGSize) -> DrawingAnnotation {
        guard old.width > 0, old.height > 0, new.width > 0, new.height > 0 else { return self }
        let sx = new.width / old.width, sy = new.height / old.height
        var result = self
        result.points = points.map { CGPoint(x: $0.x * sx, y: $0.y * sy) }
        result.keyframes = keyframes.map {
            RegionKeyframe(time: $0.time, rect: CGRect(x: $0.rect.minX * sx, y: $0.rect.minY * sy,
                                                       width: $0.rect.width * sx, height: $0.rect.height * sy))
        }
        return result
    }

    /// Commit a displayed-geometry edit made at `time`, with the same motion rules as regions.
    func applyingEdit(_ edited: DrawingAnnotation, time: Double?, recording: Bool,
                      anchor: (time: Double, annotation: DrawingAnnotation)? = nil) -> DrawingAnnotation {
        var result = self
        result.kind = edited.kind; result.lineWidth = edited.lineWidth; result.fillOpacity = edited.fillOpacity
        result.red = edited.red; result.green = edited.green; result.blue = edited.blue; result.alpha = edited.alpha
        let shown = displayed(at: time)
        guard edited.points != shown.points else { return result }
        guard let t = time, t.isFinite else { result.points = edited.points; return result }
        let from = shown.bounds, to = edited.bounds
        guard recording else {
            guard !keyframes.isEmpty else { result.points = edited.points; return result }
            result.points = edited.replacingBounds(MotionTrack.shifted(bounds, from: from, to: to)).points
            result.keyframes = keyframes.map {
                RegionKeyframe(time: $0.time, rect: MotionTrack.shifted($0.rect, from: from, to: to))
            }
            return result
        }
        let start = appliesToEntireVideo ? 0 : timeRange.lowerBound
        let anchorRect = anchor.map { (time: $0.time, rect: $0.annotation.displayed(at: $0.time).bounds) }
        guard let frames = MotionTrack.recording(keyframes: keyframes, from: from, to: to, time: t,
                                                 start: start, anchor: anchorRect) else {
            result.points = edited.points // First edit at the start time just repositions the drawing.
            return result
        }
        result.keyframes = frames
        return result
    }
}

extension RGBAColor {
    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        self.init(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: c.alphaComponent)
    }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}
