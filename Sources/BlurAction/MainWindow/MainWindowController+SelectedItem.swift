import AppKit
import AVKit
import AVFoundation
import UniformTypeIdentifiers
import os
import Darwin

// MainWindowController: 선택 항목의 시간 구간·움직임 기록·정밀 조정.

extension MainWindowController {
    // MARK: - Selected item timing (region or drawing)

    var hasSelection: Bool { selectedID != nil || selectedDrawingID != nil }

    private var selectedKeyframes: [RegionKeyframe] {
        if let id = selectedID, let pair = pairs.first(where: { $0.shape.id == id }) { return pair.effect.keyframes }
        if let id = selectedDrawingID, let drawing = annotations.first(where: { $0.id == id }) { return drawing.keyframes }
        return []
    }

    private var selectedTiming: ClosedRange<Double>? {
        if let id = selectedID, let pair = pairs.first(where: { $0.shape.id == id }) { return pair.effect.timeRange }
        if let id = selectedDrawingID, let drawing = annotations.first(where: { $0.id == id }) { return drawing.timeRange }
        return nil
    }

    @objc func previousKeyframe() {
        let now = canvas.currentVideoTime
        guard doc.hasVideo, let time = selectedKeyframes.map(\.time).filter({ $0 < now - MotionTrack.sameTime }).max() else { NSSound.beep(); return }
        stopPlayback()
        seek(to: time)
    }

    @objc func nextKeyframe() {
        let now = canvas.currentVideoTime
        guard doc.hasVideo, let time = selectedKeyframes.map(\.time).filter({ $0 > now + MotionTrack.sameTime }).min() else { NSSound.beep(); return }
        stopPlayback()
        seek(to: time)
    }

    /// Moves recorded position `index` of the selected item to `time`, kept between its neighbours.
    /// Internal for tests (the timeline strip calls it after a drag).
    func retimeKeyframe(_ index: Int, to time: Double) {
        guard doc.hasVideo, !isExporting, time.isFinite else { return }
        func retimed(_ frames: [RegionKeyframe]) -> [RegionKeyframe]? {
            guard frames.indices.contains(index) else { return nil }
            let low = index > 0 ? frames[index - 1].time + MotionTrack.sameTime * 2 : 0
            let high = index < frames.count - 1 ? frames[index + 1].time - MotionTrack.sameTime * 2 : doc.duration
            guard low <= high else { return nil }
            var result = frames
            result[index].time = min(high, max(low, time))
            return result == frames ? nil : result
        }
        endGesture()
        if let id = selectedID, let i = pairs.firstIndex(where: { $0.shape.id == id }), let frames = retimed(pairs[i].effect.keyframes) {
            checkpoint()
            pairs[i].effect.keyframes = frames
        } else if let id = selectedDrawingID, let i = annotations.firstIndex(where: { $0.id == id }), let frames = retimed(annotations[i].keyframes) {
            checkpoint()
            annotations[i].keyframes = frames
        } else { return }
        refreshAfterEdit()
    }

    /// Drags of the timeline band's ends. Internal for tests.
    func moveRangeEdge(start: Bool, to time: Double) {
        guard doc.hasVideo, !isExporting, time.isFinite, let current = selectedTiming else { return }
        let range = current.lowerBound == 0 && current.upperBound == 0 ? 0...doc.duration : current
        let t = min(doc.duration, max(0, time))
        let lower = start ? t : range.lowerBound, upper = start ? range.upperBound : t
        guard upper - lower > MotionTrack.sameTime else { NSSound.beep(); return }
        endGesture()
        setSelectedTimeRange(lower == 0 && abs(upper - doc.duration) < MotionTrack.sameTime ? 0...0 : lower...upper)
    }

    func selectedMotionPath() -> [CGPoint] {
        guard doc.hasVideo else { return [] }
        return selectedKeyframes.map { CGPoint(x: $0.rect.midX, y: $0.rect.midY) }
    }

    /// Applies to the selected item and, when it is grouped, to every member of its group.
    func setSelectedTimeRange(_ range: ClosedRange<Double>) {
        guard let id = currentSelectionID else { return }
        let group = groupIDOfItem(id)
        func member(_ itemID: UUID, _ itemGroup: UUID?) -> Bool { itemID == id || (group != nil && itemGroup == group) }
        var newPairs = pairs, newDrawings = annotations
        for index in newPairs.indices where member(newPairs[index].shape.id, newPairs[index].effect.groupID) {
            newPairs[index].effect.timeRange = range
        }
        for index in newDrawings.indices where member(newDrawings[index].id, newDrawings[index].groupID) {
            newDrawings[index].timeRange = range
        }
        guard !RegionEditing.equal(newPairs, pairs) || newDrawings != annotations else { return }
        if gestureSnapshot == nil { checkpoint() }
        pairs = newPairs
        annotations = newDrawings
        refreshAfterEdit()
    }

    @objc func blurChanged(_ sender: NSSlider) {
        let v = CGFloat(sender.doubleValue).rounded()
        blurValueLabel.stringValue = "\(Int(v))px"
        updateSelectedEffect { $0.blurRadius = v }
    }

    @objc func featherChanged(_ sender: NSSlider) {
        let v = CGFloat(sender.doubleValue).rounded()
        featherValueLabel.stringValue = "\(Int(v))px"
        updateSelectedEffect { $0.featherRadius = v }
        liveBlur.refresh()
    }

    @objc func qualityChanged(_ sender: NSPopUpButton) {
        if let title = sender.titleOfSelectedItem, let q = QualityPreset(rawValue: title) {
            quality = q
        }
        refreshQualityInfo()
    }

    @objc func imageFormatChanged(_ sender: NSPopUpButton) { refreshQualityInfo() }

    func updateSelectedEffect(coalescing key: String? = nil, _ transform: (inout RegionEffect) -> Void) {
        guard let sel = selectedID,
              let idx = pairs.firstIndex(where: { $0.shape.id == sel }) else { return }
        guard !isExporting else { return }
        var eff = pairs[idx].effect
        transform(&eff)
        guard eff != pairs[idx].effect else { return }
        if gestureSnapshot == nil { checkpoint(coalescing: key.map { "\($0)-\(sel)" }) }
        pairs[idx].effect = eff
        refreshRegionList()
        canvas.refreshOverlay()
        liveBlur.refresh()
    }

    func refreshSelectedEditor() {
        refreshCoverAttachments()
        refreshAutomaticCoverControls()
        let hasCover = selectedID.flatMap { id in pairs.first { $0.shape.id == id } } != nil
        selectedTitle.stringValue = selectedDrawingID != nil ? "그림 설정" : hasCover ? "선택한 가림" : toolSegment.selectedSegment == 2 ? "지우개 설정" : "새 영역 설정"
        selectedHint.stringValue = hasSelection ? "선택한 항목의 설정입니다. 레이어에서 다른 항목을 고를 수 있습니다."
            : "미리보기에서 영역을 그리거나 레이어를 선택하세요."
        selectedHint.isHidden = hasSelection
        modeSegment.isHidden = toolSegment.selectedSegment == 2 || hasSelection
        if let id = selectedDrawingID, let drawing = annotations.first(where: { $0.id == id }) {
            showTextStyle(drawing)
        }
        refreshTextControls()
        timeRangeEditor.isHidden = !doc.hasVideo
        motionTools.isHidden = !doc.hasVideo
        let canEditRange = doc.hasVideo && hasSelection && !isExporting
        for control in [rangeStart, rangeEnd, rangeApply, rangeEntire] as [NSControl] { control.isEnabled = canEditRange }
        let canEditPosition = doc.mediaKind != .none && hasSelection && !isExporting
        for control in [positionX, positionY, positionWidth, positionHeight, applyPositionButton] as [NSControl] {
            control.isEnabled = canEditPosition
        }
        recordPositionButton.isEnabled = canEditRange && playheadTime != nil
        autoTrackButton.isEnabled = doc.hasVideo && (hasSelection || multiSelection.count > 1) && !isExporting
        trackAfterFindCheckbox.isHidden = !doc.hasVideo
        for button in [findFacesButton, findTextButton] { button.isEnabled = doc.mediaKind != .none && !isExporting }
        let foundLeft = !foundIDsStillHere.isEmpty && !isExporting
        selectFoundButton.isEnabled = foundLeft
        deleteFoundButton.isEnabled = foundLeft
        let canStep = doc.hasVideo && !isExporting && doc.videoFPS > 0
        previousFrameButton.isEnabled = canStep
        nextFrameButton.isEnabled = canStep
        rangeHint.textColor = .secondaryLabelColor
        mainContainer.slider.markers = doc.hasVideo ? selectedKeyframes.map(\.time) : []
        mainContainer.slider.rangeBand = doc.hasVideo ? selectedTiming.map { $0.lowerBound == 0 && $0.upperBound == 0 ? 0...doc.duration : $0 } : nil
        previousKeyButton.isEnabled = doc.hasVideo && !isExporting && selectedKeyframes.contains { $0.time < canvas.currentVideoTime - MotionTrack.sameTime }
        nextKeyButton.isEnabled = doc.hasVideo && !isExporting && selectedKeyframes.contains { $0.time > canvas.currentVideoTime + MotionTrack.sameTime }
        refreshCoverControls()
        canvas.refreshOverlay()
        let timing: (range: ClosedRange<Double>, entire: Bool)
        if let id = selectedDrawingID, let drawing = annotations.first(where: { $0.id == id }) {
            blurSlider.doubleValue = 0
            featherSlider.doubleValue = 0
            blurValueLabel.stringValue = "—"
            featherValueLabel.stringValue = "—"
            timing = (drawing.timeRange, drawing.appliesToEntireVideo)
        } else if let sel = selectedID, let pair = pairs.first(where: { $0.shape.id == sel }) {
            blurSlider.doubleValue = Double(pair.effect.blurRadius)
            blurValueLabel.stringValue = "\(Int(pair.effect.blurRadius))px"
            featherSlider.doubleValue = Double(pair.effect.featherRadius)
            featherValueLabel.stringValue = "\(Int(pair.effect.featherRadius))px"
            timing = (pair.effect.timeRange, pair.effect.appliesToEntireVideo)
        } else {
            blurSlider.doubleValue = 0
            featherSlider.doubleValue = 0
            blurValueLabel.stringValue = "—"
            featherValueLabel.stringValue = "—"
            rangeHint.stringValue = "영역이나 그림을 선택한 뒤 시간을 지정하세요."
            for field in [positionX, positionY, positionWidth, positionHeight] { field.stringValue = "" }
            return
        }
        refreshPositionFields()
        rangeStart.stringValue = String(format: "%.2f", timing.entire ? 0 : timing.range.lowerBound)
        rangeEnd.stringValue = String(format: "%.2f", timing.entire ? doc.duration : timing.range.upperBound)
        rangeHint.stringValue = timing.entire ? "현재: 영상 전체" : "현재: \(rangeStart.stringValue) ~ \(rangeEnd.stringValue)초"
    }

    /// Displayed bounding box of the selected region or drawing at the playhead.
    var selectedDisplayedRect: CGRect? {
        if let id = selectedID, let pair = pairs.first(where: { $0.shape.id == id }) {
            return RegionEditing.displayed(pair, at: editTime).boundingRect
        }
        if let id = selectedDrawingID, let drawing = annotations.first(where: { $0.id == id }) {
            return drawing.displayed(at: editTime).bounds
        }
        return nil
    }

    func refreshPositionFields() {
        guard let displayed = selectedDisplayedRect else { return }
        let source = doc.appliedVideoSize
        guard canvas.bounds.width > 0, canvas.bounds.height > 0, source.width > 0, source.height > 0 else { return }
        let sx = source.width / canvas.bounds.width
        let sy = source.height / canvas.bounds.height
        positionX.stringValue = String(format: "%.1f", displayed.minX * sx)
        positionY.stringValue = String(format: "%.1f", (canvas.bounds.height - displayed.maxY) * sy)
        positionWidth.stringValue = String(format: "%.1f", displayed.width * sx)
        positionHeight.stringValue = String(format: "%.1f", displayed.height * sy)
    }

    @objc func applyTimeRange() {
        guard doc.hasVideo, hasSelection, !isExporting else { return }
        guard let start = Double(rangeStart.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let end = Double(rangeEnd.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              start.isFinite, end.isFinite, start >= 0, start < doc.duration, start < end, end <= doc.duration + 0.005 else {
            rangeHint.textColor = .systemRed
            rangeHint.stringValue = "0 ~ \(String(format: "%.2f", doc.duration))초 사이에서 시작 < 끝으로 입력하세요."
            return
        }
        endGesture()
        setSelectedTimeRange(start...min(end, doc.duration))
        refreshSelectedEditor()
    }

    @objc func applyEntireVideo() {
        guard doc.hasVideo, hasSelection, !isExporting else { return }
        endGesture()
        setSelectedTimeRange(0...0)
        refreshSelectedEditor()
    }

    func addRegion() {
        guard doc.mediaKind != .none, !isExporting else { return }
        checkpoint()
        let rect = canvas.displayRect == .zero ? canvas.bounds : canvas.displayRect
        let def = CGSize(width: max(40, rect.width * 0.25), height: max(40, rect.height * 0.25))
        let origin = CGPoint(x: rect.midX - def.width / 2, y: rect.midY - def.height / 2)
        let shape = RegionShape.rectangle(id: UUID(), origin: origin, size: def)
        var effect = RegionEffect.created(at: playheadTime, videoDuration: doc.hasVideo ? doc.duration : nil)
        applyDefaultCover(to: &effect)
        pairs.append((shape, effect))
        canvas.refreshOverlay()
        selectedID = shape.id
        canvas.selectRegion(id: shape.id)
        refreshRegionList()
        refreshSelectedEditor()
        liveBlur.refresh()
    }

    func deleteSelected() {
        guard !isExporting else { return }
        let lockedHint = "잠긴 레이어입니다. 레이어 목록에서 잠금을 풀면 지울 수 있습니다."
        if multiSelection.count > 1, let current = currentSelectionID, multiSelection.contains(current) {
            // Several chosen: remove the unlocked ones even when the last one clicked is locked.
            let ids = Set(multiSelection.filter { !layerState($0).locked })
            guard !ids.isEmpty else { NSSound.beep(); workflowHint.stringValue = lockedHint; return }
            endGesture()
            multiSelection.removeAll()
            eraseItems(regions: ids, drawings: ids)
            return
        }
        if let id = currentSelectionID, layerState(id).locked {
            NSSound.beep()
            workflowHint.stringValue = lockedHint
            return
        }
        if let id = selectedDrawingID {
            endGesture()
            eraseItems(regions: [], drawings: [id])
            return
        }
        if let id = selectedID {
            endGesture()
            eraseItems(regions: [id], drawings: [])
            return
        }
        canvas.deleteSelected()
        refreshRegionList()
        refreshSelectedEditor()
        liveBlur.refresh()
    }
}
