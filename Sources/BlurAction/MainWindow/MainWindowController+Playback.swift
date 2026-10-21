import AppKit
import AVKit
import AVFoundation
import UniformTypeIdentifiers
import os
import Darwin

// MainWindowController: 재생기와 재생·탐색 동작.

extension MainWindowController {
    func configurePlayer() {
        player = AVPlayer()
        mainContainer.playerLayer.player = player
        mainContainer.playPauseButton.target = self
        mainContainer.playPauseButton.action = #selector(togglePlay)
        mainContainer.slider.target = self
        mainContainer.slider.action = #selector(sliderMoved(_:))
        mainContainer.playPauseButton.isEnabled = false
        mainContainer.slider.trackingBegan = { [weak self] in
            guard let self, self.doc.hasVideo, !self.isExporting else { return }
            self.seekCoordinator.beginScrubbing()
            self.stopPlayback()
        }
        mainContainer.slider.trackingEnded = { [weak self] in
            guard let self else { return }
            // Commit the mouse-up value, even if no final continuous action was delivered.
            self.seek(to: self.mainContainer.slider.doubleValue)
            self.seekCoordinator.endScrubbing()
        }
        seekCoordinator.didSettle = { [weak self] finished in
            guard let self, self.doc.hasVideo else { return }
            if !self.seekCoordinator.isScrubbing {
                self.updatePlaybackTime(self.player.currentTime().seconds)
            } else if finished {
                self.liveBlur.refresh()
                self.canvas.refreshOverlay()
            }
            if finished, self.playAfterSeek, !self.seekCoordinator.isScrubbing {
                self.startPlayback()
            } else if !finished {
                self.stopPlayback()
            }
            if finished, !self.seekCoordinator.isScrubbing, self.player.rate == 0 {
                self.liveBlur.requestStillFrame(at: max(0, self.player.currentTime().seconds))
            }
        }

    }

    func observePlaybackTime(for item: AVPlayerItem) {
        playerItemStatusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async { [weak self, weak item] in
                guard let self, let item, self.player.currentItem === item else { return }
                if item.status == .failed {
                    self.seekCoordinator.reset(duration: self.doc.duration)
                    self.stopPlayback()
                    self.mainContainer.slider.isEnabled = false
                    self.mainContainer.playPauseButton.isEnabled = false
                    self.updatePlaybackTime(self.player.currentTime().seconds)
                } else {
                    self.seekCoordinator.setReady(item.status == .readyToPlay)
                    if item.status == .readyToPlay, self.player.rate == 0 {
                        self.liveBlur.requestStillFrame(at: max(0, self.player.currentTime().seconds))
                    }
                }
            }
        }
        let interval = CMTime(seconds: 1.0 / 30, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self, let item, self.player.currentItem === item, self.doc.hasVideo,
                      !self.seekCoordinator.suppressesTimeObserver else { return }
                // Read the current clock, not a callback time queued before the latest seek.
                self.updatePlaybackTime(self.player.currentTime().seconds)
            }
        }
    }

    func resetPlaybackTime(duration: Double) {
        let duration = duration.isFinite ? max(0, duration) : 0
        seekCoordinator.reset(duration: duration)
        mainContainer.slider.minValue = 0
        mainContainer.slider.maxValue = duration > 0 ? duration : 1
        mainContainer.slider.doubleValue = 0
        mainContainer.timeLabel.stringValue = "00:00.00 / \(format(duration))"
        mainContainer.slider.setAccessibilityValueDescription(mainContainer.timeLabel.stringValue)
        canvas.currentVideoTime = 0
        liveBlur.currentTime = 0
        lastListReloadQuantized = -1
        lastTimedLayerActivity = []
    }

    private func updatePlaybackTime(_ seconds: Double, refreshPreview: Bool = true) {
        guard seconds.isFinite, doc.duration.isFinite else { return }
        let time = min(doc.duration, max(0, seconds))
        if !seekCoordinator.isScrubbing { mainContainer.slider.doubleValue = time }
        mainContainer.timeLabel.stringValue = "\(format(time)) / \(format(doc.duration))"
        mainContainer.slider.setAccessibilityValueDescription(mainContainer.timeLabel.stringValue)
        if refreshPreview {
            liveBlur.currentTime = time
            liveBlur.refresh()
        }
        // Transport slider/label keep the continuous clock. Editing follows the
        // resulting displayed frame, which can precede an in-between-frame seek.
        synchronizeCanvasTime(fallback: time)
    }

    func synchronizeCanvasTime(fallback: Double) {
        guard fallback.isFinite, doc.duration.isFinite else { return }
        let time = presentedEditTime ?? min(doc.duration, max(0, fallback))
        canvas.currentVideoTime = time
        canvas.recordingKeyframes = recordingKeyframes && trackMotion
        canvas.refreshOverlay()
        if hasSelection, ![positionX, positionY, positionWidth, positionHeight].contains(where: { $0.currentEditor() != nil }) {
            refreshPositionFields()
        }
        let bucket = time * 10
        let quantized = bucket.isFinite && bucket < Double(Int.max) ? Int(bucket) : Int.max
        let activity = pairs.map { $0.effect.isActive(at: editTime) }
            + annotations.map { $0.isVisible(at: editTime) }
        // Keep the existing 10Hz list cadence, but do not miss interval boundaries
        // merely because the presented PTS and transport fall in the same bucket.
        if quantized != lastListReloadQuantized || activity != lastTimedLayerActivity {
            lastListReloadQuantized = quantized
            lastTimedLayerActivity = activity
            refreshRegionList()
        }
    }

    @objc func togglePlay() {
        guard doc.hasVideo, !isExporting else { return }
        if player.rate > 0 || recordingKeyframes || playAfterSeek { stopPlayback() }
        else {
            guard !seekCoordinator.isScrubbing else { return }
            playAfterSeek = true
            if canvas.currentVideoTime >= doc.duration - 0.01 { seek(to: 0) }
            if !seekCoordinator.suppressesTimeObserver { startPlayback() }
        }
    }

    private func startPlayback() {
        playAfterSeek = false
        recordingKeyframes = true
        canvas.recordingKeyframes = trackMotion
        player.play()
        mainContainer.playPauseButton.title = "⏸"
    }

    func stopPlayback() {
        playAfterSeek = false
        player.pause()
        recordingKeyframes = false
        canvas.recordingKeyframes = false
        mainContainer.playPauseButton.title = "▶"
    }

    func seek(to seconds: Double) {
        guard doc.hasVideo, !isExporting, seconds.isFinite, doc.duration > 0 else { return }
        let t = min(doc.duration, max(0, seconds))
        updatePlaybackTime(t, refreshPreview: false)
        seekCoordinator.request(t)
    }

    @objc private func sliderMoved(_ sender: NSSlider) { stopPlayback(); seek(to: sender.doubleValue) }
    @objc func stepForward() { stopPlayback(); seek(to: canvas.currentVideoTime + 1) }
    @objc func stepBackward() { stopPlayback(); seek(to: canvas.currentVideoTime - 1) }
    @objc func previousFrame() { stepFrame(-1) }
    @objc func nextFrame() { stepFrame(1) }

    private func stepFrame(_ direction: Double) {
        guard doc.hasVideo, doc.videoFPS.isFinite, doc.videoFPS > 0 else { return }
        stopPlayback()
        seek(to: canvas.currentVideoTime + direction / doc.videoFPS)
    }

    @objc func recordCurrentPosition() {
        guard doc.hasVideo, !isExporting, let rect = selectedDisplayedRect,
              let time = playheadTime, time < doc.duration else { return }
        stopPlayback()
        endGesture()
        let frame = RegionKeyframe(time: time, rect: rect)
        if let id = selectedID, let index = pairs.firstIndex(where: { $0.shape.id == id }) {
            checkpoint()
            pairs[index].effect.keyframes = RegionEditing.inserting(frame, into: pairs[index].effect.keyframes)
        } else if let id = selectedDrawingID, let index = annotations.firstIndex(where: { $0.id == id }) {
            checkpoint()
            annotations[index].keyframes = MotionTrack.inserting(frame, into: annotations[index].keyframes)
        } else { return }
        refreshAfterEdit()
    }

    @objc func applyPrecisePosition() {
        guard !isExporting, hasSelection,
              doc.appliedVideoSize.width > 0, doc.appliedVideoSize.height > 0,
              canvas.bounds.width > 0, canvas.bounds.height > 0 else { return }
        let fields = [positionX, positionY, positionWidth, positionHeight]
        let numbers = fields.compactMap { Double($0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let source = doc.appliedVideoSize
        guard numbers.count == 4, numbers.allSatisfy(\.isFinite),
              numbers[0] >= 0, numbers[1] >= 0, numbers[2] > 0, numbers[3] > 0,
              numbers[0] + numbers[2] <= source.width + 0.01,
              numbers[1] + numbers[3] <= source.height + 0.01 else {
            NSSound.beep()
            workflowHint.stringValue = "좌표·크기를 원본 크기 안의 숫자로 입력하세요."
            return
        }
        let sx = canvas.bounds.width / source.width
        let sy = canvas.bounds.height / source.height
        let rect = CGRect(x: numbers[0] * sx,
                          y: canvas.bounds.height - (numbers[1] + numbers[3]) * sy,
                          width: numbers[2] * sx, height: numbers[3] * sy)
        endGesture()
        if doc.hasVideo {
            guard let time = playheadTime, time < doc.duration else { return }
            stopPlayback()
        }
        // Same rules as dragging: with motion recording on, video positions are recorded at this time.
        if let id = selectedID, let index = pairs.firstIndex(where: { $0.shape.id == id }) {
            let shapes = pairs.enumerated().map { offset, pair in
                offset == index ? RegionEditing.displayed(pair, at: editTime).replacing(rect: rect) : RegionEditing.displayed(pair, at: editTime)
            }
            let result = preservingReviewExterior(RegionEditing.updating(shapes, in: pairs, time: editTime, recording: motionRecording), before: pairs)
            guard !RegionEditing.equal(result, pairs) else { return }
            checkpoint()
            pairs = result
        } else if let id = selectedDrawingID, let index = annotations.firstIndex(where: { $0.id == id }) {
            let edited = annotations[index].displayed(at: editTime).replacingBounds(rect)
            let updated = annotations[index].applyingEdit(edited, time: editTime, recording: motionRecording)
            guard updated != annotations[index] else { return }
            checkpoint()
            annotations[index] = updated
        }
        workflowHint.stringValue = "정밀 좌표가 적용됐습니다. ⌘Z로 되돌릴 수 있습니다."
        refreshAfterEdit()
    }
}
