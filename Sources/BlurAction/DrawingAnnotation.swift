import AppKit
import CoreGraphics
import CoreText

/// Persistent stroke/shape annotation in the same bottom-left canvas space as blur regions.
/// `points` are the base geometry; on video, `keyframes` move its bounding box over time.
struct DrawingAnnotation: Equatable, Identifiable, Codable {
    enum Kind: String, Equatable, Codable { case rectangle, ellipse, line, freehand, arrow, text }

    typealias Erasure = EraseStroke

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
    /// Text content for `.text` (lines separated by "\n"); it is fitted into the box of the two points.
    var text: String = ""
    /// Items sharing a group move together.
    var groupID: UUID?
    var erasures: [EraseStroke] = []
    /// Layer name shown in the layer list (nil = automatic name).
    var name: String?
    /// Hidden layers are left out of the preview and the exported file.
    var hidden = false
    /// Locked layers cannot be selected, moved or erased on the canvas.
    var locked = false
    /// Text font family (nil = system font) and weight.
    var fontName: String?
    var bold = true
    /// Optional box drawn behind text (caption style).
    var textBackground: RGBAColor?

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
        case .freehand:
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
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

    // MARK: Text

    /// Font size for new text boxes from the line-width control (1…20 → 13…70 pt).
    static func fontSize(forLineWidth width: CGFloat) -> CGFloat { 10 + width * 3 }

    static let lineHeightFactor: CGFloat = 1.25

    /// Font families offered in the text controls (only installed ones are listed).
    static var availableFontFamilies: [String] {
        ["Apple SD Gothic Neo", "AppleMyungjo", "Helvetica Neue", "Georgia", "Menlo", "Noteworthy"]
            .filter { fontIsAvailable($0) }
    }

    /// Availability and rendering interpret the same portable generic names.
    /// Keep the requested spelling in the annotation; only resolve at rendering.
    static func fontIsAvailable(_ family: String?, bold: Bool = false, size: CGFloat = 12) -> Bool {
        resolvedFont(size: size, family: family, bold: bold) != nil
    }

    private static func resolvedFont(size: CGFloat, family: String?, bold: Bool) -> NSFont? {
        let size = max(1, size)
        let weight: NSFont.Weight = bold ? .semibold : .regular
        func named(_ name: String) -> NSFont? {
            NSFontManager.shared.font(withFamily: name, traits: bold ? .boldFontMask : [], weight: 5, size: size)
                ?? NSFont(name: name, size: size)
        }
        switch family?.lowercased() ?? "" {
        case "", "system", "sans serif", "sans-serif":
            return .systemFont(ofSize: size, weight: weight)
        case "monospace":
            return .monospacedSystemFont(ofSize: size, weight: weight)
        case "serif":
            guard let descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor.withDesign(.serif) else { return nil }
            return NSFont(descriptor: descriptor, size: size)
        case "cursive":
            return ["Apple Chancery", "Snell Roundhand", "Zapfino"].lazy.compactMap(named).first
        case "fantasy":
            return ["Papyrus", "Herculanum", "Copperplate"].lazy.compactMap(named).first
        default:
            return family.flatMap(named)
        }
    }

    static func font(size: CGFloat, family: String?, bold: Bool) -> NSFont {
        let size = max(1, size)
        if let resolved = resolvedFont(size: size, family: family, bold: bold) { return resolved }
        // Missing explicit requests remain in the model. Output validation must
        // refuse them; this fallback is only a preview while editing old files.
        return .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    private var textLines: [String] {
        text.components(separatedBy: "\n").map { $0.isEmpty ? " " : $0 }
    }

    /// Natural size of the text at `fontSize` (widest line × line count).
    func naturalTextSize(fontSize: CGFloat) -> CGSize {
        let font = Self.font(size: fontSize, family: fontName, bold: bold)
        let width = textLines.map { line in
            CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [.font: font])), nil, nil, nil))
        }.max() ?? 0
        return CGSize(width: max(fontSize * 0.5, width), height: fontSize * Self.lineHeightFactor * CGFloat(textLines.count))
    }

    /// A text drawing whose box fits `string` at `fontSize`, with its lower-left corner at `origin`.
    static func text(_ string: String, at origin: CGPoint, fontSize: CGFloat, color: NSColor,
                     fontName: String? = nil, bold: Bool = true, background: RGBAColor? = nil) -> DrawingAnnotation {
        var drawing = DrawingAnnotation(kind: .text, points: [origin, origin], color: color, lineWidth: 2)
        drawing.text = string
        drawing.fontName = fontName
        drawing.bold = bold
        drawing.textBackground = background
        let size = drawing.naturalTextSize(fontSize: fontSize)
        drawing.points = [origin, CGPoint(x: origin.x + size.width, y: origin.y + size.height)]
        return drawing
    }

    /// Current font size implied by the box height and line count.
    var textFontSize: CGFloat { bounds.height / (Self.lineHeightFactor * CGFloat(max(1, textLines.count))) }

    /// Replaces the text (or font), keeping the font size and the top-left corner; recorded boxes and
    /// holes follow the box change.
    func withText(_ string: String, fontName: String?? = nil, bold: Bool? = nil) -> DrawingAnnotation {
        guard kind == .text else { return self }
        let size = textFontSize
        let oldBox = bounds
        var updated = self
        updated.text = string
        if let fontName { updated.fontName = fontName }
        if let bold { updated.bold = bold }
        let natural = updated.naturalTextSize(fontSize: size)
        let newBox = CGRect(x: oldBox.minX, y: oldBox.maxY - natural.height, width: natural.width, height: natural.height)
        updated.points = [newBox.origin, CGPoint(x: newBox.maxX, y: newBox.maxY)]
        updated.erasures = erasures.map { $0.mapped(from: oldBox, to: newBox) }
        let wr = oldBox.width > 0 ? newBox.width / oldBox.width : 1
        let hr = oldBox.height > 0 ? newBox.height / oldBox.height : 1
        updated.keyframes = keyframes.map {
            RegionKeyframe(time: $0.time, rect: CGRect(x: $0.rect.minX, y: $0.rect.maxY - $0.rect.height * hr,
                                                       width: $0.rect.width * wr, height: $0.rect.height * hr))
        }
        return updated
    }

    // MARK: Rendering

    /// Shared drawing for preview, canvas and export (bottom-left coordinates). Erasures active at
    /// `time` (nil = still image: all) are cleared from this drawing only, inside its own layer.
    func render(in context: CGContext, time: Double?) {
        let active = erasures.filter { $0.isActive(at: time) }
        if !active.isEmpty { context.beginTransparencyLayer(auxiliaryInfo: nil) }
        renderShape(in: context)
        if !active.isEmpty {
            context.saveGState()
            context.setBlendMode(.clear)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            for erasure in active {
                context.addPath(EraseStroke.path(erasure.points))
                context.setLineWidth(erasure.width)
                context.strokePath()
            }
            context.restoreGState()
            context.endTransparencyLayer()
        }
    }

    static func strokePath(_ points: [CGPoint]) -> CGPath { EraseStroke.path(points) }

    private func renderShape(in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch kind {
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

    /// Uniform scale for widths when a box maps to another (geometric mean of the non-zero axes),
    /// so a round trip through any aspect ratio returns the original width exactly.
    static func widthScale(sx: CGFloat, sy: CGFloat) -> CGFloat {
        let factors = [sx, sy].filter { $0.isFinite && $0 > 0 }
        guard !factors.isEmpty else { return 1 }
        return factors.count == 2 ? (factors[0] * factors[1]).squareRoot() : factors[0]
    }

    /// Lines are laid out at a size from the box height, then scaled horizontally to fill the box,
    /// so moving or resizing the box (including motion keyframes) resizes the text with it.
    private func renderText(in context: CGContext) {
        let box = bounds
        guard !text.isEmpty, box.width > 0, box.height > 0 else { return }
        let lines = textLines
        let lineHeight = box.height / CGFloat(lines.count)
        let size = lineHeight / Self.lineHeightFactor
        if let background = textBackground, background.isValid {
            let pad = size * 0.2
            context.addPath(CGPath(roundedRect: box.insetBy(dx: -pad, dy: -pad * 0.5), cornerWidth: pad, cornerHeight: pad, transform: nil))
            context.setFillColor(red: background.red, green: background.green, blue: background.blue, alpha: background.alpha)
            context.fillPath()
        }
        let font = Self.font(size: size, family: fontName, bold: bold)
        let ctLines = lines.map {
            CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: [.font: font, .foregroundColor: color]))
        }
        let widest = ctLines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }.max() ?? 0
        guard widest > 0 else { return }
        for (index, line) in ctLines.enumerated() {
            var descent: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, nil, &descent, nil)
            let lineMinY = box.maxY - CGFloat(index + 1) * lineHeight
            context.saveGState()
            context.translateBy(x: box.minX, y: lineMinY + descent + (lineHeight - size * 1.2) / 2)
            context.scaleBy(x: box.width / widest, y: 1)
            context.textMatrix = .identity
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }
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

    /// Shown at `time` (nil = still image). Hidden layers are never shown.
    func isVisible(at time: Double?) -> Bool {
        guard !hidden else { return false }
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
        // Holes move with the shape; like the stroke width, their width is unchanged by a resize.
        result.erasures = erasures.map { $0.mapped(from: old, to: rect) }
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
        // Widths are canvas points; scale them with the picture too (exactly invertible).
        let widthScale = Self.widthScale(sx: sx, sy: sy)
        result.lineWidth = lineWidth * widthScale
        result.erasures = erasures.map { $0.scaled(sx: sx, sy: sy, width: widthScale) }
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
        result.fontName = edited.fontName; result.bold = edited.bold; result.textBackground = edited.textBackground
        result.name = edited.name; result.hidden = edited.hidden; result.locked = edited.locked
        result.red = edited.red; result.green = edited.green; result.blue = edited.blue; result.alpha = edited.alpha
        let shown = displayed(at: time)
        guard edited.points != shown.points else { return result }
        // Edits are moves/resizes of the box, so holes are re-derived from the box change rather
        // than trusted from the caller (which may have moved only the points).
        var edited = edited
        edited.erasures = shown.replacingBounds(edited.bounds).erasures
        guard let t = time, t.isFinite else { result.points = edited.points; result.erasures = edited.erasures; return result }
        let from = shown.bounds, to = edited.bounds
        guard recording else {
            guard !keyframes.isEmpty else { result.points = edited.points; result.erasures = edited.erasures; return result }
            let base = edited.replacingBounds(MotionTrack.shifted(bounds, from: from, to: to))
            result.points = base.points
            result.erasures = base.erasures
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
            result.erasures = edited.erasures
            return result
        }
        result.keyframes = frames
        return result
    }
}

extension DrawingAnnotation {
    /// Fields added after 0.4 are optional in files so older projects still open.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), kind: try c.decode(Kind.self, forKey: .kind),
                  points: try c.decode([CGPoint].self, forKey: .points))
        red = try c.decode(CGFloat.self, forKey: .red)
        green = try c.decode(CGFloat.self, forKey: .green)
        blue = try c.decode(CGFloat.self, forKey: .blue)
        alpha = try c.decode(CGFloat.self, forKey: .alpha)
        lineWidth = try c.decode(CGFloat.self, forKey: .lineWidth)
        fillOpacity = try c.decodeIfPresent(CGFloat.self, forKey: .fillOpacity) ?? 0
        timeRange = try c.decodeIfPresent(ClosedRange<Double>.self, forKey: .timeRange) ?? 0...0
        keyframes = try c.decodeIfPresent([RegionKeyframe].self, forKey: .keyframes) ?? []
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        erasures = try c.decodeIfPresent([EraseStroke].self, forKey: .erasures) ?? []
        name = try c.decodeIfPresent(String.self, forKey: .name)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName)
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? true
        textBackground = try c.decodeIfPresent(RGBAColor.self, forKey: .textBackground)
    }
}

extension RGBAColor {
    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        self.init(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: c.alphaComponent)
    }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}
