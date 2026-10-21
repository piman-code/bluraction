import AppKit
import AVKit
import AVFoundation
import UniformTypeIdentifiers
import os
import Darwin

// MainWindowController: 가림 글자·이모지, 추적 확인·보정, 자동 가림 모양.

// MARK: - Cover labels and reviewable tracking
extension MainWindowController {
    func configureCoverAttachments() {
        let title = NSTextField(labelWithString: "가림에 글자·이모지 붙이기")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        decorationField.placeholderString = "예: 학생 A 또는 🙂"
        decorationField.setAccessibilityLabel("가림에 붙일 내용")
        decorationField.widthAnchor.constraint(equalToConstant: 195).isActive = true
        decorationScale.setAccessibilityLabel("가림 안의 글자 크기")
        decorationScale.toolTip = "가림 영역 안에서 차지할 크기 (비율 유지·중앙 맞춤)"
        decorationScale.widthAnchor.constraint(equalToConstant: 135).isActive = true
        decorationColor.color = .white
        decorationColor.setAccessibilityLabel("가림 글자 색")
        decorationColor.widthAnchor.constraint(equalToConstant: 32).isActive = true
        decorationApply.target = self; decorationApply.action = #selector(applyDecorationTapped)
        decorationRemove.target = self; decorationRemove.action = #selector(removeDecorationTapped)
        for button in [decorationApply, decorationRemove, reviewGo, reviewRetry, reviewHold] {
            button.bezelStyle = .rounded; button.controlSize = .small
        }
        let content = NSStackView(views: [decorationField, decorationApply]); content.spacing = 6
        let appearance = NSStackView(views: [decorationScale, decorationColor, decorationRemove]); appearance.spacing = 6
        let reviewTitle = NSTextField(labelWithString: "추적 확인·보정")
        reviewTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        reviewPopup.widthAnchor.constraint(equalToConstant: 265).isActive = true
        reviewPopup.setAccessibilityLabel("확인할 추적 구간")
        reviewGo.target = self; reviewGo.action = #selector(goToReviewTapped)
        reviewRetry.target = self; reviewRetry.action = #selector(retryReviewTapped)
        reviewHold.target = self; reviewHold.action = #selector(holdReviewTapped)
        for label in [decorationHint, reviewHint] {
            label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = 290
        }
        for view in [inspectorDivider(), title, content, appearance, decorationHint] as [NSView] { decorationTools.addArrangedSubview(view) }
        for view in [reviewTitle, reviewPopup, reviewGo, reviewRetry, reviewHold, reviewHint] as [NSView] {
            reviewTools.addArrangedSubview(view)
        }
    }

    @discardableResult
    func setCoverDecoration(_ id: UUID, text: String, scale: CGFloat = 0.8,
                            color: RGBAColor = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)) -> Bool {
        guard !isExporting, let index = pairs.firstIndex(where: { $0.shape.id == id }),
              !pairs[index].effect.locked, !pairs[index].effect.inverted else { return false }
        let label = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil
            : CoverDecoration(text: text, scale: scale, color: color)
        guard label?.isValid ?? true else {
            workflowHint.stringValue = "내용은 1,000자 이내, 크기는 10~100%로 입력하세요."
            return false
        }
        guard label != pairs[index].effect.decoration else { return true }
        endGesture(); checkpoint()
        pairs[index].effect.decoration = label
        decorationSelection = nil
        refreshAfterEdit()
        return true
    }

    @objc private func applyDecorationTapped() {
        guard let id = selectedID, let color = decorationColor.color.usingColorSpace(.sRGB) else { return }
        _ = setCoverDecoration(id, text: decorationField.stringValue, scale: CGFloat(decorationScale.doubleValue / 100),
                               color: RGBAColor(red: color.redComponent, green: color.greenComponent,
                                                blue: color.blueComponent, alpha: color.alphaComponent))
    }
    @objc private func removeDecorationTapped() {
        guard let id = selectedID else { return }; _ = setCoverDecoration(id, text: "")
    }

    var pendingTrackingReviews: [(regionID: UUID, review: TrackingReview)] {
        pairs.flatMap { pair in pair.effect.trackingReviews.filter { $0.status == .needsReview }
            .map { (regionID: pair.shape.id, review: $0) } }
            .sorted { $0.review.start < $1.review.start }
    }
    private var chosenTrackingReview: (regionID: UUID, review: TrackingReview)? {
        let rows = pendingTrackingReviews, index = reviewPopup.indexOfSelectedItem
        return rows.indices.contains(index) ? rows[index] : nil
    }
    /// Position edits while correcting a review must not bend the path outside that interval.
    func preservingReviewExterior(_ changed: [RegionEditing.Pair], before: [RegionEditing.Pair]) -> [RegionEditing.Pair] {
        guard let selection = reviewSelection, let time = editTime,
              let original = before.first(where: { $0.shape.id == selection.region }),
              let issue = original.effect.trackingReviews.first(where: { $0.id == selection.review && $0.status == .needsReview }),
              time >= issue.start, time <= issue.end,
              let index = changed.firstIndex(where: { $0.shape.id == selection.region }) else { return changed }
        var result = changed
        guard !RegionEditing.equal([original], [changed[index]]) else { return changed }
        let rect = RegionEditing.displayed(changed[index], at: time).boundingRect
        var frames = changed[index].effect.keyframes.filter { $0.time >= issue.start && $0.time <= issue.end }
        frames = MotionTrack.inserting(.init(time: time, rect: rect), into: frames)
        frames += original.effect.keyframes.filter { $0.time < issue.start || $0.time > issue.end }
        for boundary in [issue.start.nextDown, issue.end.nextUp] where boundary >= 0 && boundary <= doc.duration {
            if !frames.contains(where: { $0.time == boundary }) {
                frames.append(.init(time: boundary, rect: RegionEditing.displayed(original, at: boundary).boundingRect))
            }
        }
        result[index].shape = original.effect.automaticCover == nil ? original.shape
            : .rectangle(id: original.shape.id, origin: original.shape.boundingRect.origin, size: original.shape.boundingRect.size)
        result[index].effect.keyframes = frames.sorted { $0.time < $1.time }
        return result
    }
    func refreshCoverAttachments() {
        let pair = selectedID.flatMap { id in pairs.first { $0.shape.id == id } }
        let canEdit = !isExporting && pair != nil && pair?.effect.locked == false && pair?.effect.inverted == false
        for control in [decorationField, decorationScale, decorationColor, decorationApply, decorationRemove] as [NSControl] {
            control.isEnabled = canEdit
        }
        if decorationSelection != selectedID || decorationDisplayed != pair?.effect.decoration {
            // Preserve unapplied drafts across playhead/selection-editor refreshes.
                decorationField.stringValue = pair?.effect.decoration?.text ?? ""
                decorationScale.doubleValue = Double(pair?.effect.decoration?.scale ?? 0.8) * 100
                if let c = pair?.effect.decoration?.color {
                    decorationColor.color = NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
                } else { decorationColor.color = .white }
            decorationSelection = selectedID
            decorationDisplayed = pair?.effect.decoration
        }
        decorationHint.stringValue = pair?.effect.inverted == true ? "역가림 영역에는 내용을 붙이지 않습니다."
            : pair?.effect.locked == true ? "잠금을 풀면 붙인 내용을 수정할 수 있습니다."
            : "가림과 함께 이동·확대되고 같은 시간 동안 표시됩니다."
        let oldID = reviewPopup.selectedItem?.representedObject as? UUID
        let rows = pendingTrackingReviews
        taskPanelSelector.setLabel(rows.isEmpty ? "확인" : "확인 \(rows.count)", forSegment: InspectorPanel.review.rawValue)
        reviewTools.isHidden = !doc.hasVideo
        staticReviewHint.isHidden = doc.hasVideo
        reviewPopup.removeAllItems()
        for row in rows {
            let reason: String
            switch row.review.reason {
            case .lostTarget: reason = "추적 끊김"
            case .recognitionGap: reason = "문구 재확인 필요"
            case .cancelled: reason = "중단된 추적"
            case .sampledInterval: reason = "긴 검사 간격"
            }
            reviewPopup.addItem(withTitle: String(format: "%.2f–%.2f초 · %@", row.review.start, row.review.end, reason))
            reviewPopup.lastItem?.representedObject = row.review.id
        }
        if let index = rows.firstIndex(where: { $0.review.id == oldID }) { reviewPopup.selectItem(at: index) }
        if rows.isEmpty { reviewPopup.addItem(withTitle: "확인할 구간 없음") }
        reviewPopup.isEnabled = doc.hasVideo && !isExporting && !rows.isEmpty
        reviewGo.isEnabled = reviewPopup.isEnabled
        let current = chosenTrackingReview
        let atReview = current.map { reviewSelection?.region == $0.regionID && reviewSelection?.review == $0.review.id } ?? false
        let unlocked = current.map { !layerState($0.regionID).locked } ?? false
        reviewRetry.isEnabled = reviewPopup.isEnabled && atReview && unlocked
        reviewHold.isEnabled = reviewRetry.isEnabled
        reviewHint.stringValue = rows.isEmpty ? "자동 검사는 모든 누락을 찾지 못합니다. 출력 전 전체 결과를 확인하세요."
            : "\(rows.count)개 구간: 이동한 뒤 가림 위치를 조정하고 다시 추적하거나 현재 위치로 구간을 덮으세요."
    }

    @discardableResult
    func selectTrackingReview(regionID: UUID, reviewID: UUID) -> Bool {
        guard doc.hasVideo, !isExporting,
              let row = pendingTrackingReviews.first(where: { $0.regionID == regionID && $0.review.id == reviewID }) else { return false }
        stopPlayback(); endGesture()
        reviewSelection = (regionID, reviewID)
        selectedID = regionID; selectedDrawingID = nil; multiSelection = []
        canvas.selectRegion(id: regionID)
        trackMotion = true; trackMotionCheckbox.state = .on
        seek(to: row.review.start)
        if let index = pendingTrackingReviews.firstIndex(where: { $0.review.id == reviewID }) { reviewPopup.selectItem(at: index) }
        refreshSelectedEditor()
        workflowHint.stringValue = "가림을 대상에 맞춘 뒤 ‘이 구간 다시 추적’ 또는 ‘현재 위치로 구간 보정’을 누르세요."
        showInspectorPanel(.review)
        return true
    }
    @objc private func goToReviewTapped() {
        guard let row = chosenTrackingReview else { return }
        _ = selectTrackingReview(regionID: row.regionID, reviewID: row.review.id)
    }
    @objc private func retryReviewTapped() {
        guard let row = chosenTrackingReview else { return }
        retryTrackingReview(regionID: row.regionID, reviewID: row.review.id)
    }
    func retryTrackingReview(regionID: UUID, reviewID: UUID) {
        guard !isExporting, doc.hasVideo, let time = playheadTime,
              let row = pendingTrackingReviews.first(where: { $0.regionID == regionID && $0.review.id == reviewID }),
              !layerState(regionID).locked else { return }
        guard abs(time - row.review.start) <= max(0.1, 1 / max(1, doc.videoFPS)) else {
            workflowHint.stringValue = "해당 구간의 시작으로 이동한 뒤 위치를 맞춰 주세요."; return
        }
        repairingReview = (regionID, reviewID, row.review.end)
        startTracking(ids: [regionID], choice: .forward, until: row.review.end)
        if !isTracking { repairingReview = nil }
    }
    @objc private func holdReviewTapped() {
        guard let row = chosenTrackingReview else { return }
        _ = holdTrackingReview(regionID: row.regionID, reviewID: row.review.id)
    }
    @discardableResult
    func holdTrackingReview(regionID: UUID, reviewID: UUID) -> Bool {
        guard doc.hasVideo, !isExporting, selectedID == regionID,
              let index = pairs.firstIndex(where: { $0.shape.id == regionID }), !pairs[index].effect.locked,
              let issueIndex = pairs[index].effect.trackingReviews.firstIndex(where: { $0.id == reviewID && $0.status == .needsReview }),
              let time = playheadTime else { return false }
        let issue = pairs[index].effect.trackingReviews[issueIndex]
        guard time >= issue.start - 0.05, time <= issue.end + 0.05 else { return false }
        let old = pairs[index].effect
        let rect = old.automaticCover == nil ? RegionEditing.displayed(pairs[index], at: time).boundingRect
            : MotionTrack.rect(at: time, base: pairs[index].shape.boundingRect, keyframes: old.keyframes)
        var frames = old.keyframes.filter { $0.time < issue.start || $0.time > issue.end }
        for boundary in [issue.start.nextDown, issue.end.nextUp] where boundary >= 0 && boundary <= doc.duration {
            if !frames.contains(where: { $0.time == boundary }) {
                frames.append(.init(time: boundary, rect: old.automaticCover == nil ? old.shape(pairs[index].shape, at: boundary).boundingRect
                    : MotionTrack.rect(at: boundary, base: pairs[index].shape.boundingRect, keyframes: old.keyframes)))
            }
        }
        frames.append(.init(time: issue.start, rect: rect))
        if issue.end != issue.start { frames.append(.init(time: issue.end, rect: rect)) }
        frames.sort { $0.time < $1.time }
        endGesture(); checkpoint()
        pairs[index].effect.keyframes = frames
        if pairs[index].effect.automaticCover != nil {
            pairs[index].effect.automaticCover?.mode = .generous
            pairs[index].effect.automaticCover?.evidenceKeyframes = []
        }
        pairs[index].effect.trackingReviews[issueIndex].status = .corrected
        reviewSelection = nil
        refreshAfterEdit()
        workflowHint.stringValue = "선택한 구간을 현재 가림 위치로 보정했습니다. ⌘Z로 되돌립니다."
        return true
    }

    func findAndTrackPhrases(_ phrases: [String], completion: (() -> Void)?) {
        guard let url = doc.url else { completion?(); return }
        do { try doc.validateSourceUnchanged() } catch { showError(error.localizedDescription); completion?(); return }
        stopPlayback(); endGesture()
        let context = FindContext(url: url, page: pageWorkspace?.currentIndex, time: nil)
        let duration = doc.duration
        setExporting(true)
        let step = PhraseCover.sampleTimes(duration: duration, step: PhraseTracker.defaultRecognitionStep).step
        progressIndicator.doubleValue = 0; progressIndicator.isHidden = false; cancelButton.isHidden = false
        progressLabel.stringValue = String(format: "문구 찾아 추적 중 · 문자 재확인 %.2f초 간격", step)
        let indicator = progressIndicator
        let report: (Double) -> Void = { value in DispatchQueue.main.async { indicator.doubleValue = value * 100 } }
        let (task, cancellation) = finding.startPhraseTracking(phrases, url: url, duration: duration, report: report)
        Task { [weak self] in
            let result = await task.value
            guard let self else { completion?(); return }
            self.phraseTrackingTask = nil; self.phraseTrackingCancellation = nil
            self.progressIndicator.isHidden = true; self.cancelButton.isHidden = true
            self.progressLabel.stringValue = ""; self.setExporting(false)
            guard !task.isCancelled, !cancellation.isCancelled else {
                self.workflowHint.stringValue = "문구 추적을 취소했습니다. 기존 편집을 유지했습니다."; completion?(); return
            }
            guard context == FindContext(url: self.doc.url, page: self.pageWorkspace?.currentIndex, time: nil) else { completion?(); return }
            do {
                try self.doc.validateSourceUnchanged()
                switch result {
                case .failure(let error): self.showError(error.localizedDescription)
                case .success(let outcome):
                    if !outcome.cancelled { try self.applyPhraseTracking(outcome) }
                }
            } catch { self.showError(error.localizedDescription) }
            completion?()
        }
    }

    func applyPhraseTracking(_ outcome: PhraseTracker.Outcome) throws {
        guard !isExporting, doc.hasVideo, !outcome.cancelled else { return }
        guard outcome.recognitionStep.isFinite, outcome.recognitionStep > 0,
              Set(outcome.tracks.map(\.id)).count == outcome.tracks.count,
              outcome.tracks.allSatisfy({ track in
                  track.start.isFinite && track.end.isFinite && track.start >= 0 && track.end <= doc.duration + 0.01 &&
                  track.end >= track.start && track.samples.count <= 100_000 && track.samples.allSatisfy {
                      $0.time.isFinite && $0.time >= track.start - 0.01 && $0.time <= track.end + 0.01 &&
                      $0.box.minX.isFinite && $0.box.minY.isFinite && $0.box.width.isFinite && $0.box.height.isFinite &&
                      $0.box.width > 0 && $0.box.height > 0
                  }
              }), outcome.reviews.allSatisfy({ issue in
                  issue.start.isFinite && issue.end.isFinite && issue.start >= 0 && issue.end >= issue.start &&
                  outcome.tracks.contains { $0.id == issue.trackID && issue.start >= $0.start - 0.01 && issue.end <= $0.end + 0.01 }
              }) else { throw ProjectFile.ProjectError.invalidContent }
        let usable = outcome.tracks.filter { !$0.samples.isEmpty && $0.end > $0.start }
        guard pairs.count + usable.count <= 1_000 else { throw ProjectFile.ProjectError.tooLarge }
        let size = canvas.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        func rect(_ box: CGRect) -> CGRect {
            CGRect(x: box.minX * size.width, y: box.minY * size.height, width: box.width * size.width, height: box.height * size.height)
        }
        guard !usable.isEmpty else {
            workflowHint.stringValue = String(format: "문구를 찾지 못했습니다. 문자 검사 %.2f초 간격 · 짧거나 흐린 글자는 놓칠 수 있습니다.", outcome.recognitionStep)
            return
        }
        var candidate = pairs
        var ids: [UUID] = []
        for track in usable {
            let id = UUID(), box = rect(track.samples[0].box)
            var effect = RegionEffect.alwaysOn(); applyDefaultCover(to: &effect)
            effect.name = "문구 \(String(track.phrase.prefix(190)))"
            effect.timeRange = track.start...min(doc.duration, track.end)
            effect.keyframes = track.samples.sorted { $0.time < $1.time }.map { .init(time: $0.time, rect: rect($0.box)) }
            effect.trackingReviews = outcome.reviews.filter { $0.trackID == track.id }.map {
                let reason: TrackingReview.Reason
                switch $0.reason {
                case .trackingLost: reason = .lostTarget
                case .samplingGap: reason = .sampledInterval
                case .textUnconfirmed, .sceneChange: reason = .recognitionGap
                }
                return TrackingReview(start: $0.start, end: min(doc.duration, $0.end), reason: reason)
            }
            if let anchor = track.coverEvidence.first,
               let fit = automaticCover(kind: .text, points: anchor.points, box: track.samples[0].box) {
                effect.automaticCover = fittedCover(fit, anchors: track.coverEvidence)
                effect.automaticCover?.phrases = PhraseCover.parse(track.phrase).phrases
                effect.featherRadius = min(effect.featherRadius, 2)
                effect.trackingReviews += refinementGaps(samples: track.samples, anchors: track.coverEvidence,
                                                        start: track.start, end: track.end)
            }
            candidate.append((.rectangle(id: id, origin: box.origin, size: box.size), effect)); ids.append(id)
        }
        // Validate the complete candidate before touching existing editing or its Undo history.
        let unit = CGSize(width: 1, height: 1)
        let validated = ProjectFile(mediaPath: doc.url?.lastPathComponent ?? "video",
            regions: RegionEditing.scaled(candidate, from: size, to: unit).map { .init(shape: $0.shape, effect: $0.effect) },
            drawings: annotations.map { $0.scaled(from: size, to: unit) })
        _ = try ProjectFile.decode(validated.encoded(), allowsReverse: true)
        endGesture(); checkpoint(); pairs = candidate
        canvas.setRegionsFromExternal(pairs.map(\.shape)); lastFound = (ids, doc.url, pageWorkspace?.currentIndex)
        if let id = ids.first { canvas.selectRegion(id: id) }; multiSelection = ids.count > 1 ? ids : []
        refreshAfterEdit()
        workflowHint.stringValue = String(format: "문구 %d곳 추적 · 문자 재확인 %.2f초 간격 · 확인할 구간 %d개. 짧은 등장도 전체 결과에서 확인하세요.",
                                         ids.count, outcome.recognitionStep, pendingTrackingReviews.count)
        showInspectorPanel(pendingTrackingReviews.isEmpty ? .selected : .review)
    }
}

extension MainWindowController {
    func automaticCover(kind: AutomaticCover.Kind, points: [CGPoint], box: CGRect) -> AutomaticCover? {
        FindPlacement.automaticCover(kind: kind, points: points, box: box, sourceSize: doc.appliedVideoSize)
    }

    func setupAutomaticCoverControls() {
        automaticCoverTools.orientation = .vertical
        automaticCoverTools.alignment = .leading
        automaticCoverTools.spacing = 8
        automaticCoverTools.identifier = NSUserInterfaceItemIdentifier("automaticCoverTools")
        let title = NSTextField(labelWithString: "가림 영역 다듬기")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let marginTitle = NSTextField(labelWithString: "안전 여백 · 원본 픽셀")
        marginTitle.font = .systemFont(ofSize: 12)
        safetyMarginSlider.minValue = 4; safetyMarginSlider.maxValue = 32; safetyMarginSlider.doubleValue = 8
        safetyMarginSlider.isContinuous = true
        safetyMarginSlider.identifier = NSUserInterfaceItemIdentifier("safetyMarginSlider")
        safetyMarginSlider.setAccessibilityLabel("안전 여백")
        safetyMarginSlider.target = self; safetyMarginSlider.action = #selector(safetyMarginChanged(_:))
        safetyMarginSlider.editingBegan = { [weak self] in self?.beginGesture() }
        safetyMarginSlider.editingEnded = { [weak self] in self?.endGesture() }
        let row = NSStackView(views: [safetyMarginSlider, safetyMarginValue]); row.spacing = 8
        generousCoverButton.target = self; generousCoverButton.action = #selector(generousCoverTapped)
        recommendedCoverButton.target = self; recommendedCoverButton.action = #selector(recommendedCoverTapped)
        generousCoverButton.identifier = NSUserInterfaceItemIdentifier("generousCoverButton")
        recommendedCoverButton.identifier = NSUserInterfaceItemIdentifier("recommendedCoverButton")
        let buttons = NSStackView(views: [generousCoverButton, recommendedCoverButton]); buttons.spacing = 8
        automaticCoverHint.font = .systemFont(ofSize: 12)
        automaticCoverHint.textColor = .secondaryLabelColor
        automaticCoverHint.preferredMaxLayoutWidth = 290
        for item in [title, marginTitle, row, buttons, automaticCoverHint] { automaticCoverTools.addArrangedSubview(item) }
    }

    @objc private func safetyMarginChanged(_ sender: NSSlider) {
        guard let id = selectedID else { return }
        _ = setAutomaticCover(id, margin: sender.doubleValue.rounded())
    }
    @objc private func generousCoverTapped() {
        guard let id = selectedID else { return }; _ = setAutomaticCover(id, mode: .generous)
    }
    @objc private func recommendedCoverTapped() {
        guard let id = selectedID else { return }; _ = setAutomaticCover(id, margin: 8, mode: .recommended)
    }

    /// Each edit belongs to this cover, follows Undo/save, and never resolves a review.
    @discardableResult
    func setAutomaticCover(_ id: UUID, margin: Double? = nil, mode: AutomaticCover.Mode? = nil) -> Bool {
        guard !isExporting, let index = pairs.firstIndex(where: { $0.shape.id == id }),
              !pairs[index].effect.locked, pairs[index].effect.erasures.isEmpty,
              var fit = pairs[index].effect.automaticCover else { return false }
        if let margin { guard margin.isFinite, (4...32).contains(margin) else { return false }; fit.safetyMargin = margin }
        if let mode {
            if mode == .recommended, doc.hasVideo, !pairs[index].effect.keyframes.isEmpty,
               fit.evidenceKeyframes.isEmpty { return false }
            fit.mode = mode
        }
        guard fit.isValid, fit != pairs[index].effect.automaticCover else { return false }
        if gestureSnapshot == nil { checkpoint(coalescing: "automatic-cover-\(id)") }
        pairs[index].effect.automaticCover = fit
        refreshAfterEdit()
        return true
    }

    func refreshAutomaticCoverControls() {
        let pair = selectedID.flatMap { id in pairs.first { $0.shape.id == id } }
        guard let pair, let fit = pair.effect.automaticCover else { automaticCoverTools.isHidden = true; return }
        automaticCoverTools.isHidden = false
        let editable = !isExporting && !pair.effect.locked && pair.effect.erasures.isEmpty
        safetyMarginSlider.doubleValue = fit.safetyMargin
        safetyMarginValue.stringValue = "\(Int(fit.safetyMargin))px"
        safetyMarginSlider.isEnabled = editable && fit.mode == .recommended
        generousCoverButton.isEnabled = editable && fit.mode != .generous
        recommendedCoverButton.isEnabled = editable && (!doc.hasVideo || pair.effect.keyframes.isEmpty || !fit.evidenceKeyframes.isEmpty)
        automaticCoverHint.stringValue = fit.mode == .generous
            ? "기존의 넉넉한 범위입니다."
            : "대상에 맞춘 가림 · 확인이 필요한 구간은 넉넉하게 유지합니다. 전체 결과를 확인하세요."
    }
}

extension MainWindowController {
    func fittedCover(_ fit: AutomaticCover, anchors: [PhraseTracker.CoverEvidence]) -> AutomaticCover {
        TrackingMerge.fittedCover(fit, anchors: anchors)
    }

    func refinementGaps(samples: [ObjectTracker.Sample], anchors: [PhraseTracker.CoverEvidence],
                                start: Double, end: Double) -> [TrackingReview] {
        TrackingMerge.refinementGaps(samples: samples, anchors: anchors, start: start, end: end, fps: doc.videoFPS)
    }
}
