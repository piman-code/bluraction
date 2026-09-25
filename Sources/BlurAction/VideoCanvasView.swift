import AppKit
import AVFoundation
import AVKit
import CoreGraphics
import UniformTypeIdentifiers
import os

/// 비디오 영역 위에 떠 있는 영역 편집 + 드래그앤드롭 통합 캔버스.
final class VideoCanvasView: NSView {
    enum Mode {
        case rectangle, ellipse, polygonClick, polygonFree, drawRectangle, drawEllipse, drawLine, drawFreehand, erase
        var isDrawing: Bool { [.drawRectangle, .drawEllipse, .drawLine, .drawFreehand].contains(self) }
    }

    // 콜백
    var regionsBinding: (() -> [RegionShape])?
    var regionsUpdate: (([RegionShape]) -> Void)?
    /// Drawings as displayed at the current time (video motion already applied).
    var annotationsBinding: (() -> [DrawingAnnotation])?
    var annotationAdded: ((DrawingAnnotation) -> Void)?
    /// A displayed-geometry edit (move/resize) of an existing drawing.
    var annotationChanged: ((DrawingAnnotation) -> Void)?
    /// Eraser and Delete: (blur region IDs, drawing IDs).
    var itemsErased: ((Set<UUID>, Set<UUID>) -> Void)?
    var annotationSelectionChange: ((UUID?) -> Void)?
    var rightClickOnAnnotation: ((UUID, NSPoint) -> Void)?
    /// (stroke color, line width, fill opacity) for new drawings.
    var annotationStyleBinding: (() -> (NSColor, CGFloat, CGFloat))?
    /// When set, the next click samples a color at that point instead of editing.
    var colorPickHandler: ((NSPoint) -> Void)? {
        didSet { updateCursorAtCurrentMouseLocation() }
    }
    var colorPickCancelled: (() -> Void)?
    /// Single-key shortcuts (tools, frame step). Returns true when handled.
    var shortcutHandler: ((Character) -> Bool)?
    /// Centers of the selected item's recorded positions, drawn as its motion path.
    var motionPathProvider: (() -> [CGPoint])?
    var editingBegan: (() -> Void)?
    var editingEnded: (() -> Void)?
    var isEditable = false {
        didSet {
            if isEditable { updateCursorAtCurrentMouseLocation() }
            else { resetCursor() }
        }
    }
    private var dragShape: RegionShape?
    private var hoverTracking: NSTrackingArea?
    private var displayedCursor: NSCursor?
    var modeBinding: (() -> Mode)?
    var modeUpdate: ((Mode) -> Void)?
    var viewSizeBinding: (() -> CGSize)?
    var videoSizeBinding: (() -> CGSize)?
    var onFileLoad: ((URL) -> Void)?
    var liveBlurRefreshCallback: (() -> Void)?
    var addRegionHandler: (() -> Void)?
    var deleteSelectedHandler: (() -> Void)?
    var playPauseHandler: (() -> Void)?
    var selectionChange: ((UUID?) -> Void)?
    var regionDoubleClickHandler: ((UUID) -> Void)?
    /// 키프레임 자동 기록 모드 (▶ 누르면 true). true면 drag 중 30Hz로 키프레임 추가.
    var recordingKeyframes: Bool = false
    /// 현재 비디오 시간 (초). 키프레임 기록 시 사용.
    var currentVideoTime: Double = 0
    /// 키프레임 기록 콜백. MainWindowController가 pairs 갱신.
    /// - Parameter id: 영역 ID
    /// - Parameter rect: 캔버스 좌표 rect
    var recordKeyframeHandler: ((UUID, NSRect) -> Void)?
    /// 영역 ID → 해당 영역의 효과(시간·feather 등)
    var effectForID: ((UUID) -> RegionEffect?)?
    /// 현재 재생 시간(초) — 활성 영역 색 구분용
    var currentTimeProvider: (() -> Double)?
    /// Capture the playhead at mouse-down / the first polygon vertex, not at commit.
    var creationTimeProvider: (() -> Double?)?
    private(set) var creationStartTime: Double?
    /// 우클릭 컨텍스트 메뉴 콜백 (영역 id, 마우스 위치)
    var rightClickOnRegion: ((UUID?, NSPoint) -> Void)?

    /// aspect-fit으로 표시되는 비디오 프레임의 프레임 (캔버스 좌표).
    /// 외부(MainContainer)에서 aspectFitVideo frame과 동기화해 설정해줌.
    /// 영역 좌표계 기준 = canvas bounds. 비디오와 정확히 일치.
    /// drawRegion, hitTest, drag clamp 모두 이 좌표 사용.
    var displayRect: NSRect = .zero
    weak var hostContainer: NSView?

    var emptyHint: String = ""

    private var selectedID: UUID? = nil
    private var dragStart: NSPoint = .zero
    private var dragLast: NSPoint = .zero
    private var activeDrag: DragKind? = nil
    private var activeHandle: HandlePos? = nil
    /// resize 시작 시 잡은 handle의 anchor corner (shift 정사각형화에 사용).
    private var activeHandleAnchor: NSPoint? = nil
    private var polygonBuffer: [NSPoint] = []
    private var annotationBuffer: [NSPoint] = []
    private var selectedAnnotationID: UUID?
    private var dragAnnotation: DrawingAnnotation?
    private var annotationHandleAnchor: NSPoint?
    private var eraseHoverID: UUID?
    private var lastMouseLocation: NSPoint? = nil
    /// drag 중 마지막 키프레임 기록 시간. 30Hz 간격 체크용.
    private var lastKeyframeTime: Double = -1

    private enum DragKind { case create, createEllipse, polygonFree, move, resize, annotation, annotationMove, annotationResize, erase }
    private enum HandlePos { case tl, tr, bl, br, vertex(Int), topEdge, bottomEdge, leftEdge, rightEdge }
    enum ResizeCursorDirection: Equatable { case descendingDiagonal, ascendingDiagonal, horizontal, vertical }

    private static let descendingCursor = diagonalCursor(ascending: false)
    private static let ascendingCursor = diagonalCursor(ascending: true)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        registerForDraggedTypes([.fileURL])
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point)
    }

    override func layout() {
        super.layout()
        // displayRect = canvas.bounds 자체 (canvas 좌표 = 비디오 frame).
        displayRect = NSRect(origin: .zero, size: bounds.size)
        refreshOverlay()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastMouseLocation = clamped(point)
        updateCursor(at: point)
        if !polygonBuffer.isEmpty { refreshOverlay() }
        if modeBinding?() == .erase {
            let hover = eraseTargets(at: lastMouseLocation ?? point)
            let id = hover.regions.first ?? hover.drawings.first
            if id != eraseHoverID { eraseHoverID = id; refreshOverlay() }
        } else if eraseHoverID != nil { eraseHoverID = nil; refreshOverlay() }
    }

    override func mouseEntered(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        resetCursor()
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { window?.makeFirstResponder(self) }
        else { resetCursor() }
    }

    func refreshOverlay() {
        setNeedsDisplay(bounds)
    }

    func selectRegion(id: UUID) {
        if selectedAnnotationID != nil { selectedAnnotationID = nil; annotationSelectionChange?(nil) }
        selectedID = id
        selectionChange?(id)
        refreshOverlay()
        updateCursorAtCurrentMouseLocation()
    }

    /// Undo/redo can remove the selected drawing; keep the canvas in step with the controller.
    func clearAnnotationSelection() {
        guard selectedAnnotationID != nil else { return }
        selectedAnnotationID = nil
        refreshOverlay()
    }

    func selectAnnotation(id: UUID) {
        if selectedID != nil { selectedID = nil; selectionChange?(nil) }
        selectedAnnotationID = id
        annotationSelectionChange?(id)
        refreshOverlay()
    }

    func setRegionsFromExternal(_ shapes: [RegionShape]) {
        // 외부에서 직접 regions 교체 (undo/redo 등). 선택 영역 정리.
        if let sel = selectedID, !shapes.contains(where: { $0.id == sel }) {
            selectedID = nil
            selectionChange?(nil)
        }
        refreshOverlay()
        updateCursorAtCurrentMouseLocation()
    }

    func deleteSelected() {
        if liveAnnotationSelectionID != nil { deleteSelectedAnnotation(); refreshOverlay(); return }
        guard let sel = selectedID else { return }
        var current = regionsBinding?() ?? []
        if let idx = current.firstIndex(where: { $0.id == sel }) {
            current.remove(at: idx)
            regionsUpdate?(current)
            selectedID = nil
            selectionChange?(nil)
            refreshOverlay()
            updateCursorAtCurrentMouseLocation()
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // 빈 캔버스 안내
        if (regionsBinding?() ?? []).isEmpty, polygonBuffer.isEmpty, videoSizeBinding?() == .zero {
            drawEmptyHint()
        }

        // 비디오 표시 영역 보더
        NSColor.white.withAlphaComponent(0.05).setStroke()
        let bp = NSBezierPath(rect: displayRect)
        bp.lineWidth = 1
        bp.stroke()

        // 저장된 영역
        let regions = regionsBinding?() ?? []
        let currentTime = currentTimeProvider?() ?? 0
        let highlightedAnnotationID = liveAnnotationSelectionID
        for annotation in annotationsBinding?() ?? [] {
            let path = NSBezierPath(cgPath: annotation.path)
            path.lineWidth = annotation.lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            // The preview layer renders visible drawings; outside their time only a faint guide shows.
            let visible = videoSizeBinding?() == .zero || annotation.isVisible(at: currentTime)
            if visible {
                annotation.color.setStroke()
            } else {
                annotation.color.withAlphaComponent(0.25).setStroke()
                path.setLineDash([6, 4], count: 2, phase: 0)
            }
            path.stroke()
            if annotation.id == highlightedAnnotationID {
                NSColor.white.setStroke(); path.lineWidth = annotation.lineWidth + 3
                path.setLineDash([3, 3], count: 2, phase: 0); path.stroke()
                for corner in corners(of: annotation.bounds) {
                    let dot = NSBezierPath(rect: NSRect(x: corner.x - 4, y: corner.y - 4, width: 8, height: 8))
                    NSColor.white.setFill(); dot.fill()
                    NSColor.systemOrange.setStroke(); dot.lineWidth = 1.5; dot.stroke()
                }
            }
            if annotation.id == eraseHoverID { drawEraseHighlight(NSBezierPath(cgPath: annotation.path)) }
        }
        if !annotationBuffer.isEmpty, let mode = modeBinding?(), mode.isDrawing {
            let style = annotationStyleBinding?() ?? (.systemYellow, 4, 0)
            let annotation = DrawingAnnotation(kind: annotationKind(for: mode), points: annotationBuffer, color: style.0,
                                               lineWidth: style.1, fillOpacity: style.2)
            if annotation.isFilled {
                annotation.color.withAlphaComponent(annotation.alpha * annotation.fillOpacity * 0.8).setFill()
                NSBezierPath(cgPath: annotation.fillPath).fill()
            }
            let path = NSBezierPath(cgPath: annotation.path)
            path.lineWidth = annotation.lineWidth; path.lineCapStyle = .round; path.lineJoinStyle = .round
            annotation.color.withAlphaComponent(0.8).setStroke(); path.stroke()
        }
        for r in regions {
            let eff = effectForID?(r.id)
            let isActiveNow = eff.map { isEffectActive($0, at: currentTime) } ?? true
            drawShape(r, selected: r.id == selectedID, active: isActiveNow)
            drawRegionLabel(r, effect: eff, selected: r.id == selectedID, active: isActiveNow)
            if r.id == eraseHoverID { drawEraseHighlight(NSBezierPath(cgPath: r.path())) }
        }
        drawMotionPath()
        if recordingKeyframes { drawRecordingBadge() }

        // 폴리곤 진행 중
        let mode = modeBinding?() ?? .rectangle
        if (mode == .polygonClick || mode == .polygonFree), polygonBuffer.count >= 1 {
            let path = NSBezierPath()
            path.move(to: polygonBuffer[0])
            for p in polygonBuffer.dropFirst() { path.line(to: p) }
            if let hover = lastMouseLocation, polygonBuffer.count >= 1 {
                path.line(to: hover)
            }
            NSColor.systemYellow.setStroke()
            path.lineWidth = 1.5
            path.setLineDash([4, 4], count: 2, phase: 0)
            path.stroke()
            path.setLineDash([], count: 0, phase: 0)

            // 닫기 가능 여부 — 마지막 hover가 첫점 근처이고 점이 3개 이상이면 강조
            var canClose = false
            if let hover = lastMouseLocation, polygonBuffer.count >= 3 {
                let first = polygonBuffer[0]
                let dx = hover.x - first.x, dy = hover.y - first.y
                if (dx * dx + dy * dy).squareRoot() < 14 {
                    canClose = true
                }
            }

            for (i, p) in polygonBuffer.enumerated() {
                let isFirst = i == 0
                let isLast = i == polygonBuffer.count - 1
                if isFirst {
                    // 첫점 — 가장 큰 사각형 (20x20 흰색) + 굵은 주황 외곽선 (4pt) + 점선 펄스
                    let pulse = NSBezierPath(rect: NSRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22))
                    NSColor.systemOrange.setStroke()
                    pulse.lineWidth = 2
                    pulse.setLineDash([3, 3], count: 2, phase: 0)
                    pulse.stroke()
                    pulse.setLineDash([], count: 0, phase: 0)
                    // 핵심 마커
                    let dot = NSBezierPath(rect: NSRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14))
                    NSColor.white.setFill(); dot.fill()
                    NSColor.systemOrange.setStroke(); dot.lineWidth = 4; dot.stroke()
                    // "1번 점" 라벨
                    let label = NSAttributedString(string: "1", attributes: [
                        .font: NSFont.systemFont(ofSize: 11, weight: .heavy),
                        .foregroundColor: NSColor.systemOrange
                    ])
                    let s = label.size()
                    label.draw(at: NSPoint(x: p.x - s.width / 2, y: p.y - s.height / 2 - 1))
                } else {
                    let dot = NSBezierPath(ovalIn: NSRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
                    NSColor.systemYellow.setFill(); dot.fill()
                    dot.lineWidth = 1; NSColor.systemYellow.setStroke(); dot.stroke()
                    if isLast {
                        let ring = NSBezierPath(ovalIn: NSRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14))
                        ring.lineWidth = 1
                        NSColor.systemYellow.setStroke()
                        ring.stroke()
                    }
                }
            }

            // 닫기 가능 표시 — 첫점 위에 더 큰 펄스 사각형
            if canClose {
                let first = polygonBuffer[0]
                // 큰 외부 펄스
                let pulse = NSBezierPath(rect: NSRect(x: first.x - 14, y: first.y - 14, width: 28, height: 28))
                NSColor.systemGreen.setStroke()
                pulse.lineWidth = 3
                pulse.setLineDash([4, 4], count: 2, phase: 0)
                pulse.stroke()
                pulse.setLineDash([], count: 0, phase: 0)
                // 안내 텍스트
                let info = NSAttributedString(string: "클릭하여 닫기", attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                    .foregroundColor: NSColor.systemGreen
                ])
                info.draw(at: NSPoint(x: first.x + 18, y: first.y + 4))
            }

            // 첫점 ↔ 현재 hover 가이드 (점 개수 부족할 때)
            if let hover = lastMouseLocation, polygonBuffer.count < 3 {
                let guide = NSAttributedString(string: "최소 3개 점을 찍으세요", attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor
                ])
                guide.draw(at: NSPoint(x: hover.x + 10, y: hover.y + 10))
            }
        }

        // 사각형 생성 중
        if mode == .rectangle, activeDrag == .create {
            let r = rect(from: dragStart, to: dragLast)
            let p = NSBezierPath(rect: r)
            NSColor.systemGreen.setStroke()
            p.lineWidth = 1.5
            p.setLineDash([4, 4], count: 2, phase: 0)
            p.stroke()
        }
        // 원형 생성 중
        if mode == .ellipse, activeDrag == .createEllipse {
            let r = rect(from: dragStart, to: dragLast)
            let p = NSBezierPath(ovalIn: r)
            NSColor.systemTeal.setStroke()
            p.lineWidth = 1.5
            p.setLineDash([4, 4], count: 2, phase: 0)
            p.stroke()
        }
    }

    private func corners(of rect: CGRect) -> [NSPoint] {
        [NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.minY),
         NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: rect.maxX, y: rect.maxY)]
    }

    private func drawEraseHighlight(_ path: NSBezierPath) {
        NSColor.systemRed.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 3
        path.setLineDash([5, 3], count: 2, phase: 0)
        path.stroke()
    }

    /// Recorded positions of the selected item: dashed path through keyframe centers.
    private func drawMotionPath() {
        guard let points = motionPathProvider?(), points.count >= 2 else { return }
        let path = NSBezierPath()
        path.move(to: points[0])
        for p in points.dropFirst() { path.line(to: p) }
        NSColor.systemOrange.withAlphaComponent(0.85).setStroke()
        path.lineWidth = 1.5
        path.setLineDash([4, 3], count: 2, phase: 0)
        path.stroke()
        for p in points {
            let dot = NSBezierPath(ovalIn: NSRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
            NSColor.systemOrange.setFill(); dot.fill()
        }
    }

    private func drawRecordingBadge() {
        let text = NSAttributedString(string: "● 움직임 기록 중", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white
        ])
        let size = text.size()
        let box = NSRect(x: displayRect.minX + 8, y: displayRect.maxY - size.height - 14, width: size.width + 12, height: size.height + 6)
        NSColor.systemRed.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        text.draw(at: NSPoint(x: box.minX + 6, y: box.minY + 3))
    }

    private func drawEmptyHint() {
        let text = emptyHint.isEmpty ? "영상을 끌어다 놓으세요" : emptyHint
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        let pt = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        s.draw(at: pt)
    }

    private func drawShape(_ region: RegionShape, selected: Bool, active: Bool = true) {
        let path = NSBezierPath()
        switch region {
        case .rectangle(_, let o, let s):
            path.appendRect(NSRect(origin: o, size: s))
        case .ellipse(_, let o, let s):
            path.appendOval(in: NSRect(origin: o, size: s))
        case .polygon(_, let pts):
            guard let first = pts.first else { return }
            path.move(to: first)
            for p in pts.dropFirst() { path.line(to: p) }
            path.close()
        }
        let baseColor: NSColor = active ? .systemBlue : .systemGray
        let alpha: CGFloat = selected ? (active ? 0.25 : 0.15) : (active ? 0.10 : 0.06)
        baseColor.withAlphaComponent(alpha).setFill()
        path.fill()
        baseColor.setStroke()
        path.lineWidth = selected ? 3.5 : 1.5
        path.stroke()

        if selected {
            switch region {
            case .rectangle(_, let o, let s):
                let rect = NSRect(origin: o, size: s)
                for pt in handles(for: rect) {
                    let dot = NSBezierPath(ovalIn: NSRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10))
                    NSColor.white.setFill(); dot.fill()
                    baseColor.setStroke(); dot.lineWidth = 1.5; dot.stroke()
                }
            case .ellipse(_, let o, let s):
                let rect = NSRect(origin: o, size: s)
                for pt in handles(for: rect) {
                    let dot = NSBezierPath(ovalIn: NSRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10))
                    NSColor.white.setFill(); dot.fill()
                    baseColor.setStroke(); dot.lineWidth = 1.5; dot.stroke()
                }
            case .polygon(_, let pts):
                for p in pts {
                    let dot = NSBezierPath(ovalIn: NSRect(x: p.x - 5, y: pt_y(p), width: 10, height: 10))
                    NSColor.white.setFill(); dot.fill()
                    baseColor.setStroke(); dot.lineWidth = 1.5; dot.stroke()
                }
            }
        }
    }
    private func pt_y(_ p: CGPoint) -> CGFloat { p.y - 5 }

    private func handles(for rect: NSRect) -> [NSPoint] {
        [
            // 4 꼭짓점
            NSPoint(x: rect.minX, y: rect.minY),
            NSPoint(x: rect.maxX, y: rect.minY),
            NSPoint(x: rect.minX, y: rect.maxY),
            NSPoint(x: rect.maxX, y: rect.maxY),
            // 4 변 중점 (가장자리에서 resize — 양쪽 가장자리까지 같이 움직임)
            NSPoint(x: rect.midX, y: rect.minY),  // top edge
            NSPoint(x: rect.midX, y: rect.maxY),  // bottom edge
            NSPoint(x: rect.minX, y: rect.midY),  // left edge
            NSPoint(x: rect.maxX, y: rect.midY)   // right edge
        ]
    }

    /// 4 꼭짓점 + 4 변 중점의 총 8개 핸들 좌표 + 라벨을 매칭해서 반환.
    private func handlesAndLabels(for rect: NSRect) -> (points: [NSPoint], labels: [HandlePos]) {
        let points = handles(for: rect)
        let labels: [HandlePos] = [.tl, .tr, .bl, .br, .topEdge, .bottomEdge, .leftEdge, .rightEdge]
        return (points, labels)
    }

    /// Hover uses the same selected handles as resizing, without changing the selection.
    func resizeCursorDirection(at point: NSPoint) -> ResizeCursorDirection? {
        guard isEditable, let selectedID,
              let region = regionsBinding?().first(where: { $0.id == selectedID }) else { return nil }
        let rect: NSRect
        switch region {
        case .rectangle, .ellipse: rect = region.boundingRect
        case .polygon: return nil
        }
        let (points, labels) = handlesAndLabels(for: rect)
        for (index, handlePoint) in points.enumerated() where dist(handlePoint, point) < 10 {
            return cursorDirection(for: labels[index])
        }
        return nil
    }

    private func cursorDirection(for handle: HandlePos) -> ResizeCursorDirection? {
        switch handle {
        case .tl, .br: return .ascendingDiagonal
        case .tr, .bl: return .descendingDiagonal
        case .leftEdge, .rightEdge: return .horizontal
        case .topEdge, .bottomEdge: return .vertical
        case .vertex: return nil
        }
    }

    private func updateCursor(at point: NSPoint) {
        guard isEditable, bounds.contains(point) else { resetCursor(); return }
        if colorPickHandler != nil || modeBinding?() == .erase {
            NSCursor.crosshair.set()
            displayedCursor = .crosshair
            return
        }
        let direction: ResizeCursorDirection?
        if activeDrag == .resize, let activeHandle {
            direction = cursorDirection(for: activeHandle)
        } else if activeDrag == nil {
            direction = resizeCursorDirection(at: point)
        } else {
            direction = nil
        }
        let cursor: NSCursor
        switch direction {
        case .ascendingDiagonal: cursor = Self.ascendingCursor
        case .descendingDiagonal: cursor = Self.descendingCursor
        case .horizontal: cursor = .resizeLeftRight
        case .vertical: cursor = .resizeUpDown
        case nil: cursor = .arrow
        }
        // AppKit may replace the cursor before cursorUpdate even when the handle is unchanged.
        cursor.set()
        displayedCursor = cursor
    }

    private func updateCursorAtCurrentMouseLocation() {
        guard let window else { return }
        updateCursor(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func resetCursor() {
        if displayedCursor != nil {
            NSCursor.arrow.set()
            displayedCursor = nil
        }
    }

    /// macOS 14 has no public diagonal frame-resize cursors, so draw both directions.
    private static func diagonalCursor(ascending: Bool) -> NSCursor {
        let image = NSImage(size: NSSize(width: 24, height: 24))
        image.lockFocus()
        let start = ascending ? NSPoint(x: 5, y: 5) : NSPoint(x: 5, y: 19)
        let end = ascending ? NSPoint(x: 19, y: 19) : NSPoint(x: 19, y: 5)
        let dx = (end.x - start.x) / 14
        let dy = (end.y - start.y) / 14
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        for (tip, sign) in [(start, -1.0), (end, 1.0)] {
            let base = NSPoint(x: tip.x - sign * dx * 5, y: tip.y - sign * dy * 5)
            path.move(to: NSPoint(x: base.x - dy * 3, y: base.y + dx * 3))
            path.line(to: tip)
            path.line(to: NSPoint(x: base.x + dy * 3, y: base.y - dx * 3))
        }
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.white.setStroke()
        path.lineWidth = 4
        path.stroke()
        NSColor.black.setStroke()
        path.lineWidth = 2
        path.stroke()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }

    // MARK: - Mouse

    override var acceptsFirstResponder: Bool { true }

    private var lastMouseDownAt: NSPoint = .zero
    private var lastMouseDownTime: Date = .distantPast

    private func log(_ msg: String) { BLog(msg) }

    private func clamped(_ point: NSPoint) -> NSPoint {
        NSPoint(x: min(max(0, point.x), bounds.width), y: min(max(0, point.y), bounds.height))
    }

    func resetInteraction() {
        selectedID = nil
        selectedAnnotationID = nil
        annotationSelectionChange?(nil)
        annotationBuffer.removeAll()
        dragAnnotation = nil
        eraseHoverID = nil
        polygonBuffer.removeAll()
        creationStartTime = nil
        activeDrag = nil
        dragShape = nil
        selectionChange?(nil)
        resetCursor()
        refreshOverlay()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEditable else { return }
        window?.makeFirstResponder(self)
        editingBegan?()
        let pt = clamped(convert(event.locationInWindow, from: nil))
        lastMouseLocation = pt
        // 모든 drag 분기에서 사용할 기준점. applyDrag에서 dragStart 대비 delta 사용.
        dragStart = pt
        dragLast = pt
        let mode = modeBinding?() ?? .rectangle
        log("[canvas] mouseDown mode=\(mode) pt=(\(Int(pt.x)),\(Int(pt.y))) buffer=\(polygonBuffer.count)")

        if let pick = colorPickHandler {
            colorPickHandler = nil
            pick(pt)
            refreshOverlay()
            return
        }
        if mode == .erase {
            if selectedID != nil { selectedID = nil; selectionChange?(nil) }
            if selectedAnnotationID != nil { selectedAnnotationID = nil; annotationSelectionChange?(nil) }
            activeDrag = .erase
            eraseItems(at: pt)
            return
        }
        if mode.isDrawing {
            let annotations = annotationsBinding?() ?? []
            if let selected = liveAnnotationSelectionID, let current = annotations.first(where: { $0.id == selected }),
               let opposite = corners(of: current.bounds).enumerated().first(where: { dist($0.element, pt) < 10 }).map({
                   corners(of: current.bounds)[3 - $0.offset] }) {
                dragAnnotation = current
                annotationHandleAnchor = opposite
                activeDrag = .annotationResize
                refreshOverlay()
                return
            }
            if let hit = annotations.reversed().first(where: { $0.hitTest(pt) }) {
                selectAnnotation(id: hit.id)
                annotationBuffer.removeAll()
                if event.clickCount >= 2 { deleteSelectedAnnotation(); refreshOverlay(); return }
                dragAnnotation = hit
                activeDrag = .annotationMove
                return
            }
            if selectedAnnotationID != nil { selectedAnnotationID = nil; annotationSelectionChange?(nil) }
            captureCreationTime()
            annotationBuffer = [pt]
            activeDrag = .annotation
            refreshOverlay()
            return
        }

        // 자유형(polygonClick) 첫점 근처 클릭 → 닫기
        if mode == .polygonClick, polygonBuffer.count >= 3,
           let first = polygonBuffer.first, dist(first, pt) < 14 {
            var current = regionsBinding?() ?? []
            let id = UUID()
            current.append(.polygon(id: id, points: polygonBuffer))
            regionsUpdate?(current)
            polygonBuffer.removeAll()
            selectedID = id
            selectionChange?(id)
            activeDrag = nil
            refreshOverlay()
            return
        }

        // 더블클릭 (동일 위치 + 짧은 시간) → 폴리곤 닫기
        if mode == .polygonClick, polygonBuffer.count >= 3 {
            let now = Date()
            if dist(lastMouseDownAt, pt) < 8, now.timeIntervalSince(lastMouseDownTime) < 0.4 {
                var current = regionsBinding?() ?? []
                let id = UUID()
                current.append(.polygon(id: id, points: polygonBuffer))
                regionsUpdate?(current)
                polygonBuffer.removeAll()
                selectedID = id
                selectionChange?(id)
                activeDrag = nil
                refreshOverlay()
                lastMouseDownTime = .distantPast
                return
            }
        }
        lastMouseDownAt = pt
        lastMouseDownTime = Date()

        // 영역 안 hit test (handle 우선 → 본체)
        if let hit = hitTest(at: pt) {
            let id = regionsBinding?()[hit.regionIndex].id
            dragShape = regionsBinding?()[hit.regionIndex]
            selectedID = id
            selectionChange?(id)
            // 더블클릭 = 시간 설정
            if event.clickCount >= 2, let id {
                regionDoubleClickHandler?(id)
                activeDrag = nil
                refreshOverlay()
                return
            }
            if (mode == .polygonClick || mode == .polygonFree), hit.kind == .resize, case .vertex = hit.handle {
                // 폴리곤 점 드래그
                activeDrag = .resize
                activeHandle = hit.handle
                activeHandleAnchor = nil  // 폴리곤은 shift 정사각형화 미적용
            } else {
                activeDrag = hit.kind
                activeHandle = hit.handle
                // resize 시 anchor corner 저장 — shift 정사각형화에 사용
                if hit.kind == .resize {
                    let reg = regionsBinding?()[hit.regionIndex]
                    activeHandleAnchor = anchorCorner(for: hit.handle, on: reg)
                }
                // 키프레임 기록 시작: drag 시작 시점 시간 기록.
                lastKeyframeTime = currentVideoTime
            }
        } else if mode == .polygonClick {
            selectedID = nil
            selectionChange?(nil)
            // 점 찍기
            if polygonBuffer.isEmpty { captureCreationTime() }
            polygonBuffer.append(pt)
            activeDrag = nil
        } else if mode == .polygonFree {
            selectedID = nil
            selectionChange?(nil)
            // 자유 그리기: 첫 점만 기록, mouseDragged로 계속 추가
            captureCreationTime()
            polygonBuffer = [pt]
            activeDrag = .polygonFree
        } else if mode == .ellipse {
            // 원형 생성 (드래그)
            captureCreationTime()
            activeDrag = .createEllipse
            dragStart = pt
            selectedID = nil
            selectionChange?(nil)
        } else {
            // 사각형 새로 생성
            captureCreationTime()
            activeDrag = .create
            dragStart = pt
            selectedID = nil
            selectionChange?(nil)
        }
        dragLast = pt
        refreshOverlay()
        updateCursor(at: pt)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEditable else { return }
        let rawPoint = convert(event.locationInWindow, from: nil)
        var pt = clamped(rawPoint)
        lastMouseLocation = pt
        // Shift + 드래그 = 정사각형/정원 강제. drag 중 매번 modifier 검사.
        let isShift = event.modifierFlags.contains(.shift)
        let isCreateMode = activeDrag == .create || activeDrag == .createEllipse
        if isShift && isCreateMode {
            let dx = pt.x - dragStart.x
            let dy = pt.y - dragStart.y
            let side = min(abs(dx), abs(dy))
            let signX: Double = dx >= 0 ? 1 : -1
            let signY: Double = dy >= 0 ? 1 : -1
            pt = NSPoint(
                x: dragStart.x + signX * side,
                y: dragStart.y + signY * side
            )
        }
        if activeDrag == .move || activeDrag == .resize {
            applyDrag(current: pt, shiftHeld: isShift)
        } else if activeDrag == .create {
            dragLast = pt
            refreshOverlay()
        } else if activeDrag == .createEllipse {
            dragLast = pt
            refreshOverlay()
        } else if activeDrag == .annotationMove || activeDrag == .annotationResize {
            if let edited = editedAnnotation(at: pt) { annotationChanged?(edited) }
            refreshOverlay()
        } else if activeDrag == .erase {
            eraseItems(at: pt)
        } else if activeDrag == .annotation {
            if modeBinding?() == .drawFreehand {
                if let last = annotationBuffer.last, hypot(pt.x - last.x, pt.y - last.y) >= 2 { annotationBuffer.append(pt) }
            } else if annotationBuffer.count == 1 {
                annotationBuffer.append(pt)
            } else { annotationBuffer[1] = pt }
            refreshOverlay()
        } else if activeDrag == .polygonFree {
            // 자유 그리기: 이전 점과 충분한 거리일 때만 점 추가
            if let last = polygonBuffer.last {
                let dx = pt.x - last.x, dy = pt.y - last.y
                if (dx * dx + dy * dy).squareRoot() > 6 {
                    polygonBuffer.append(pt)
                    refreshOverlay()
                }
            }
        }
        updateCursor(at: rawPoint)
    }

    override func mouseUp(with event: NSEvent) {
        guard isEditable else { return }
        defer {
            editingEnded?()
            dragShape = nil
            if polygonBuffer.isEmpty { creationStartTime = nil }
        }
        var pt = clamped(convert(event.locationInWindow, from: nil))
        if event.modifierFlags.contains(.shift), activeDrag == .create || activeDrag == .createEllipse {
            let dx = pt.x - dragStart.x, dy = pt.y - dragStart.y
            let side = min(abs(dx), abs(dy))
            pt = NSPoint(x: dragStart.x + (dx < 0 ? -side : side), y: dragStart.y + (dy < 0 ? -side : side))
        }
        let mode = modeBinding?() ?? .rectangle
        let shiftHeld = event.modifierFlags.contains(.shift)
        log("[canvas] mouseUp activeDrag=\(String(describing: activeDrag)) mode=\(mode) ptsTotal=\(regionsBinding?().count ?? -1)")
        if activeDrag == .annotation {
            if annotationBuffer.count == 1 { annotationBuffer.append(pt) }
            else if mode != .drawFreehand { annotationBuffer[1] = pt }
            if annotationBuffer.count >= 2, hypot(annotationBuffer.last!.x - annotationBuffer[0].x, annotationBuffer.last!.y - annotationBuffer[0].y) > 2 {
                let style = annotationStyleBinding?() ?? (.systemYellow, 4, 0)
                let created = DrawingAnnotation(kind: annotationKind(for: mode), points: annotationBuffer,
                                                color: style.0, lineWidth: style.1, fillOpacity: style.2)
                annotationAdded?(created)
                selectedAnnotationID = created.id
                annotationSelectionChange?(created.id)
            }
            annotationBuffer.removeAll()
        }
        if activeDrag == .annotationMove || activeDrag == .annotationResize {
            if hypot(pt.x - dragStart.x, pt.y - dragStart.y) > 0, let edited = editedAnnotation(at: pt) {
                annotationChanged?(edited)
            }
            dragAnnotation = nil
            annotationHandleAnchor = nil
        }
        if mode == .rectangle, activeDrag == .create {
            var r = rect(from: dragStart, to: pt)
            // Shift + 드래그 = 정사각형 (짧은 변 기준)
            if shiftHeld {
                let side = min(r.width, r.height)
                r.size = CGSize(width: side, height: side)
            }
            if r.width > 4, r.height > 4 {
                var current = regionsBinding?() ?? []
                let new = RegionShape.rectangle(id: UUID(), origin: r.origin, size: r.size)
                current.append(new)
                regionsUpdate?(current)
                selectedID = new.id
                selectionChange?(new.id)
            }
        } else if mode == .ellipse, activeDrag == .createEllipse {
            var r = rect(from: dragStart, to: pt)
            // Shift + 드래그 = 정원 (짧은 변 기준)
            if shiftHeld {
                let side = min(r.width, r.height)
                r.size = CGSize(width: side, height: side)
            }
            if r.width > 4, r.height > 4 {
                var current = regionsBinding?() ?? []
                let new = RegionShape.ellipse(id: UUID(), origin: r.origin, size: r.size)
                current.append(new)
                regionsUpdate?(current)
                selectedID = new.id
                selectionChange?(new.id)
            }
        } else if mode == .polygonFree, activeDrag == .polygonFree, polygonBuffer.count >= 3 {
            // 자유 그리기 종료: 현재 점들로 polygon 생성
            var current = regionsBinding?() ?? []
            let id = UUID()
            current.append(.polygon(id: id, points: polygonBuffer))
            regionsUpdate?(current)
            polygonBuffer.removeAll()
            selectedID = id
            selectionChange?(id)
        }
        // move/resize 종료: mouseDragged가 호출되지 않은 경우에도 regionsUpdate 보장
        if activeDrag == .move || activeDrag == .resize {
            applyDrag(current: pt, shiftHeld: shiftHeld)
        }
        if activeDrag == .polygonFree { polygonBuffer.removeAll() }
        activeDrag = nil
        activeHandle = nil
        activeHandleAnchor = nil
        refreshOverlay()
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func annotationKind(for mode: Mode) -> DrawingAnnotation.Kind {
        switch mode { case .drawRectangle: return .rectangle; case .drawEllipse: return .ellipse
        case .drawLine: return .line; default: return .freehand }
    }

    /// Displayed geometry of the dragged drawing for a move (clamped to the media) or corner resize.
    private func editedAnnotation(at pt: NSPoint) -> DrawingAnnotation? {
        guard let original = dragAnnotation else { return nil }
        if activeDrag == .annotationResize, let anchor = annotationHandleAnchor {
            var target = rect(from: anchor, to: pt)
            let old = original.bounds
            // Keep a straight line straight: a zero-extent axis stays zero. Any other axis keeps
            // at least 2pt so it can be enlarged again (a zero axis could never grow back).
            if old.width == 0 { target = CGRect(x: old.minX, y: target.minY, width: 0, height: target.height) }
            else if target.width < 2 { target.size.width = 2; if pt.x < anchor.x { target.origin.x = anchor.x - 2 } }
            if old.height == 0 { target = CGRect(x: target.minX, y: old.minY, width: target.width, height: 0) }
            else if target.height < 2 { target.size.height = 2; if pt.y < anchor.y { target.origin.y = anchor.y - 2 } }
            return original.replacingBounds(target)
        }
        let box = original.bounds
        let tx = min(max(displayRect.minX - box.minX, pt.x - dragStart.x), displayRect.maxX - box.maxX)
        let ty = min(max(displayRect.minY - box.minY, pt.y - dragStart.y), displayRect.maxY - box.maxY)
        var moved = original
        moved.points = original.points.map { CGPoint(x: $0.x + tx, y: $0.y + ty) }
        return moved
    }

    /// The single topmost item under the eraser (drawings render above blur regions),
    /// matching the hover highlight so a click never removes hidden items underneath.
    private func eraseTargets(at pt: NSPoint) -> (regions: [UUID], drawings: [UUID]) {
        if let drawing = (annotationsBinding?() ?? []).reversed().first(where: { $0.hitTest(pt) }) { return ([], [drawing.id]) }
        if let region = (regionsBinding?() ?? []).reversed().first(where: { $0.contains(point: pt, threshold: 6) }) { return ([region.id], []) }
        return ([], [])
    }

    private func eraseItems(at pt: NSPoint) {
        let targets = eraseTargets(at: pt)
        guard !targets.regions.isEmpty || !targets.drawings.isEmpty else { return }
        itemsErased?(Set(targets.regions), Set(targets.drawings))
        eraseHoverID = nil
        refreshOverlay()
        liveBlurRefreshCallback?()
    }

    /// A drawing selection is actionable only in a drawing mode and while that drawing still
    /// exists (undo or a new file can remove it); otherwise Delete must reach blur regions.
    private var liveAnnotationSelectionID: UUID? {
        guard let id = selectedAnnotationID, modeBinding?().isDrawing == true,
              (annotationsBinding?() ?? []).contains(where: { $0.id == id }) else { return nil }
        return id
    }

    private func deleteSelectedAnnotation() {
        guard let id = liveAnnotationSelectionID else { return }
        selectedAnnotationID = nil
        annotationSelectionChange?(nil)
        itemsErased?([], [id])
    }

    override func keyDown(with event: NSEvent) {
        guard isEditable else { super.keyDown(with: event); return }
        editingBegan?()
        defer {
            editingEnded?()
            if polygonBuffer.isEmpty { creationStartTime = nil }
        }
        let mode = modeBinding?() ?? .rectangle
        switch event.keyCode {
        case 49:
            playPauseHandler?()
        case 51, 117:
            // Delete/Backspace: 선택 영역 삭제 or 폴리곤 점 하나 빼기
            if liveAnnotationSelectionID != nil {
                deleteSelectedAnnotation()
                refreshOverlay()
            } else if selectedID != nil {
                deleteSelected()
            } else if mode == .polygonClick, !polygonBuffer.isEmpty {
                polygonBuffer.removeLast()
                refreshOverlay()
            }
        case 36, 76:
            // Return: 폴리곤(점찍기) 닫기 (3개 이상)
            if mode == .polygonClick, polygonBuffer.count >= 3 {
                var current = regionsBinding?() ?? []
                let id = UUID()
                current.append(.polygon(id: id, points: polygonBuffer))
                regionsUpdate?(current)
                polygonBuffer.removeAll()
                selectedID = id
                selectionChange?(id)
                refreshOverlay()
            }
        case 53:
            // ESC: 스포이드 취소 또는 폴리곤 진행 취소
            if colorPickHandler != nil {
                colorPickHandler = nil
                colorPickCancelled?()
            } else if (mode == .polygonClick || mode == .polygonFree), !polygonBuffer.isEmpty {
                polygonBuffer.removeAll()
                activeDrag = nil
                refreshOverlay()
            }
        case 123, 124, 125, 126:
            // 화살표 키: 선택 영역 이동
            moveSelectedByArrow(keyCode: event.keyCode, modifierFlags: event.modifierFlags)
        default:
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               let key = event.charactersIgnoringModifiers?.lowercased().first, shortcutHandler?(key) == true { return }
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, isEditable, selectedID != nil, event.modifierFlags.contains(.command),
           [123, 124, 125, 126].contains(event.keyCode) {
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// 선택 영역을 화살표 키로 이동. ⇧=큰(10pt), ⌘=미세(0.1pt), 기본=1pt.
    private func moveSelectedByArrow(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        guard let sel = selectedID else { return }
        let step: CGFloat = modifierFlags.contains(.shift) ? 10.0
                            : modifierFlags.contains(.command) ? 0.1
                            : 1.0
        let dx: CGFloat, dy: CGFloat
        switch keyCode {
        case 123: dx = -step; dy = 0   // Left
        case 124: dx = step; dy = 0    // Right
        case 125: dx = 0; dy = -step   // Down
        case 126: dx = 0; dy = step    // Up
        default: return
        }
        let currentList = regionsBinding?() ?? []
        guard let idx = currentList.firstIndex(where: { $0.id == sel }) else { return }
        var regionsList = currentList
        let ar = displayRect
        switch regionsList[idx] {
        case .rectangle(let id, let o, let s):
            let nox = min(max(ar.minX, o.x + dx), ar.maxX - s.width)
            let noy = min(max(ar.minY, o.y + dy), ar.maxY - s.height)
            regionsList[idx] = .rectangle(id: id, origin: CGPoint(x: nox, y: noy), size: s)
        case .ellipse(let id, let o, let s):
            let nox = min(max(ar.minX, o.x + dx), ar.maxX - s.width)
            let noy = min(max(ar.minY, o.y + dy), ar.maxY - s.height)
            regionsList[idx] = .ellipse(id: id, origin: CGPoint(x: nox, y: noy), size: s)
        case .polygon(let id, let pts):
            let box = regionsList[idx].boundingRect
            let tx = min(max(ar.minX - box.minX, dx), ar.maxX - box.maxX)
            let ty = min(max(ar.minY - box.minY, dy), ar.maxY - box.maxY)
            regionsList[idx] = .polygon(id: id, points: pts.map { CGPoint(x: $0.x + tx, y: $0.y + ty) })
        }
        regionsUpdate?(regionsList)
        refreshOverlay()
        liveBlurRefreshCallback?()
    }

    // MARK: - Drag math

    private func rect(from a: NSPoint, to b: NSPoint) -> NSRect {
        let minX = min(a.x, b.x), minY = min(a.y, b.y)
        return NSRect(x: minX, y: minY, width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// resize 시작 handle의 anchor corner (opposite corner) 위치 반환.
    private func anchorCorner(for handle: HandlePos?, on region: RegionShape?) -> NSPoint? {
        guard let handle, let region else { return nil }
        switch region {
        case .rectangle(_, let o, let s):
            switch handle {
            case .tl: return NSPoint(x: o.x + s.width, y: o.y + s.height)
            case .tr: return NSPoint(x: o.x, y: o.y + s.height)
            case .bl: return NSPoint(x: o.x + s.width, y: o.y)
            case .br: return NSPoint(x: o.x, y: o.y)
            case .vertex, .topEdge, .bottomEdge, .leftEdge, .rightEdge: return nil
            }
        case .ellipse(_, let o, let s):
            switch handle {
            case .tl: return NSPoint(x: o.x + s.width, y: o.y + s.height)
            case .tr: return NSPoint(x: o.x, y: o.y + s.height)
            case .bl: return NSPoint(x: o.x + s.width, y: o.y)
            case .br: return NSPoint(x: o.x, y: o.y)
            case .vertex, .topEdge, .bottomEdge, .leftEdge, .rightEdge: return nil
            }
        case .polygon: return nil
        }
    }

    /// shift + resize에서 size 정사각형화. anchor 위치 그대로, size = max(|dx|,|dy|).
    private func squaredResize(anchor: NSPoint, current mousePt: NSPoint) -> NSRect {
        let dx = mousePt.x - anchor.x
        let dy = mousePt.y - anchor.y
        let side = max(abs(dx), abs(dy))
        let signX: Double = dx >= 0 ? 1 : -1
        let signY: Double = dy >= 0 ? 1 : -1
        let corner = NSPoint(x: anchor.x + signX * side, y: anchor.y + signY * side)
        let r = rect(from: anchor, to: corner)
        return NSRect(
            x: r.origin.x,
            y: r.origin.y,
            width: max(r.size.width, 4),
            height: max(r.size.height, 4)
        )
    }

    private func hitTest(at pt: NSPoint) -> (regionIndex: Int, kind: DragKind, handle: HandlePos?)? {
        let regions = regionsBinding?() ?? []
        // 선택된 영역의 핸들 먼저
        if let sel = selectedID, let idx = regions.firstIndex(where: { $0.id == sel }) {
            switch regions[idx] {
            case .rectangle(_, let o, let s):
                let rect = NSRect(origin: o, size: s)
                let (hs, labels) = handlesAndLabels(for: rect)
                for (i, h) in hs.enumerated() where dist(h, pt) < 10 {
                    return (idx, .resize, labels[i])
                }
            case .ellipse(_, let o, let s):
                let rect = NSRect(origin: o, size: s)
                let (hs, labels) = handlesAndLabels(for: rect)
                for (i, h) in hs.enumerated() where dist(h, pt) < 10 {
                    return (idx, .resize, labels[i])
                }
            case .polygon(_, let pts):
                for (i, v) in pts.enumerated() where dist(v, pt) < 10 {
                    return (idx, .resize, .vertex(i))
                }
            }
            if regions[idx].contains(point: pt, threshold: 0) {
                return (idx, .move, nil)
            }
        }
        // 다른 영역 (역순 — 위쪽 영역 우선)
        for (i, r) in regions.enumerated().reversed() where r.contains(point: pt, threshold: 6) {
            selectedID = r.id
            selectionChange?(r.id)
            return (i, .move, nil)
        }
        return nil
    }

    private func dist(_ a: NSPoint, _ b: NSPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    private func applyDrag(current mousePt: NSPoint, shiftHeld: Bool = false) {
        guard let sel = selectedID else { return }
        let currentList = regionsBinding?() ?? []
        guard let idx = currentList.firstIndex(where: { $0.id == sel }) else { return }
        var regionsList = currentList
        // 누적 패턴: 첫 mouseDragged에서 큰 점프가 발생하지 않도록 mouseDragged 사이의 delta만 적용.
        // mouseDown에서 dragStart와 dragLast를 같은 값으로 시작 → 첫 step도 안전.
        let dx = mousePt.x - dragStart.x
        let dy = mousePt.y - dragStart.y
        let original = dragShape ?? regionsList[idx]
        switch original {
        case .rectangle, .ellipse:
            var r = original.boundingRect
            if activeDrag == .move {
                r.origin.x += dx; r.origin.y += dy
            } else if activeDrag == .resize, let handle = activeHandle {
                if shiftHeld, let anchor = activeHandleAnchor {
                    r = squaredResize(anchor: anchor, current: mousePt)
                } else {
                    switch handle {
                    case .tl: r.origin.x += dx; r.origin.y += dy; r.size.width -= dx; r.size.height -= dy
                    case .tr: r.origin.y += dy; r.size.width += dx; r.size.height -= dy
                    case .bl: r.origin.x += dx; r.size.width -= dx; r.size.height += dy
                    case .br: r.size.width += dx; r.size.height += dy
                    case .topEdge: r.origin.y += dy; r.size.height -= dy
                    case .bottomEdge: r.size.height += dy
                    case .leftEdge: r.origin.x += dx; r.size.width -= dx
                    case .rightEdge: r.size.width += dx
                    case .vertex: break
                    }
                }
            }
            r.size.width = min(displayRect.width, max(4, r.width))
            r.size.height = min(displayRect.height, max(4, r.height))
            r.origin.x = min(max(displayRect.minX, r.minX), displayRect.maxX - r.width)
            r.origin.y = min(max(displayRect.minY, r.minY), displayRect.maxY - r.height)
            regionsList[idx] = original.replacing(rect: r)
        case .polygon(let id, let pts):
            if activeDrag == .move {
                var newPts = pts
                let box = original.boundingRect
                let tx = min(max(-box.minX, dx), displayRect.maxX - box.maxX)
                let ty = min(max(-box.minY, dy), displayRect.maxY - box.maxY)
                for i in 0..<newPts.count { newPts[i].x += tx; newPts[i].y += ty }
                regionsList[idx] = .polygon(id: id, points: newPts)
            } else if activeDrag == .resize, case .vertex(let vi) = activeHandle, vi < pts.count {
                var newPts = pts
                newPts[vi] = mousePt
                regionsList[idx] = .polygon(id: id, points: newPts)
            }
        }
        regionsUpdate?(regionsList)
        // 키프레임 자동 기록 (recordingKeyframes 활성 + 30Hz 간격 체크)
        // Timeline edits are committed by the controller using stable base geometry.
        dragLast = mousePt
        refreshOverlay()
        liveBlurRefreshCallback?()
    }

    // MARK: - Drag & Drop (file)

    private static let dropLog = Logger(subsystem: "local.piman.BlurAction", category: "Drop")

    /// The open panel accepts DocumentModel's image extensions and system video types.
    /// This checks the drop before promising a copy; decoding still happens in DocumentModel.
    static func isSupportedDropFile(_ url: URL) -> Bool {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              FileManager.default.isReadableFile(atPath: url.path) else { return false }

        let ext = url.pathExtension.lowercased()
        if DocumentModel.imageExtensions.contains(ext) { return true }
        if DocumentModel.videoExtensions.contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    static func supportedDroppedURL(from pasteboard: NSPasteboard) -> URL? {
        guard let objects = pasteboard.readObjects(forClasses: [NSURL.self]) else {
            dropLog.notice("pasteboard-unreadable")
            return nil
        }
        guard objects.count == 1, let url = objects.first as? URL else {
            dropLog.notice("file-count-invalid")
            return nil
        }
        guard isSupportedDropFile(url) else {
            dropLog.notice("unsupported-file")
            return nil
        }
        return url
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.dropLog.notice("dragging-entered")
        guard onFileLoad != nil else {
            Self.dropLog.notice("load-callback-missing")
            return []
        }
        guard Self.supportedDroppedURL(from: sender.draggingPasteboard) != nil else { return [] }
        Self.dropLog.notice("dragging-accepted")
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        Self.dropLog.notice("perform-drag-operation")
        guard let url = Self.supportedDroppedURL(from: sender.draggingPasteboard), let onFileLoad else {
            Self.dropLog.notice("perform-rejected")
            return false
        }
        onFileLoad(url)
        Self.dropLog.notice("load-callback-invoked")
        return true
    }

    // MARK: - Right-click context menu

    private func captureCreationTime() {
        creationStartTime = creationTimeProvider?() ?? currentVideoTime
    }

    override func rightMouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        // 영역 hit test (빈 공간 → nil)
        let hitID = (regionsBinding?() ?? []).reversed().first { $0.contains(point: pt, threshold: 6) }?.id
        if hitID == nil, let drawing = (annotationsBinding?() ?? []).reversed().first(where: { $0.hitTest(pt) }) {
            selectAnnotation(id: drawing.id)
            rightClickOnAnnotation?(drawing.id, pt)
            return
        }
        // 영역 선택도 같이 갱신
        if let id = hitID, hitID != selectedID {
            selectRegion(id: id)
        }
        rightClickOnRegion?(hitID, pt)
    }

    // MARK: - Region label

    /// 영역 안에 짧은 라벨(시간 정보)을 그린다. 선택 영역만.
    private func drawRegionLabel(_ region: RegionShape, effect: RegionEffect?, selected: Bool, active: Bool) {
        guard selected, let eff = effect else { return }
        let label = labelText(for: region, effect: eff)
        let rect = region.boundingRect
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let s = NSAttributedString(string: label, attributes: attrs)
        let pad: CGFloat = 4
        let size = s.size()
        let bgRect = NSRect(
            x: rect.origin.x,
            y: rect.maxY,
            width: size.width + pad * 2,
            height: size.height + pad
        )
        let bgColor: NSColor = active ? .systemBlue : .systemGray
        bgColor.withAlphaComponent(0.85).setFill()
        let path = NSBezierPath(roundedRect: bgRect, xRadius: 3, yRadius: 3)
        path.fill()
        s.draw(at: NSPoint(x: bgRect.origin.x + pad, y: bgRect.origin.y + pad / 2))
    }

    private func labelText(for region: RegionShape, effect: RegionEffect) -> String {
        let cover: String
        switch effect.style {
        case .blur: cover = "블러 \(Int(effect.blurRadius))px"
        case .mosaic: cover = "모자이크 \(Int(effect.blurRadius))px"
        case .solid: cover = "단색"
        }
        let motion = effect.keyframes.isEmpty ? "" : " · 이동 기록 \(effect.keyframes.count)"
        if effect.appliesToEntireVideo {
            return "전체 적용 · \(cover) · 경계 \(Int(effect.featherRadius))px\(motion)"
        }
        return String(format: "%.1f–%.1fs · ", effect.timeRange.lowerBound, effect.timeRange.upperBound)
            + "\(cover) · 경계 \(Int(effect.featherRadius))px\(motion)"
    }

    private func isEffectActive(_ e: RegionEffect, at time: Double) -> Bool {
        e.isActive(at: time)
    }
}
