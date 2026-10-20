import AppKit
import Foundation
import Testing
@testable import BlurAction

@Suite(.serialized)
@MainActor
struct MacCoverWorkflowTests {
    /// Keep generated fixtures available for inspection; close only the test-owned window/player.
    private func close(_ session: EditorSession) {
        session.container.playerLayer.player?.pause()
        session.controller.close()
    }

    @Test func textAndEmojiAttachToExistingCoverWithUndoLockAndSourcePreservation() async throws {
        let session = try await ImageSession.open()
        defer { close(session) }
        let source = session.directory.appendingPathComponent("tools.png")
        let original = try Data(contentsOf: source)
        let controller = session.controller
        controller.perform(NSSelectorFromString("addRegionTapped"))
        let shape = try #require(session.canvas.regionsBinding?().first)
        #expect(controller.setCoverDecoration(shape.id, text: "학생 A 👩🏽‍🏫", scale: 0.7))
        #expect(session.canvas.effectForID?(shape.id)?.decoration?.text == "학생 A 👩🏽‍🏫")
        #expect(session.canvas.regionsBinding?().first == shape, "Decoration belongs to the cover without changing its geometry")
        controller.perform(NSSelectorFromString("undoTapped"))
        #expect(session.canvas.effectForID?(shape.id)?.decoration == nil)
        #expect(session.canvas.regionsBinding?().first == shape)
        #expect(controller.setCoverDecoration(shape.id, text: "비공개 🙂"))
        controller.setLayerLocked(shape.id, true)
        #expect(!controller.setCoverDecoration(shape.id, text: "변경 금지"))
        #expect(session.canvas.effectForID?(shape.id)?.decoration?.text == "비공개 🙂")
        let saved = try ProjectFile.decode(controller.projectData())
        #expect(saved.regions.first?.effect.decoration?.text == "비공개 🙂")
        #expect(saved.regions.first?.effect.locked == true)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func reviewSelectionHoldAndUndoPreserveMotionOutsideTheInterval() async throws {
        let session = try await VideoSession.open()
        defer { close(session) }
        let source = session.directory.appendingPathComponent("motion.mp4")
        let beforeSource = try VideoProjectSourceBinding.Source.capture(source)
        let controller = session.controller
        let samples = [0.0, 0.9995, 1, 2, 3, 4].map {
            ObjectTracker.Sample(time: $0, box: CGRect(x: $0 == 0.9995 ? 0.41 : 0.05 + $0 * 0.1, y: 0.3, width: 0.2, height: 0.2))
        }
        let track = PhraseTracker.Track(phrase: "학생", samples: samples, start: 0, end: 4)
        let result = PhraseTracker.Outcome(tracks: [track], reviews: [.init(trackID: track.id, start: 1, end: 2.5, reason: .trackingLost)],
                                           cancelled: false, recognitionStep: 1)
        try controller.applyPhraseTracking(result)
        let shape = try #require(session.canvas.regionsBinding?().first)
        let before = try #require(session.canvas.effectForID?(shape.id))
        let issue = try #require(controller.pendingTrackingReviews.first)
        #expect(issue.regionID == shape.id && issue.review.reason == .lostTarget)
        #expect(controller.selectTrackingReview(regionID: shape.id, reviewID: issue.review.id))
        let taskPanel = try #require(session.descendants.compactMap { $0 as? NSSegmentedControl }
            .first { $0.identifier?.rawValue == "taskPanelSelector" })
        #expect(taskPanel.selectedSegment == 2)
        try await waitUntil { abs(session.canvas.currentVideoTime - 1) < 0.01 }
        let atStart = RegionEditing.displayed((shape, before), at: 1).boundingRect
        try session.drag(from: CGPoint(x: atStart.midX, y: atStart.midY), to: CGPoint(x: atStart.midX + 35, y: atStart.midY + 12))
        #expect(taskPanel.selectedSegment == 2, "Moving the review target keeps its repair actions visible")
        let afterDrag = try #require(session.canvas.effectForID?(shape.id))
        #expect(RegionEditing.displayed((shape, afterDrag), at: 1).boundingRect.minX > atStart.minX + 20)
        #expect(afterDrag.keyframes.first { $0.time == 0.9995 } == before.keyframes.first { $0.time == 0.9995 },
                "A nearby outside key survives real canvas dragging despite the normal merge tolerance")
        let holdButton = try #require(session.descendants.compactMap { $0 as? NSButton }
            .first { $0.title == "현재 위치로 구간 보정" })
        #expect(!holdButton.isHiddenOrHasHiddenAncestor && holdButton.isEnabled)
        click(holdButton)
        let after = try #require(session.canvas.effectForID?(shape.id))
        #expect(controller.pendingTrackingReviews.isEmpty)
        #expect(after.trackingReviews.first?.status == .corrected)
        let held = RegionEditing.displayed((shape, after), at: 1.5).boundingRect
        #expect(held == RegionEditing.displayed((shape, after), at: 2.25).boundingRect)
        #expect(after.keyframes.first { $0.time == 0.9995 } == before.keyframes.first { $0.time == 0.9995 })
        for time in [0.5, 0.9994, 0.9997, 3.5] {
            let a = RegionEditing.displayed((shape, before), at: time).boundingRect
            let b = RegionEditing.displayed((shape, after), at: time).boundingRect
            #expect(abs(a.minX - b.minX) < 0.01 && abs(a.width - b.width) < 0.01,
                    "The correction changes only the selected interval")
        }
        controller.perform(NSSelectorFromString("undoTapped"))
        #expect(session.canvas.effectForID?(shape.id) == afterDrag, "One undo reverses the hold without losing the user's drag")
        #expect(controller.pendingTrackingReviews.count == 1)
        controller.perform(NSSelectorFromString("undoTapped"))
        #expect(session.canvas.effectForID?(shape.id) == before, "A second undo reverses the correction drag")
        #expect(try VideoProjectSourceBinding.Source.capture(source) == beforeSource)
    }

    @Test func ordinaryTrackingLossWithNoSamplesPersistsAReviewAndIsUndoable() async throws {
        let session = try await VideoSession.open()
        defer { close(session) }
        let controller = session.controller
        controller.perform(NSSelectorFromString("addRegionTapped"))
        let shape = try #require(session.canvas.regionsBinding?().first)
        let before = try #require(session.canvas.effectForID?(shape.id))
        let box = CGRect(x: 0.2, y: 0.3, width: 0.2, height: 0.2)
        controller.applyTracking(.init(samples: [], lostTarget: true, cancelled: false), itemID: shape.id, start: 1, initialBox: box)
        let issue = try #require(controller.pendingTrackingReviews.first)
        #expect(issue.regionID == shape.id && issue.review.reason == .lostTarget)
        #expect(issue.review.start == 1 && issue.review.end == 6)
        #expect(session.canvas.effectForID?(shape.id)?.keyframes == before.keyframes)
        let saved = try VideoProjectFile.decode(controller.projectData(producerVersion: "test.empty-loss"))
        #expect(saved.payload.regions.first?.effect.trackingReviews.first == issue.review)
        controller.perform(NSSelectorFromString("undoTapped"))
        #expect(session.canvas.effectForID?(shape.id) == before)
        #expect(controller.pendingTrackingReviews.isEmpty)
    }

    @Test func retryKeepsFailedReviewThenResolvesOnlyAfterReachingItsEnd() async throws {
        let session = try await VideoSession.open()
        defer { close(session) }
        let controller = session.controller
        let samples = [0.0, 0.9995, 1, 2, 3, 4].map {
            ObjectTracker.Sample(time: $0, box: CGRect(x: $0 == 0.9995 ? 0.42 : 0.1 + $0 * 0.05, y: 0.3, width: 0.2, height: 0.2))
        }
        let track = PhraseTracker.Track(phrase: "학생", samples: samples, start: 0, end: 4)
        try controller.applyPhraseTracking(.init(tracks: [track],
            reviews: [.init(trackID: track.id, start: 1, end: 2.5, reason: .trackingLost)], cancelled: false, recognitionStep: 1))
        let shape = try #require(session.canvas.regionsBinding?().first)
        let before = try #require(session.canvas.effectForID?(shape.id))
        let issue = try #require(controller.pendingTrackingReviews.first)
        controller.trackObjects = { _, start, end, boxes, options, _, _ in
            #expect(abs(start - 1) < 0.01 && end == 2.5 && options.direction == .forward)
            return boxes.map { .init(samples: [.init(time: 1.5, box: $0.offsetBy(dx: 0.03, dy: 0))], lostTarget: true, cancelled: false) }
        }
        #expect(controller.selectTrackingReview(regionID: shape.id, reviewID: issue.review.id))
        try await waitUntil { abs(session.canvas.currentVideoTime - 1) < 0.01 }
        controller.retryTrackingReview(regionID: shape.id, reviewID: issue.review.id)
        #expect(controller.isTracking)
        try await waitUntil { !controller.isTracking }
        let failed = try #require(session.canvas.effectForID?(shape.id))
        #expect(controller.pendingTrackingReviews.count == 1)
        #expect(failed.trackingReviews.first?.id == issue.review.id && failed.trackingReviews.first?.status == .needsReview)
        #expect(failed.keyframes.first { $0.time == 0.9995 } == before.keyframes.first { $0.time == 0.9995 })
        controller.trackObjects = { _, _, end, boxes, _, _, _ in
            boxes.map { box in .init(samples: [1.5, 2.0, end].map { .init(time: $0, box: box.offsetBy(dx: ($0 - 1) * 0.03, dy: 0)) },
                                     lostTarget: false, cancelled: false) }
        }
        #expect(controller.selectTrackingReview(regionID: shape.id, reviewID: issue.review.id))
        try await waitUntil { abs(session.canvas.currentVideoTime - 1) < 0.01 }
        controller.retryTrackingReview(regionID: shape.id, reviewID: issue.review.id)
        try await waitUntil { !controller.isTracking }
        let corrected = try #require(session.canvas.effectForID?(shape.id))
        #expect(controller.pendingTrackingReviews.isEmpty)
        #expect(corrected.trackingReviews.first?.status == .corrected)
        #expect(corrected.keyframes.first { $0.time == 0.9995 } == before.keyframes.first { $0.time == 0.9995 })
        for time in [0.9994, 0.9997, 2.75, 3.5] {
            let original = RegionEditing.displayed((shape, before), at: time).boundingRect
            let updated = RegionEditing.displayed((shape, corrected), at: time).boundingRect
            #expect(abs(original.minX - updated.minX) < 0.01 && abs(original.width - updated.width) < 0.01)
        }
        let saved = try VideoProjectFile.decode(controller.projectData(producerVersion: "test.retry"))
        #expect(saved.payload.regions.first?.effect.trackingReviews.first?.status == .corrected)
        controller.perform(NSSelectorFromString("undoTapped"))
        #expect(session.canvas.effectForID?(shape.id) == failed)
        #expect(controller.pendingTrackingReviews.count == 1)
    }

    @Test func cancelDiscardsEvenLateSuccessfulPhraseResultAndKeepsExistingEdits() async throws {
        let session = try await VideoSession.open()
        defer { close(session) }
        let controller = session.controller
        controller.perform(NSSelectorFromString("addRegionTapped"))
        let existing = try #require(session.canvas.regionsBinding?().first)
        #expect(controller.setCoverDecoration(existing.id, text: "기존 편집"))
        let before = try VideoProjectFile.decode(controller.projectData(producerVersion: "test.cancel")).payload.regions
        let source = session.directory.appendingPathComponent("motion.mp4")
        let original = try VideoProjectSourceBinding.Source.capture(source)
        controller.trackPhrases = { _, _, _, cancellation, _, _ in
            while !cancellation.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
            let track = PhraseTracker.Track(phrase: "새 결과", samples: [.init(time: 0, box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))], start: 0, end: 2)
            return .init(tracks: [track], reviews: [], cancelled: false, recognitionStep: 1)
        }
        controller.findPhrases("새 결과")
        #expect(controller.isExporting)
        controller.cancelCurrentOperation()
        try await waitUntil { !controller.isExporting }
        let after = try VideoProjectFile.decode(controller.projectData(producerVersion: "test.cancel")).payload.regions
        #expect(after == before)
        #expect(try VideoProjectSourceBinding.Source.capture(source) == original)
    }

    @Test func sidebarInputButtonAndVisibilityControlsWorkInTheNativeWindow() async throws {
        let session = try await ImageSession.open(split: true)
        defer { close(session) }
        let controller = session.controller
        controller.perform(NSSelectorFromString("addRegionTapped"))
        let shape = try #require(session.canvas.regionsBinding?().first)
        session.canvas.selectRegion(id: shape.id)
        let field = try #require(session.descendants.compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "가림에 붙일 내용" })
        let apply = try #require(session.descendants.compactMap { $0 as? NSButton }.first { $0.title == "붙이기" })
        let retry = try #require(session.descendants.compactMap { $0 as? NSButton }.first { $0.title == "이 구간 다시 추적" })
        let hold = try #require(session.descendants.compactMap { $0 as? NSButton }.first { $0.title == "현재 위치로 구간 보정" })
        #expect(field.isEnabled && apply.isEnabled)
        field.stringValue = "학생 A 🙂"
        click(apply)
        #expect(session.canvas.effectForID?(shape.id)?.decoration?.text == "학생 A 🙂")
        #expect(!retry.isEnabled && !hold.isEnabled, "Image mode has no video repair operation")
        controller.setLayerHidden(shape.id, true)
        #expect(session.canvas.effectForID?(shape.id)?.enabled == false)
        controller.setLayerHidden(shape.id, false)
        #expect(session.canvas.effectForID?(shape.id)?.enabled == true)
        #expect(session.canvas.effectForID?(shape.id)?.decoration?.text == "학생 A 🙂")
        session.window.contentView?.layoutSubtreeIfNeeded()
        #expect(retry.isHiddenOrHasHiddenAncestor && hold.isHiddenOrHasHiddenAncestor,
                "The static image checker must not expose video repair controls")
        for control in [field, apply] as [NSView] {
            #expect(!control.isHiddenOrHasHiddenAncestor)
            #expect(control.bounds.width > 0 && control.bounds.width <= 280)
            _ = control.scrollToVisible(control.bounds)
            let scroll = try #require(control.enclosingScrollView)
            let rect = control.convert(control.bounds, to: scroll.contentView)
            #expect(rect.minX >= scroll.contentView.bounds.minX - 1)
            #expect(rect.maxX <= scroll.contentView.bounds.maxX + 1, "Control fits the task inspector")
            #expect(control.visibleRect.height > 0)
        }
        _ = field.scrollToVisible(field.bounds)
        let content = try #require(session.window.contentView)
        content.layoutSubtreeIfNeeded()
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("qa-20261014-mac-features")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var destination = folder.appendingPathComponent("native-ui.png")
        if FileManager.default.fileExists(atPath: destination.path) { destination = folder.appendingPathComponent("native-ui-\(UUID()).png") }
        try png.write(to: destination, options: .withoutOverwriting)
        print("Synthetic native UI screenshot: \(destination.path)")
    }

    /// Sends the button's action directly. `performClick` spins a nested
    /// event loop that can end an async test run early. Toggle-style
    /// buttons (checkbox, disclosure, on/off) change state first, as a click would.
    private func click(_ button: NSButton) {
        guard button.isEnabled, let action = button.action else { return }
        if let cell = button.cell as? NSButtonCell, !cell.showsStateBy.isEmpty { button.setNextState() }
        NSApp.sendAction(action, to: button.target, from: button)
    }
}
