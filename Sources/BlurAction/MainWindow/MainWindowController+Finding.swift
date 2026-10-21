import AppKit
import AVKit
import AVFoundation
import UniformTypeIdentifiers
import os
import Darwin

// MainWindowController: 얼굴·글자·문구 자동 찾기.

extension MainWindowController {
    // MARK: - Automatic finding (faces, text)

    @objc func findFacesTapped() { findAndCover(.faces) }
    @objc func findTextTapped() { findAndCover(.text) }

    /// Finds faces or text in the image page or the video frame on screen and covers each with a
    /// new area (current cover style), skipping places already covered. One undo step; on video the
    /// new areas can be tracked both ways right away. Internal for tests.
    func findAndCover(_ target: AutoDetector.Target, completion: (() -> Void)? = nil) {
        guard !isExporting, doc.mediaKind != .none, canvas.bounds.width > 0, canvas.bounds.height > 0 else { NSSound.beep(); return }
        let detect = autoDetect
        let detailed = autoDetectDetailed
        let time = doc.hasVideo ? playheadTime : nil
        let url = doc.url
        let still = doc.hasVideo ? nil : doc.currentCGImage
        stopPlayback()
        endGesture()
        // Editing, page changes, seeking and opening files wait until the result is placed, and the
        // result is only placed where it was looked for.
        let context = FindContext(url: url, page: pageWorkspace?.currentIndex, time: time)
        setExporting(true)
        workflowHint.stringValue = "\(target.label) 찾는 중…"
        progressIndicator.isIndeterminate = true
        progressIndicator.isHidden = false
        progressIndicator.startAnimation(nil)
        cancelButton.isHidden = false
        progressLabel.stringValue = "\(target.label) 찾는 중… (취소할 수 있음)"
        let task = Task.detached(priority: .userInitiated) { () -> Result<[AutoDetector.Detection], Error> in
            do {
                let image: CIImage
                if let still { image = CIImage(cgImage: still) }
                else if let url, let time { image = try await AutoDetector.frame(of: url, at: time) }
                else { throw AutoDetector.DetectError.frameUnavailable }
                try Task.checkCancellation()
                let found = try detailed?(target, image) ?? detect(target, image).map {
                    AutoDetector.Detection(generousBox: $0, target: target, evidencePoints: [], reliable: false)
                }
                try Task.checkCancellation()
                return .success(found)
            } catch { return .failure(error) }
        }
        findTask = task
        Task { [weak self] in
            let result = await task.value
            guard let self else { completion?(); return }
            self.findTask = nil
            self.progressIndicator.stopAnimation(nil)
            self.progressIndicator.isIndeterminate = false
            self.progressIndicator.isHidden = true
            self.cancelButton.isHidden = true
            self.progressLabel.stringValue = ""
            self.setExporting(false)
            if task.isCancelled {
                self.workflowHint.stringValue = "\(target.label) 찾기를 취소했습니다."
                completion?()
                return
            }
            guard context == FindContext(url: self.doc.url, page: self.pageWorkspace?.currentIndex,
                                         time: self.doc.hasVideo ? self.playheadTime : nil) else {
                self.workflowHint.stringValue = "찾는 동안 화면이 바뀌어 결과를 넣지 않았습니다. 다시 찾아 주세요."
                completion?()
                return
            }
            self.coverFound(result, target: target, time: time)
            completion?()
        }
    }

    struct FindContext: Equatable {
        let url: URL?
        let page: Int?
        let time: Double?
        static func == (a: FindContext, b: FindContext) -> Bool {
            a.url == b.url && a.page == b.page && (a.time == nil) == (b.time == nil)
                && abs((a.time ?? 0) - (b.time ?? 0)) < MotionTrack.sameTime
        }
    }

    private func coverFound(_ result: Result<[AutoDetector.Detection], Error>, target: AutoDetector.Target, time: Double?) {
        let detections: [AutoDetector.Detection]
        switch result {
        case .failure(let error): workflowHint.stringValue = error.localizedDescription; return
        case .success(let found): detections = found
        }
        let boxes = detections.map(\.generousBox)
        let size = canvas.bounds.size
        guard !isExporting, size.width > 0, size.height > 0 else { return }
        // Areas with eraser marks may have holes, so they never count as covering.
        let covering = pairs.filter { $0.effect.isActive(at: time) && $0.effect.erasures.isEmpty }
            .map { RegionEditing.displayed($0, at: time) }
        /// Points spread over the cover this find would make (an oval for faces, the box for text);
        /// the place is skipped only when existing areas' actual shapes hold every one (a sliver left showing gets covered).
        func alreadyCovered(_ detection: AutoDetector.Detection) -> Bool {
            guard !covering.isEmpty else { return false }
            let box = detection.generousBox
            let rect = CGRect(x: box.minX * size.width, y: box.minY * size.height, width: box.width * size.width, height: box.height * size.height)
            let base: RegionShape = target == .faces ? .ellipse(id: UUID(), origin: rect.origin, size: rect.size)
                : .rectangle(id: UUID(), origin: rect.origin, size: rect.size)
            let proposed = detection.reliable ? automaticCover(kind: target == .faces ? .face : .text,
                points: detection.evidencePoints, box: box)?.shape(base: base, rect: rect, time: nil, reviews: []) : nil
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
        let fresh = detections.filter { !alreadyCovered($0) }
        guard !fresh.isEmpty else {
            workflowHint.stringValue = boxes.isEmpty ? "\(target.label)을 찾지 못했습니다." : "찾은 \(target.label)은 이미 모두 가려져 있습니다."
            return
        }
        let existing = pairs.filter { $0.effect.name?.hasPrefix(target.label + " ") == true }.count
        var created: [UUID] = []
        checkpoint()
        for (offset, detection) in fresh.enumerated() {
            let box = detection.generousBox
            let rect = CGRect(x: box.minX * size.width, y: box.minY * size.height, width: box.width * size.width, height: box.height * size.height)
            let id = UUID()
            let shape: RegionShape = target == .faces ? .ellipse(id: id, origin: rect.origin, size: rect.size)
                                                       : .rectangle(id: id, origin: rect.origin, size: rect.size)
            var effect = RegionEffect.created(at: time, videoDuration: doc.hasVideo ? doc.duration : nil)
            applyDefaultCover(to: &effect)
            effect.name = "\(target.label) \(existing + offset + 1)"
            if detection.reliable {
                effect.automaticCover = automaticCover(kind: target == .faces ? .face : .text,
                    points: detection.evidencePoints, box: box)
                if effect.automaticCover != nil { effect.featherRadius = min(effect.featherRadius, 2) }
            }
            pairs.append((shape, effect))
            created.append(id)
        }
        canvas.setRegionsFromExternal(pairs.map(\.shape))
        lastFound = (created, doc.url, pageWorkspace?.currentIndex)
        if let first = created.first { canvas.selectRegion(id: first) }
        multiSelection = created.count > 1 ? created : []
        workflowHint.stringValue = "\(target.label) \(created.count)개를 찾아 가렸습니다. 필요 없는 것은 지우세요. ⌘Z로 한 번에 되돌립니다."
        refreshAfterEdit()
        if doc.hasVideo, trackAfterFindCheckbox.state == .on {
            // Finding and its tracking undo together.
            startTracking(ids: created, choice: .both, undoWithPrevious: true)
        }
    }

    @objc func findPhrasesTapped() { findPhrases() }

    /// Covers each place the typed phrases are read, for as long as they stay on screen. Video is sampled
    /// once a second; a still image is read once. Internal for tests.
    func findPhrases(_ text: String? = nil, completion: (() -> Void)? = nil) {
        guard !isExporting, doc.mediaKind != .none, canvas.bounds.width > 0, canvas.bounds.height > 0 else { NSSound.beep(); completion?(); return }
        let parsed = PhraseCover.parse(text ?? phraseField.stringValue)
        guard !parsed.phrases.isEmpty else {
            workflowHint.stringValue = "가릴 문구를 두 글자 이상 입력하세요. 여러 개는 쉼표로 나눕니다."
            completion?()
            return
        }
        if doc.hasVideo {
            findAndTrackPhrases(parsed.phrases, completion: completion)
            return
        }
        let phrases = parsed.phrases, tooShort = parsed.tooShort
        let recognize = recognizeLines
        let url = doc.url
        let still = doc.hasVideo ? nil : doc.currentCGImage
        let isVideo = doc.hasVideo
        let duration = isVideo ? doc.duration : 0
        let sampling = PhraseCover.sampleTimes(duration: duration, step: 1)
        stopPlayback()
        endGesture()
        let context = FindContext(url: url, page: pageWorkspace?.currentIndex, time: nil)
        setExporting(true)
        workflowHint.stringValue = "문구 찾는 중…"
        progressIndicator.isIndeterminate = false
        progressIndicator.doubleValue = 0
        progressIndicator.isHidden = false
        cancelButton.isHidden = false
        progressLabel.stringValue = "문구 찾는 중… (취소할 수 있음)"
        let report: @MainActor (Int, Int) -> Void = { [weak self] done, total in
            guard let self else { return }
            self.progressIndicator.doubleValue = Double(done) / Double(max(1, total)) * 100
            self.progressLabel.stringValue = "문구 찾는 중 \(done)/\(total) (취소할 수 있음)"
        }
        let task = Task.detached(priority: .userInitiated) { () -> Result<[PhraseCover.Span], Error> in
            do {
                var samples: [(time: Double, hits: [CGRect])] = []
                for (index, time) in sampling.times.enumerated() {
                    try Task.checkCancellation()
                    let image: CIImage
                    if let still { image = CIImage(cgImage: still) }
                    else if let url { image = try await AutoDetector.frame(of: url, at: time) }
                    else { throw AutoDetector.DetectError.frameUnavailable }
                    let lines = try recognize(image)
                    let hits = lines.filter { PhraseCover.matches($0.text, phrases: phrases) }.map { PhraseCover.coverBox($0.box) }
                    samples.append((time, hits))
                    await report(index + 1, sampling.times.count)
                }
                try Task.checkCancellation()
                // A still image has one sample: each hit is simply a place to cover.
                if let still {
                    let lines = try recognize(CIImage(cgImage: still))
                    return .success(lines.filter { PhraseCover.matches($0.text, phrases: phrases) }.map {
                        PhraseCover.Span(box: PhraseCover.coverBox($0.box), start: 0, end: 0,
                                         evidencePoints: AutoDetector.phraseEvidence(line: $0, phrases: phrases))
                    })
                }
                return .success(PhraseCover.spans(samples: samples, step: sampling.step, duration: duration))
            } catch { return .failure(error) }
        }
        phraseTask = task
        Task { [weak self] in
            let result = await task.value
            guard let self else { completion?(); return }
            self.phraseTask = nil
            self.progressIndicator.stopAnimation(nil)
            self.progressIndicator.isIndeterminate = false
            self.progressIndicator.isHidden = true
            self.cancelButton.isHidden = true
            self.progressLabel.stringValue = ""
            self.setExporting(false)
            if task.isCancelled {
                self.workflowHint.stringValue = "문구 찾기를 취소했습니다."
                completion?()
                return
            }
            guard context == FindContext(url: self.doc.url, page: self.pageWorkspace?.currentIndex, time: nil) else {
                self.workflowHint.stringValue = "찾는 동안 화면이 바뀌어 결과를 넣지 않았습니다. 다시 찾아 주세요."
                completion?()
                return
            }
            self.placePhraseCovers(result, isVideo: isVideo, tooShort: tooShort)
            completion?()
        }
    }

    private func placePhraseCovers(_ result: Result<[PhraseCover.Span], Error>, isVideo: Bool, tooShort: Int) {
        let spans: [PhraseCover.Span]
        switch result {
        case .failure(let error): workflowHint.stringValue = error.localizedDescription; return
        case .success(let found): spans = found
        }
        let size = canvas.bounds.size
        guard !isExporting, size.width > 0, size.height > 0 else { return }
        // A span must have a real time range on video; anything empty is dropped rather than made whole-video.
        let usable = spans.filter { !isVideo || $0.end > $0.start }
        guard !usable.isEmpty else {
            workflowHint.stringValue = "문구를 찾지 못했습니다. 글자가 작거나 흐리면 화면을 확대해 다시 시도하세요."
            return
        }
        let existing = pairs.filter { $0.effect.name?.hasPrefix("문구 ") == true }.count
        var created: [UUID] = []
        checkpoint()
        for (offset, span) in usable.enumerated() {
            let rect = CGRect(x: span.box.minX * size.width, y: span.box.minY * size.height,
                              width: span.box.width * size.width, height: span.box.height * size.height)
            let id = UUID()
            var effect = RegionEffect.alwaysOn()
            if isVideo { effect.timeRange = span.start...span.end }
            applyDefaultCover(to: &effect)
            effect.name = "문구 \(existing + offset + 1)"
            if let points = span.evidencePoints {
                effect.automaticCover = automaticCover(kind: .text, points: points, box: span.box)
                if effect.automaticCover != nil { effect.featherRadius = min(effect.featherRadius, 2) }
            }
            pairs.append((.rectangle(id: id, origin: rect.origin, size: rect.size), effect))
            created.append(id)
        }
        canvas.setRegionsFromExternal(pairs.map(\.shape))
        lastFound = (created, doc.url, pageWorkspace?.currentIndex)
        if let first = created.first { canvas.selectRegion(id: first) }
        multiSelection = created.count > 1 ? created : []
        var message = "문구 \(created.count)곳을 찾아 가렸습니다. 필요 없는 것은 지우세요. ⌘Z로 한 번에 되돌립니다."
        if tooShort > 0 { message += " 두 글자보다 짧은 \(tooShort)개는 건너뛰었습니다." }
        workflowHint.stringValue = message
        refreshAfterEdit()
    }

    @objc func pickPersonTapped() { startPersonPick() }

    /// Reverse covers are video-only, so the person pick is too. The next canvas click picks the person.
    private func startPersonPick() {
        guard doc.hasVideo, !isExporting else { NSSound.beep(); return }
        workflowHint.stringValue = "남길 사람을 캔버스에서 클릭하세요. Esc로 취소합니다."
        window?.makeFirstResponder(canvas)
        canvas.colorPickHandler = { [weak self] point in self?.keepPerson(atCanvasPoint: point) }
    }

    /// Keeps the person under a canvas point on the current frame and covers everything else. Internal for tests.
    func keepPerson(atCanvasPoint point: CGPoint) {
        guard !isExporting, doc.hasVideo, let url = doc.url else { return }
        let size = canvas.displayRect.size
        guard size.width > 0, size.height > 0 else { return }
        let normal = CGPoint(x: point.x / size.width, y: point.y / size.height)
        guard (0...1).contains(normal.x), (0...1).contains(normal.y) else {
            workflowHint.stringValue = "사람 위를 클릭하세요."
            return
        }
        guard let time = playheadTime else { return }
        let find = findPersonBox
        stopPlayback()
        endGesture()
        let context = FindContext(url: url, page: pageWorkspace?.currentIndex, time: time)
        setExporting(true)
        workflowHint.stringValue = "사람 찾는 중…"
        let task = Task.detached(priority: .userInitiated) { () -> Result<CGRect?, Error> in
            do {
                let image = try await AutoDetector.frame(of: url, at: time)
                try Task.checkCancellation()
                return .success(try find(image, normal))
            } catch { return .failure(error) }
        }
        Task { [weak self] in
            let result = await task.value
            guard let self else { return }
            self.setExporting(false)
            guard context == FindContext(url: self.doc.url, page: self.pageWorkspace?.currentIndex, time: self.playheadTime) else {
                self.workflowHint.stringValue = "찾는 동안 화면이 바뀌어 결과를 넣지 않았습니다. 다시 시도해 주세요."
                return
            }
            switch result {
            case .failure(let error): self.workflowHint.stringValue = error.localizedDescription
            case .success(nil): self.workflowHint.stringValue = "그 자리에서 사람을 찾지 못했습니다. 사람의 몸 위를 클릭해 보세요."
            case .success(let box?): self.placeKeptPerson(box, time: time)
            }
        }
    }

    private func placeKeptPerson(_ box: CGRect, time: Double) {
        let size = canvas.bounds.size
        guard !isExporting, size.width > 0, size.height > 0 else { return }
        // A little room around the body so hair and hands stay inside the kept area.
        let padded = box.insetBy(dx: -box.width * 0.04, dy: -box.height * 0.04).clampedToUnit
        let rect = CGRect(x: padded.minX * size.width, y: padded.minY * size.height,
                          width: padded.width * size.width, height: padded.height * size.height)
        let id = UUID()
        var effect = RegionEffect.created(at: time, videoDuration: doc.duration)
        applyDefaultCover(to: &effect)
        effect.inverted = true
        effect.name = "사람 \(pairs.filter { $0.effect.name?.hasPrefix("사람 ") == true }.count + 1)"
        checkpoint()
        pairs.append((.rectangle(id: id, origin: rect.origin, size: rect.size), effect))
        canvas.setRegionsFromExternal(pairs.map(\.shape))
        lastFound = ([id], doc.url, pageWorkspace?.currentIndex)
        canvas.selectRegion(id: id)
        workflowHint.stringValue = "이 사람만 남기고 나머지를 가렸습니다. 사람이 움직이면 자동 추적으로 따라가게 하세요. ⌘Z로 되돌립니다."
        refreshAfterEdit()
        if trackAfterFindCheckbox.state == .on {
            startTracking(ids: [id], choice: .both, undoWithPrevious: true)
        }
    }

    /// Areas from the latest find that still exist on the page it ran on, in creation order.
    var foundIDsStillHere: [UUID] {
        guard lastFound.url == doc.url, lastFound.page == pageWorkspace?.currentIndex else { return [] }
        let present = Set(pairs.map(\.shape.id))
        return lastFound.ids.filter(present.contains)
    }

    /// Picks the latest find's areas again, together. Internal for tests.
    @objc func selectFoundTapped() {
        let ids = foundIDsStillHere
        guard !isExporting, let first = ids.first else { NSSound.beep(); return }
        endGesture()
        selectItem(first)
        multiSelection = ids.count > 1 ? ids : []
        workflowHint.stringValue = "찾은 영역 \(ids.count)개를 골랐습니다. ⌘G 그룹, Delete 삭제, 자동 추적으로 함께 다룹니다."
        canvas.refreshOverlay()
        refreshRegionList()
        refreshSelectedEditor()
    }

    /// Removes the latest find's areas in one undo step; locked ones stay. Internal for tests.
    @objc func deleteFoundTapped() {
        let ids = foundIDsStillHere.filter { !layerState($0).locked }
        guard !isExporting, !ids.isEmpty else { NSSound.beep(); return }
        endGesture()
        multiSelection.removeAll()
        eraseItems(regions: Set(ids), drawings: [])
        workflowHint.stringValue = "찾은 영역 \(ids.count)개를 지웠습니다. ⌘Z로 되돌립니다."
    }
}
