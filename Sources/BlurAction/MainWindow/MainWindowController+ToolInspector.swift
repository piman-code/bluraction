import AppKit
import AVKit
import AVFoundation
import UniformTypeIdentifiers
import os
import Darwin

// MainWindowController: 도구·가리기 방식·색 고르기, 지우개 설정, 글자.

extension MainWindowController {
    @objc func modeChanged(_ sender: NSSegmentedControl) {
        if toolSegment.selectedSegment == 1 {
            switch sender.selectedSegment { case 0: canvasMode = .drawRectangle; case 1: canvasMode = .drawEllipse
            case 2: canvasMode = .drawLine; case 3: canvasMode = .drawFreehand; case 4: canvasMode = .drawArrow
            case 5: canvasMode = .drawText; default: canvasMode = .drawRectangle }
            annotationWidthTitle.stringValue = canvasMode == .drawText ? "글자 크기" : "선 굵기"
            refreshTextControls()
            annotationFillPopup.isEnabled = [.drawRectangle, .drawEllipse, .drawFreehand].contains(canvasMode)
        } else {
            switch sender.selectedSegment { case 0: canvasMode = .rectangle; case 1: canvasMode = .ellipse
            case 2: canvasMode = .polygonClick; case 3: canvasMode = .polygonFree; default: canvasMode = .rectangle }
        }
        canvas.resetInteraction()
    }

    @objc func toolChanged(_ sender: NSSegmentedControl) {
        updateToolPresentation(resetInteraction: true)
    }

    private func updateToolPresentation(resetInteraction: Bool) {
        let sender = toolSegment
        let drawing = sender.selectedSegment == 1
        let erasing = sender.selectedSegment == 2
        let labels = drawing ? ["사각형", "타원", "선", "펜", "화살표", "글자"] : ["사각형", "원", "점찍기", "자유"]
        modeSegment.segmentCount = labels.count
        for (index, label) in labels.enumerated() {
            modeSegment.setLabel(label, forSegment: index)
            modeSegment.setWidth(0, forSegment: index)
        }
        modeSegment.selectedSegment = 0
        annotationWidthTitle.stringValue = "선 굵기"
        annotationFillPopup.isEnabled = true
        modeSegment.isHidden = erasing
        canvasMode = erasing ? .erase : drawing ? .drawRectangle : .rectangle
        annotationColorRow?.isHidden = !drawing
        annotationWidthTitle.isHidden = !drawing
        annotationWidthSlider.isHidden = !drawing
        annotationFillPopup.isHidden = !drawing
        annotationHint.isHidden = !drawing
        eraserTools.isHidden = !erasing
        if resetInteraction { canvas.resetInteraction() }
        refreshCoverControls()
        refreshTextControls()
        showInspectorPanel(.selected)
    }

    /// Selecting a layer exposes its style without cancelling the in-progress canvas drag.
    func showSelectionInspector(drawing: Bool) {
        let keepReview = !drawing && taskPanelSelector.selectedSegment == InspectorPanel.review.rawValue
            && reviewSelection?.region == selectedID && selectedID != nil
        let tool = drawing ? 1 : 0
        if toolSegment.selectedSegment != tool {
            toolSegment.selectedSegment = tool
            updateToolPresentation(resetInteraction: false)
        }
        showInspectorPanel(keepReview ? .review : .selected)
    }

    /// Cover controls follow the blur tool and the selected region's (or next region's) style.
    func refreshCoverControls() {
        let blurTool = toolSegment.selectedSegment == 0
        let selected = selectedID.flatMap { id in pairs.first(where: { $0.shape.id == id }) }
        let style = selected?.effect.style ?? defaultCoverStyle
        coverSegment.selectedSegment = RegionEffect.CoverStyle.allCases.firstIndex(of: style) ?? 0
        if let selected { coverColorWell.color = selected.effect.color.nsColor }
        coverTitle.isHidden = !blurTool
        coverSegment.isHidden = !blurTool
        let showsStrength = blurTool && style != .solid
        effectTitle.stringValue = style == .mosaic ? "모자이크 크기" : "블러 강도"
        effectTitle.isHidden = !showsStrength; blurSlider.isHidden = !showsStrength; blurValueLabel.isHidden = !showsStrength
        blurRow?.isHidden = !showsStrength
        featherTitle.isHidden = !blurTool; featherSlider.isHidden = !blurTool; featherValueLabel.isHidden = !blurTool
        featherRow?.isHidden = !blurTool
        coverColorRow.isHidden = !(blurTool && style == .solid)
        decorationTools.isHidden = !blurTool
    }

    var selectedFillOpacity: CGFloat {
        [0, 0.35, 1][max(0, min(2, annotationFillPopup.indexOfSelectedItem))]
    }

    @objc func annotationPresetChosen(_ sender: NSPopUpButton) {
        let colors: [NSColor] = [.systemYellow, .systemRed, .systemBlue, .systemGreen, .white]
        annotationColorWell.color = colors[max(0, min(colors.count - 1, sender.indexOfSelectedItem))]
        annotationStyleChanged(sender)
    }

    /// Style controls set the next drawing and restyle the selected one (one undo step per gesture).
    @objc func annotationStyleChanged(_ sender: Any?) {
        canvas.refreshOverlay()
        guard !isExporting, let id = selectedDrawingID, let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        var drawing = annotations[index]
        // Loaded projects can retain widths/fills the preset controls cannot display exactly.
        // Restyle only the explicit field; color/preset/eyedropper must not quantize those values.
        if let slider = sender as? NSSlider, slider === annotationWidthSlider {
            drawing.lineWidth = CGFloat(annotationWidthSlider.doubleValue).rounded()
        } else if let popup = sender as? NSPopUpButton, popup === annotationFillPopup {
            drawing.fillOpacity = selectedFillOpacity
        } else {
            drawing.setColor(annotationColorWell.color)
        }
        guard drawing != annotations[index] else { return }
        // Only the color well streams continuous changes; popups and the eyedropper are single edits.
        if gestureSnapshot == nil { checkpoint(coalescing: sender is NSColorWell ? "drawing-color-\(id)" : nil) }
        annotations[index] = drawing
        refreshAfterEdit()
    }

    func showDrawingStyle(_ drawing: DrawingAnnotation) {
        annotationColorWell.color = drawing.color
        annotationWidthSlider.doubleValue = Double(drawing.lineWidth)
        annotationFillPopup.selectItem(at: drawing.fillOpacity <= 0 ? 0 : drawing.fillOpacity < 1 ? 1 : 2)
    }

    @objc func coverChanged(_ sender: NSSegmentedControl) {
        let style = RegionEffect.CoverStyle.allCases[max(0, min(2, sender.selectedSegment))]
        defaultCoverStyle = style
        updateSelectedEffect { $0.style = style }
        refreshCoverControls()
        refreshSelectedEditor()
    }

    @objc func coverColorChanged(_ sender: Any?) {
        let color = RGBAColor(coverColorWell.color)
        updateSelectedEffect(coalescing: sender is NSColorWell ? "cover-color" : nil) { $0.color = color }
    }

    func applyDefaultCover(to effect: inout RegionEffect) {
        effect.style = defaultCoverStyle
        effect.color = RGBAColor(coverColorWell.color)
    }

    @objc func trackMotionChanged(_ sender: NSButton) {
        trackMotion = sender.state == .on
        canvas.recordingKeyframes = recordingKeyframes && trackMotion
        workflowHint.stringValue = trackMotion
            ? "움직임 기록 켬: 옮긴 시점의 위치가 기록됩니다."
            : "움직임 기록 끔: 옮기면 기록된 경로 전체가 함께 움직입니다."
        canvas.refreshOverlay()
    }

    // MARK: - Color picking

    enum ColorTarget { case drawing, cover }

    @objc func pickAnnotationColor() { startColorPick(.drawing) }
    @objc func pickCoverColor() { startColorPick(.cover) }

    func startColorPick(_ target: ColorTarget) {
        guard doc.mediaKind != .none, !isExporting else { return }
        workflowHint.stringValue = "색을 가져올 곳을 캔버스에서 클릭하세요. Esc로 취소합니다."
        window?.makeFirstResponder(canvas)
        canvas.colorPickHandler = { [weak self] point in
            guard let self else { return }
            guard let color = self.liveBlur.color(atCanvasPoint: point) else {
                self.workflowHint.stringValue = "이 위치의 색을 읽지 못했습니다."
                return
            }
            self.applyPickedColor(color, to: target)
        }
    }

    private func applyPickedColor(_ color: NSColor, to target: ColorTarget) {
        switch target {
        case .drawing:
            applyPickedDrawingColor(color)
        case .cover:
            coverColorWell.color = color
            coverColorChanged(nil)
        }
        workflowHint.stringValue = "색을 가져왔습니다."
    }

    /// The eyedropper's committed color path, also driven by controller regression tests.
    func applyPickedDrawingColor(_ color: NSColor) {
        annotationColorWell.color = color
        annotationStyleChanged(nil)
    }

    // MARK: - Eraser options

    @objc func eraserStyleChanged(_ sender: Any?) {
        eraseFromNow = eraseFromNowCheckbox.state == .on
        refreshEraserControls()
        canvas.refreshOverlay()
    }

    var eraserIsBrush: Bool { eraserModeSegment.selectedSegment == 0 }

    func refreshEraserControls() {
        let size = Int(eraserSizeSlider.doubleValue.rounded())
        eraserSizeLabel.stringValue = "크기 \(size)pt"
        eraserSizeSlider.isEnabled = eraserIsBrush && !isExporting
        eraserTargetPopup.isHidden = !eraserIsBrush
        eraseFromNowCheckbox.isHidden = !doc.hasVideo
        eraserHint.stringValue = eraserIsBrush
            ? "문지른 부분만 지웁니다(블러 영역을 지우면 그 자리는 가려지지 않습니다). 지운 자리는 항목을 옮기거나 순서를 바꿔도 함께 움직이고, 영상에서는 지운 시점부터 적용됩니다."
            : "영역이나 그림을 클릭하거나 문질러 통째로 지웁니다. 영상에서는 켜 두면 지금 시점부터 사라지고 그 전 모습은 남습니다."
    }

    /// Eraser-tool removal on video ends each item just before the current time instead of
    /// deleting it, so everything shown earlier stays. Items that start now are removed.
    func endItems(regions: Set<UUID>, drawings: Set<UUID>, at time: Double) {
        let cutoff = time - MotionTrack.sameTime / 2
        func trimmed(_ range: ClosedRange<Double>, entire: Bool) -> ClosedRange<Double>? {
            let start = entire ? 0 : range.lowerBound
            return cutoff - start > MotionTrack.sameTime ? start...cutoff : nil
        }
        var removeRegions = Set<UUID>(), removeDrawings = Set<UUID>()
        var newPairs = pairs, newDrawings = annotations
        for index in newPairs.indices where regions.contains(newPairs[index].shape.id) {
            let effect = newPairs[index].effect
            if let range = trimmed(effect.timeRange, entire: effect.appliesToEntireVideo) { newPairs[index].effect.timeRange = range }
            else { removeRegions.insert(newPairs[index].shape.id) }
        }
        for index in newDrawings.indices where drawings.contains(newDrawings[index].id) {
            let drawing = newDrawings[index]
            if let range = trimmed(drawing.timeRange, entire: drawing.appliesToEntireVideo) { newDrawings[index].timeRange = range }
            else { removeDrawings.insert(drawing.id) }
        }
        guard !RegionEditing.equal(newPairs, pairs) || newDrawings != annotations else { return }
        if gestureSnapshot == nil { checkpoint() }
        pairs = newPairs.filter { !removeRegions.contains($0.shape.id) }
        annotations = newDrawings.filter { !removeDrawings.contains($0.id) }
        if let id = selectedID, regions.contains(id) { selectedID = nil }
        if let id = selectedDrawingID, drawings.contains(id) { selectedDrawingID = nil }
        canvas.setRegionsFromExternal(pairs.map(\.shape))
        refreshAfterEdit()
    }

    /// Brush eraser: rubs out the part of each drawing shown under the stroke. The erasure is stored
    /// in the drawing's own base geometry, so it follows moves, motion, groups and reordering.
    /// Internal for tests.
    func applyEraserStroke(_ points: [CGPoint], width: CGFloat) {
        guard !isExporting, !points.isEmpty, width.isFinite, width > 0 else { return }
        let time = editTime
        let from: Double? = doc.hasVideo && eraseFromNow ? time : nil
        let area = EraseStroke.path(points)
            .copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1).boundingBoxOfPath
        let target = eraserTargetPopup.indexOfSelectedItem // 0 all, 1 drawings, 2 blur regions
        var drawings = annotations, regions = pairs
        var touched = 0
        if target != 2 {
            for index in drawings.indices where drawings[index].isVisible(at: time) && !drawings[index].locked {
                let shown = drawings[index].displayed(at: time)
                let reach = shown.lineWidth / 2 + 2
                guard shown.bounds.insetBy(dx: -reach, dy: -reach).intersects(area) else { continue }
                drawings[index].erasures.append(EraseStroke(points: Self.clamped(points, near: shown.bounds, width: width),
                                                            width: width, from: from)
                    .mapped(from: shown.bounds, to: drawings[index].bounds))
                touched += 1
            }
        }
        if target != 1 {
            // A reverse cover takes no rubbed-out parts (see BlurRenderer), so the eraser passes over it.
            for index in regions.indices where regions[index].effect.isActive(at: time) && !regions[index].effect.locked && !regions[index].effect.inverted {
                let shown = RegionEditing.displayed(regions[index], at: time).boundingRect
                guard shown.intersects(area) else { continue }
                regions[index].effect.erasures.append(EraseStroke(points: Self.clamped(points, near: shown, width: width),
                                                                  width: width, from: from)
                    .mapped(from: shown, to: regions[index].shape.boundingRect))
                touched += 1
            }
        }
        guard touched > 0 else {
            workflowHint.stringValue = "문지른 자리에 지울 항목이 없습니다."
            return
        }
        if gestureSnapshot == nil { checkpoint() }
        annotations = drawings
        pairs = regions
        refreshAfterEdit()
    }

    /// Points far outside the item never touch it; keeping them near its box stops the mapping into
    /// a much larger base box (a tiny recorded size) from producing huge coordinates.
    static func clamped(_ points: [CGPoint], near box: CGRect, width: CGFloat) -> [CGPoint] {
        let area = box.insetBy(dx: -width, dy: -width)
        return points.map { CGPoint(x: min(max($0.x, area.minX), area.maxX), y: min(max($0.y, area.minY), area.maxY)) }
    }

    @objc func restoreErasedFromMenu(_ sender: NSMenuItem) {
        guard !isExporting, let id = sender.representedObject as? UUID else { return }
        endGesture()
        if let index = annotations.firstIndex(where: { $0.id == id }), !annotations[index].erasures.isEmpty {
            checkpoint()
            annotations[index].erasures.removeAll()
        } else if let index = pairs.firstIndex(where: { $0.shape.id == id }), !pairs[index].effect.erasures.isEmpty {
            checkpoint()
            pairs[index].effect.erasures.removeAll()
        } else { return }
        refreshAfterEdit()
    }

    // MARK: - Text

    func promptText(at point: NSPoint) {
        guard let text = askText(title: "글자 넣기", initial: "") else { return }
        addText(text, at: point)
    }

    /// Multi-line prompt (Return adds a line; the 확인 button confirms).
    private func askText(title: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "여러 줄로 쓸 수 있습니다(Return으로 줄바꿈). 넣은 뒤 끌어서 옮기고 모서리로 크기를 바꿀 수 있습니다."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 280, height: 90))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let view = NSTextView(frame: scroll.bounds)
        view.string = initial
        view.font = .systemFont(ofSize: 13)
        view.isRichText = false
        view.autoresizingMask = [.width]
        view.setAccessibilityLabel("글자 내용")
        scroll.documentView = view
        alert.accessoryView = scroll
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = view
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return Self.cleanedText(view.string)
    }

    /// Trims outer blank space and lines; keeps inner line breaks; caps the length.
    static func cleanedText(_ raw: String) -> String? {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(1000))
    }

    private var selectedTextFont: String? {
        let index = textFontPopup.indexOfSelectedItem
        guard index > 0 else { return nil }
        return textFontPopup.selectedItem?.representedObject as? String ?? textFontPopup.titleOfSelectedItem
    }

    private var selectedTextBackground: RGBAColor? {
        switch textBackgroundPopup.indexOfSelectedItem {
        case 1: return RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.55)
        case 2: return RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)
        case 3: return RGBAColor(red: 1, green: 1, blue: 1, alpha: 0.7)
        case 4: return RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
        default: return nil
        }
    }

    /// Places text with its top-left corner at `point`, using the current text settings. Internal for tests.
    func addText(_ string: String, at point: CGPoint) {
        guard !isExporting, let string = Self.cleanedText(string) else { return }
        let size = DrawingAnnotation.fontSize(forLineWidth: CGFloat(annotationWidthSlider.doubleValue))
        var drawing = DrawingAnnotation.text(string, at: .zero, fontSize: size, color: annotationColorWell.color,
                                             fontName: selectedTextFont, bold: textBoldCheckbox.state == .on,
                                             background: selectedTextBackground)
        let box = drawing.bounds
        let origin = CGPoint(x: min(max(0, point.x), max(0, canvas.bounds.width - box.width)),
                             y: min(max(0, point.y - box.height), max(0, canvas.bounds.height - box.height)))
        drawing.points = drawing.points.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
        addAnnotation(drawing)
    }

    /// Edits the text, keeping its size and top-left corner. Internal for tests.
    func replaceText(of id: UUID, with string: String) {
        guard !isExporting, let string = Self.cleanedText(string), let index = annotations.firstIndex(where: { $0.id == id }),
              annotations[index].kind == .text, annotations[index].text != string else { return }
        checkpoint()
        annotations[index] = annotations[index].withText(string)
        refreshAfterEdit()
    }

    /// Font, weight and background controls: set the next text and restyle a selected text.
    @objc func textStyleChanged(_ sender: Any?) {
        guard !isExporting, let id = selectedDrawingID, let index = annotations.firstIndex(where: { $0.id == id }),
              annotations[index].kind == .text, !annotations[index].locked,
              let control = sender as? NSControl else { return }
        var updated = annotations[index]
        if control === textFontPopup {
            updated = updated.withText(updated.text, fontName: .some(selectedTextFont))
        } else if control === textBoldCheckbox {
            updated = updated.withText(updated.text, bold: textBoldCheckbox.state == .on)
        } else if control === textBackgroundPopup {
            updated.textBackground = selectedTextBackground
        } else { return }
        guard updated != annotations[index] else { return }
        checkpoint()
        annotations[index] = updated
        refreshAfterEdit()
    }

    func showTextStyle(_ drawing: DrawingAnnotation) {
        guard drawing.kind == .text else { return }
        textFontPopup.removeAllItems()
        textFontPopup.addItems(withTitles: ["시스템 글꼴"] + DrawingAnnotation.availableFontFamilies)
        if let font = drawing.fontName {
            if !font.isEmpty, let index = textFontPopup.itemTitles.dropFirst().firstIndex(of: font) {
                textFontPopup.selectItem(at: index)
            } else {
                textFontPopup.addItem(withTitle: font.isEmpty ? "시스템 글꼴" : font)
                textFontPopup.lastItem?.representedObject = font
                textFontPopup.selectItem(at: textFontPopup.numberOfItems - 1)
            }
            textFontPopup.toolTip = DrawingAnnotation.fontIsAvailable(font, bold: drawing.bold, size: drawing.textFontSize)
                ? "글꼴"
                : "이 Mac에 없는 글꼴: \(font). 원래 이름을 보존합니다. 출력 전에 설치된 글꼴을 선택하세요."
        } else {
            textFontPopup.selectItem(at: 0)
            textFontPopup.toolTip = "글꼴"
        }
        textBoldCheckbox.state = drawing.bold ? .on : .off
        let options: [RGBAColor?] = [nil, RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.55), RGBAColor(red: 0, green: 0, blue: 0, alpha: 1),
                                     RGBAColor(red: 1, green: 1, blue: 1, alpha: 0.7), RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)]
        textBackgroundPopup.selectItem(at: options.firstIndex(where: { $0 == drawing.textBackground }) ?? 0)
    }

    /// Text controls show in text mode or while a text drawing is selected.
    func refreshTextControls() {
        let selected = selectedDrawingID.flatMap { id in annotations.first { $0.id == id } }
        let selectedText = selected?.kind == .text
        textTools.isHidden = !(toolSegment.selectedSegment == 1 && (canvasMode == .drawText || selectedText))
        for control in [textFontPopup, textBoldCheckbox, textBackgroundPopup] as [NSControl] {
            control.isEnabled = !isExporting && !(selected?.locked ?? false)
        }
    }

    func editText(_ id: UUID) {
        guard let drawing = annotations.first(where: { $0.id == id }), drawing.kind == .text,
              let text = askText(title: "글자 고치기", initial: drawing.text) else { return }
        replaceText(of: id, with: text)
    }
}
