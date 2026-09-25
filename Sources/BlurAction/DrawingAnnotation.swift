import AppKit
import CoreGraphics
import CoreText

/// Persistent stroke/shape annotation in the same bottom-left canvas space as blur regions.
/// `points` are the base geometry; on video, `keyframes` move its bounding box over time.
struct DrawingAnnotation: Equatable, Identifiable, Codable {
    /// `eraser` is a brush stroke that clears the drawings listed before it (from its time on).
    enum Kind: String, Equatable, Codable { case rectangle, ellipse, line, freehand, arrow, text, eraser }

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
    /// Text content for `.text`; the text is fitted into the box given by the two points.
    var text: String = ""
    /// Items sharing a group move together.
    var groupID: UUID?

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
    var isFilled: Bool { [.rectangle, .ellipse, .freehand].contains(kind) && fillOpacity > 0 }
    var isEraser: Bool { kind == .eraser }

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
        case .line, .arrow:
            guard points.count >= 2 else { return path }
            path.move(to: first); path.addLine(to: points[1])
        case .freehand, .eraser:
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            if points.count == 1 { path.addLine(to: first) } // a single dab still erases
        case .text:
            path.addRect(bounds)
        }
        return path
    }

    /// Filled triangle at the end point of an arrow.
    var arrowHead: CGPath? {
        guard kind == .arrow, points.count >= 2 else { return nil }
        let tip = points[1], tail = points[0]
        let length = hypot(tip.x - tail.x, tip.y - tail.y)
        guard length > 0 else { return nil }
        let ux = (tip.x - tail.x) / length, uy = (tip.y - tail.y) / length
        let size = max(10, lineWidth * 3.5), half = size * 0.55
        let base = CGPoint(x: tip.x - ux * size, y: tip.y - uy * size)
        let head = CGMutablePath()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: base.x - uy * half, y: base.y + ux * half))
        head.addLine(to: CGPoint(x: base.x + uy * half, y: base.y - ux * half))
        head.closeSubpath()
        return head
    }

    /// Font size for new text boxes from the line-width control (1…20 → 13…70 pt).
    static func fontSize(forLineWidth width: CGFloat) -> CGFloat { 10 + width * 3 }

    /// A text drawing whose box fits `string` at `fontSize`, with its lower-left corner at `origin`.
    static func text(_ string: String, at origin: CGPoint, fontSize: CGFloat, color: NSColor) -> DrawingAnnotation {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font(size: fontSize)]))
        let width = max(fontSize * 0.5, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        var drawing = DrawingAnnotation(kind: .text, points: [origin, CGPoint(x: origin.x + width, y: origin.y + fontSize * 1.25)],
                                        color: color, lineWidth: 2)
        drawing.text = string
        return drawing
    }

    private static func font(size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .semibold) }

    /// Shared drawing for preview, canvas and export (bottom-left coordinates).
    /// Eraser strokes clear everything drawn before them in the same context or transparency layer.
    func render(in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch kind {
        case .eraser:
            context.setBlendMode(.clear)
            context.addPath(path)
            context.setLineWidth(lineWidth)
            context.strokePath()
        case .text:
            renderText(in: context)
        default:
            if isFilled {
                context.addPath(fillPath)
                context.setFillColor(red: red, green: green, blue: blue, alpha: alpha * fillOpacity)
                context.fillPath()
            }
            context.addPath(path)
            context.setStrokeColor(red: red, green: green, blue: blue, alpha: alpha)
            context.setLineWidth(lineWidth)
            context.strokePath()
            if let head = arrowHead {
                context.addPath(head)
                context.setFillColor(red: red, green: green, blue: blue, alpha: alpha)
                context.fillPath()
            }
        }
    }

    /// Text is laid out at a size from the box height, then scaled horizontally to fill the box,
    /// so moving or resizing the box (including motion keyframes) resizes the text with it.
    private func renderText(in context: CGContext) {
        let box = bounds
        guard !text.isEmpty, box.width > 0, box.height > 0 else { return }
        let size = box.height / 1.25
        let attributed = NSAttributedString(string: text, attributes: [
            .font: Self.font(size: size), .foregroundColor: color
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, &descent, nil))
        guard width > 0 else { return }
        context.translateBy(x: box.minX, y: box.minY + descent + (box.height - size * 1.2) / 2)
        context.scaleBy(x: box.width / width, y: 1)
        context.textMatrix = .identity
        context.textPosition = .zero
        CTLineDraw(line, context)
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
        if kind == .text { return bounds.insetBy(dx: -4, dy: -4).contains(point) }
        if isFilled, fillPath.contains(point) { return true }
        return path.copy(strokingWithWidth: max(12, lineWidth + 8), lineCap: .round, lineJoin: .round, miterLimit: 1)
            .contains(point)
    }

    func scaled(from old: CGSize, to new: CGSize) -> DrawingAnnotation {
        guard old.width > 0, old.height > 0, new.width > 0, new.height > 0 else { return self }
        let sx = new.width / old.width, sy = new.height / old.height
        var result = self
        result.points = points.map { CGPoint(x: $0.x * sx, y: $0.y * sy) }
        // Line and eraser widths are canvas points; scale them with the picture too.
        result.lineWidth = lineWidth * (sx + sy) / 2
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
        result.text = edited.text; result.groupID = edited.groupID
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
