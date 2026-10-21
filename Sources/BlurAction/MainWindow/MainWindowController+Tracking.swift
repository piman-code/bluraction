import AppKit
import AVKit
import AVFoundation
import UniformTypeIdentifiers
import os
import Darwin

// MainWindowController: Vision 자동 추적.

extension MainWindowController {
    // MARK: - Automatic tracking (Vision)

    enum TrackChoice: Int { case forward, backward, both }

    /// True once a running tracking task has been asked to stop (window close or 취소). Internal for tests.
    var trackingStopRequested: Bool { trackingCancellation?.isCancelled ?? false }
    var isTracking: Bool { trackingCancellation != nil }

    @objc func autoTrackTapped() {
        let ids = multiSelection.count > 1 ? multiSelection : [currentSelectionID].compactMap { $0 }
        startTracking(ids: ids, choice: TrackChoice(rawValue: trackDirectionPopup.indexOfSelectedItem) ?? .forward)
    }

    private func displayedRect(of id: UUID, at time: Double) -> CGRect? {
        if let pair = pairs.first(where: { $0.shape.id == id }) { return RegionEditing.displayed(pair, at: time).boundingRect }
        return annotations.first(where: { $0.id == id }).map { $0.displayed(at: time).bounds }
    }

    /// Follows every listed item from the playhead (several at once, in the chosen direction).
    /// Internal for tests.
    func startTracking(ids: [UUID], choice: TrackChoice, until: Double? = nil, undoWithPrevious: Bool = false) {
        guard doc.hasVideo, !isExporting, let url = doc.url, let start = playheadTime,
              canvas.bounds.width > 0, canvas.bounds.height > 0 else {
            NSSound.beep()
            workflowHint.stringValue = "영상에서 따라갈 영역이나 그림을 먼저 선택하세요."
            return
        }
        let size = canvas.bounds.size
        var items: [UUID] = [], boxes: [CGRect] = [], tooSmall = 0
        for id in ids where !layerState(id).locked {
            let trackingRect = pairs.first(where: { $0.shape.id == id && $0.effect.automaticCover != nil }).map {
                MotionTrack.rect(at: start, base: $0.shape.boundingRect, keyframes: $0.effect.keyframes)
            }
            guard let rect = trackingRect ?? displayedRect(of: id, at: start), rect.width > 0, rect.height > 0 else { continue }
            let box = CGRect(x: rect.minX / size.width, y: rect.minY / size.height,
                             width: rect.width / size.width, height: rect.height / size.height)
            // The tracker needs at least 1% of the picture each way; skip only the tiny ones.
            guard box.width >= ObjectTracker.minimumSide, box.height >= ObjectTracker.minimumSide else { tooSmall += 1; continue }
            items.append(id)
            boxes.append(box)
        }
        guard !items.isEmpty else {
            NSSound.beep()
            workflowHint.stringValue = ids.isEmpty ? "영상에서 따라갈 영역이나 그림을 먼저 선택하세요."
                : tooSmall > 0 ? "너무 작아서 따라갈 수 없습니다. 영역을 조금 더 크게 잡으세요." : "잠긴 레이어는 추적할 수 없습니다."
            return
        }
        guard until == nil || until!.isFinite else { return }
        let itemEnd = items.map { id -> Double in
            let range = timing(of: id)
            return range.map { $0.lowerBound == 0 && $0.upperBound == 0 ? doc.duration : min(doc.duration, $0.upperBound) } ?? doc.duration
        }.max() ?? doc.duration
        let end = until.map { min(itemEnd, max(start, $0)) } ?? itemEnd
        let minimumSpan = until == nil ? 0.05 : MotionTrack.sameTime
        guard choice != .forward || end - start > minimumSpan else {
            NSSound.beep(); workflowHint.stringValue = "이 항목은 지금 이후로 표시되는 시간이 없습니다."; return
        }
        guard choice != .backward || start > 0.05 else {
            NSSound.beep(); workflowHint.stringValue = "지금이 영상의 시작이라 뒤로 따라갈 구간이 없습니다."; return
        }
        var options = ObjectTracker.Options()
        options.smoothing = smoothTrackingCheckbox.state == .on
        options.reacquireFaces = reacquireFacesCheckbox.state == .on
        stopPlayback()
        endGesture()
        let cancellation = ObjectTracker.Cancellation()
        trackingCancellation = cancellation
        setExporting(true)
        progressIndicator.doubleValue = 0
        progressIndicator.isHidden = false
        cancelButton.isHidden = false
        progressLabel.stringValue = "자동 추적 중… \(items.count)개 (취소하면 여기까지만 기록)"
        let indicator = progressIndicator
        let report: @Sendable (Double) -> Void = { value in DispatchQueue.main.async { indicator.doubleValue = value } }
        let initial = Dictionary(uniqueKeysWithValues: zip(items, boxes))
        let run = trackObjects
        let refinementKinds = Dictionary(uniqueKeysWithValues: pairs.compactMap { pair -> (UUID, AutoDetector.Target)? in
            guard items.contains(pair.shape.id), let fit = pair.effect.automaticCover,
                  fit.phrases.isEmpty else { return nil }
            return (pair.shape.id, fit.kind == .face ? .faces : .text)
        })
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<RefinedTracking, Error> in
                do {
                    var backward: [ObjectTracker.Outcome]?, forward: [ObjectTracker.Outcome]?
                    if choice != .forward {
                        var back = options
                        back.direction = .backward
                        backward = try await run(url, start, 0, boxes, back, cancellation) { report(choice == .both ? $0 / 2 : $0) }
                    }
                    if choice != .backward, !cancellation.isCancelled {
                        var ahead = options
                        ahead.direction = .forward
                        forward = try await run(url, start, end, boxes, ahead, cancellation) { report(choice == .both ? 0.5 + $0 / 2 : $0) }
                    }
                    var outcomes: [UUID: ObjectTracker.Outcome] = [:]
                    for (index, id) in items.enumerated() {
                        let samples = ((backward?[index].samples ?? []) + (forward?[index].samples ?? [])).sorted { $0.time < $1.time }
                        outcomes[id] = ObjectTracker.Outcome(samples: samples,
                                                             lostTarget: (backward?[index].lostTarget ?? false) || (forward?[index].lostTarget ?? false),
                                                             cancelled: cancellation.isCancelled)
                    }
                    var evidence: [UUID: [PhraseTracker.CoverEvidence]] = [:]
                    if !cancellation.isCancelled {
                        for target in AutoDetector.Target.allCases {
                            let ids = items.filter { refinementKinds[$0] == target }
                            guard !ids.isEmpty else { continue }
                            let samples = ids.map { id -> [ObjectTracker.Sample] in
                                let list = outcomes[id]?.samples ?? []
                                return ([ObjectTracker.Sample(time: start, box: initial[id] ?? .zero)] + list)
                                    .sorted { $0.time < $1.time }
                            }
                            do {
                                let refined = try await AutoDetector.refineTracks(url: url, target: target,
                                    tracks: samples, cancellation: cancellation)
                                for (id, anchors) in zip(ids, refined) { evidence[id] = anchors }
                            } catch PageWorkspace.WorkspaceError.sourceChanged { throw PageWorkspace.WorkspaceError.sourceChanged }
                            catch { // Optional refinement must not discard an already recorded tracking path.
                                for id in ids { evidence[id] = [] }
                            }
                        }
                    }
                    if cancellation.isCancelled {
                        for id in items { outcomes[id]?.cancelled = true }
                        evidence = [:]
                    }
                    return .success(RefinedTracking(outcomes: outcomes, evidence: evidence))
                } catch { return .failure(error) }
            }.value
            let requestedRange = (choice == .forward ? start : 0)...max(choice == .backward ? start : end, start)
            self?.finishTracking(result, start: start, initialBoxes: initial, undoWithPrevious: undoWithPrevious,
                                 skipped: tooSmall, requestedRange: requestedRange)
        }
    }

    private struct RefinedTracking {
        var outcomes: [UUID: ObjectTracker.Outcome]
        var evidence: [UUID: [PhraseTracker.CoverEvidence]]
    }
    private func finishTracking(_ result: Result<RefinedTracking, Error>, start: Double, initialBoxes: [UUID: CGRect],
                                undoWithPrevious: Bool, skipped: Int = 0, requestedRange: ClosedRange<Double>? = nil) {
        defer { repairingReview = nil }
        trackingCancellation = nil
        setExporting(false)
        progressIndicator.isHidden = true
        cancelButton.isHidden = true
        progressLabel.stringValue = ""
        switch result {
        case .failure(let error):
            showError(error.localizedDescription)
        case .success(let refined):
            applyTrackingResults(refined.outcomes, start: start, initialBoxes: initialBoxes, newUndoStep: !undoWithPrevious,
                                 requestedRange: requestedRange, coverEvidence: refined.evidence)
            if skipped > 0 { workflowHint.stringValue += " 너무 작은 \(skipped)개는 건너뛰었습니다." }
        }
    }

    /// One item's tracked boxes as recorded positions (compatibility entry point). Internal for tests.
    func applyTracking(_ outcome: ObjectTracker.Outcome, itemID id: UUID, start: Double, initialBox: CGRect) {
        applyTrackingResults([id: outcome], start: start, initialBoxes: [id: initialBox])
    }

    /// Writes tracked boxes as recorded positions around `start`, replacing positions recorded in
    /// the tracked span, in one undo step. Regions take the tracked box; drawings keep their size and
    /// follow its movement. Tracking back before an item's start extends its time range.
    /// Internal for tests.
    func applyTrackingResults(_ outcomes: [UUID: ObjectTracker.Outcome], start: Double, initialBoxes: [UUID: CGRect],
                              newUndoStep: Bool = true, requestedRange: ClosedRange<Double>? = nil,
                              coverEvidence: [UUID: [PhraseTracker.CoverEvidence]] = [:]) {
        let size = canvas.bounds.size
        let repair = repairingReview
        let frameTolerance = 1 / max(1, doc.videoFPS) + 0.000_001
        let usable = outcomes.filter { !$0.value.samples.isEmpty }
        let uncertainRegions = outcomes.filter { (id, outcome) in
            (outcome.lostTarget || outcome.cancelled) && pairs.contains { $0.shape.id == id } && repair?.region != id
        }
        guard (!usable.isEmpty || !uncertainRegions.isEmpty), size.width > 0, size.height > 0 else {
            let cancelled = outcomes.values.contains { $0.cancelled }
            workflowHint.stringValue = cancelled ? "자동 추적을 취소했습니다." : "대상을 따라가지 못했습니다. 영역을 대상에 딱 맞게 잡고 다시 시도하세요."
            return
        }
        func canvasRect(_ box: CGRect) -> CGRect {
            CGRect(x: box.minX * size.width, y: box.minY * size.height, width: box.width * size.width, height: box.height * size.height)
        }
        func merged(_ frames: [RegionKeyframe], base: CGRect, anchor: CGRect, tracked: [RegionKeyframe], isRepair: Bool) -> [RegionKeyframe] {
            TrackingMerge.keyframes(frames, base: base, anchor: anchor, tracked: tracked, start: start,
                                    repairEnd: isRepair ? repair?.end : nil)
        }
        func extended(_ range: ClosedRange<Double>, from earliest: Double) -> ClosedRange<Double> {
            TrackingMerge.extended(range, from: earliest)
        }
        if newUndoStep { checkpoint() }
        var positions = 0, lost = 0, earliest = start, latest = start
        var addedReviews = 0, repaired = false
        for (id, outcome) in usable {
            let samples = outcome.samples
            positions += samples.count
            if outcome.lostTarget { lost += 1 }
            earliest = min(earliest, samples.first?.time ?? start)
            latest = max(latest, samples.last?.time ?? start)
            if let index = pairs.firstIndex(where: { $0.shape.id == id }) {
                let anchor = pairs[index].effect.automaticCover == nil
                    ? RegionEditing.displayed(pairs[index], at: start).boundingRect
                    : MotionTrack.rect(at: start, base: pairs[index].shape.boundingRect, keyframes: pairs[index].effect.keyframes)
                // Object tracking alone cannot verify changing facial pose or lettering angle.
                // Keep the stored recommendation for still-frame edits, but use the generous mask on this path.
                if let fit = pairs[index].effect.automaticCover {
                    let anchors = coverEvidence[id] ?? []
                    if anchors.isEmpty {
                        pairs[index].effect.automaticCover?.mode = .generous
                        pairs[index].effect.automaticCover?.evidenceKeyframes = []
                    }
                    else {
                        var updated = fittedCover(fit, anchors: anchors)
                        if let repair, repair.region == id {
                            updated.evidenceKeyframes += fit.evidenceKeyframes.filter { $0.time < start || $0.time > repair.end }
                            updated.evidenceKeyframes.sort { $0.time < $1.time }
                        }
                        pairs[index].effect.automaticCover = updated
                        let expected = [ObjectTracker.Sample(time: start, box: initialBoxes[id] ?? .zero)] + samples
                        pairs[index].effect.trackingReviews += refinementGaps(samples: expected, anchors: anchors,
                            start: requestedRange?.lowerBound ?? min(start, samples.first?.time ?? start),
                            end: requestedRange?.upperBound ?? max(start, samples.last?.time ?? start))
                    }
                }
                let isRepair = repair?.region == id
                let completedRepair = isRepair && !outcome.lostTarget && !outcome.cancelled &&
                    (samples.last?.time ?? start) >= (repair?.end ?? .infinity) - frameTolerance
                var tracked = samples.map { RegionKeyframe(time: $0.time, rect: canvasRect($0.box)) }
                if completedRepair, let repair, let last = tracked.last, last.time < repair.end {
                    tracked.append(.init(time: repair.end, rect: last.rect))
                }
                pairs[index].effect.keyframes = merged(pairs[index].effect.keyframes, base: pairs[index].shape.boundingRect,
                    anchor: anchor, tracked: tracked, isRepair: isRepair)
                if !isRepair { pairs[index].effect.timeRange = extended(pairs[index].effect.timeRange, from: samples.first?.time ?? start) }
                if completedRepair, let repair,
                   let reviewIndex = pairs[index].effect.trackingReviews.firstIndex(where: { $0.id == repair.review }) {
                    pairs[index].effect.trackingReviews[reviewIndex].status = .corrected
                    repaired = true
                }
            } else if let index = annotations.firstIndex(where: { $0.id == id }) {
                let anchor = annotations[index].displayed(at: start).bounds
                let origin = canvasRect(initialBoxes[id] ?? .zero)
                let tracked = samples.map { sample -> RegionKeyframe in
                    let box = canvasRect(sample.box)
                    return RegionKeyframe(time: sample.time, rect: anchor.offsetBy(dx: box.midX - origin.midX, dy: box.midY - origin.midY))
                }
                annotations[index].keyframes = merged(annotations[index].keyframes, base: annotations[index].bounds,
                    anchor: anchor, tracked: tracked, isRepair: false)
                annotations[index].timeRange = extended(annotations[index].timeRange, from: samples.first?.time ?? start)
            }
        }
        for (id, outcome) in uncertainRegions {
            guard let index = pairs.firstIndex(where: { $0.shape.id == id }) else { continue }
            let backwards = (outcome.samples.first?.time ?? start) < start
            let range = requestedRange ?? (backwards ? 0...start : start...max(start, doc.duration))
            let first = max(range.lowerBound, min(range.upperBound, outcome.samples.first?.time ?? start))
            let last = max(range.lowerBound, min(range.upperBound, outcome.samples.last?.time ?? start))
            let reason: TrackingReview.Reason = outcome.cancelled ? .cancelled : .lostTarget
            var intervals: [ClosedRange<Double>] = []
            if first - range.lowerBound > frameTolerance { intervals.append(range.lowerBound...first) }
            if range.upperBound - last > frameTolerance { intervals.append(last...range.upperBound) }
            if intervals.isEmpty { intervals.append(last...last) }
            for interval in intervals {
                guard !pairs[index].effect.trackingReviews.contains(where: {
                    $0.status == .needsReview && $0.reason == reason && $0.start == interval.lowerBound && $0.end == interval.upperBound
                }), pairs[index].effect.trackingReviews.count < 10_000 else { continue }
                pairs[index].effect.trackingReviews.append(.init(start: interval.lowerBound, end: interval.upperBound, reason: reason))
                addedReviews += 1
            }
        }
        var note = usable.count > 1
            ? "자동 추적: \(usable.count)개 항목, \(positions)개 위치를 \(format(earliest))~\(format(latest)) 구간에 기록했습니다."
            : "자동 추적: \(positions)개 위치를 \(format(earliest))~\(format(latest)) 구간에 기록했습니다."
        if lost > 0 { note += usable.count > 1 ? " \(lost)개는 대상이 가려지거나 사라져 중간에 멈췄습니다." : " 대상이 가려지거나 사라져 거기서 멈췄습니다." }
        if outcomes.values.contains(where: { $0.cancelled }) { note += " (취소한 곳까지)" }
        if addedReviews > 0 { note += " 확인할 구간 \(addedReviews)개를 기록했습니다." }
        if repair != nil { note += repaired ? " 선택한 구간의 보정을 완료했습니다." : " 끝까지 따라가지 못해 확인할 구간을 유지했습니다." }
        workflowHint.stringValue = note + " ⌘Z로 되돌립니다."
        refreshAfterEdit()
    }

    func timing(of id: UUID) -> ClosedRange<Double>? {
        if let pair = pairs.first(where: { $0.shape.id == id }) { return pair.effect.timeRange }
        return annotations.first(where: { $0.id == id })?.timeRange
    }
}
