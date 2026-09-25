import Testing
import AppKit
import AVFoundation
@testable import BlurAction

@Suite(.serialized)
@MainActor
final class VideoSeekTests {
    @Test
    func testRapidRequestsFinishOnlyFirstAndLatestSeek() {
        let harness = SeekHarness(duration: 30)
        let coordinator = harness.coordinator
        coordinator.request(2)
        coordinator.request(18)
        coordinator.request(7)
        #expect(harness.targets == [2])
        #expect(coordinator.suppressesTimeObserver)

        harness.finish(0)
        #expect(harness.targets == [2, 7])
        #expect(harness.outcomes.isEmpty, "An intermediate seek must not settle the timeline")
        #expect(coordinator.suppressesTimeObserver)
        harness.finish(1)
        #expect(harness.outcomes == [true])
        #expect(!coordinator.suppressesTimeObserver)
    }

    @Test
    func testObserverStaysSuppressedWhileMouseIsHeldAfterSeekCompletes() {
        let harness = SeekHarness(duration: 30)
        let coordinator = harness.coordinator
        coordinator.beginScrubbing()
        coordinator.request(12)
        for _ in 0..<20 { coordinator.request(12) }
        harness.finish(0)
        #expect(harness.targets == [12])
        #expect(!coordinator.isSeeking)
        #expect(coordinator.suppressesTimeObserver)
        coordinator.endScrubbing()
        #expect(!coordinator.suppressesTimeObserver)

        coordinator.beginScrubbing()
        coordinator.request(14)
        coordinator.endScrubbing()
        #expect(coordinator.suppressesTimeObserver, "Mouse-up must not release a pending seek")
        harness.finish(1)
        #expect(!coordinator.suppressesTimeObserver)
    }

    @Test
    func testFileReplacementIgnoresOldCompletionAndWaitsForReadyItem() {
        let harness = SeekHarness(duration: 30)
        let coordinator = harness.coordinator
        coordinator.request(20)
        coordinator.reset(duration: 4)
        coordinator.request(3)
        coordinator.request(2)
        harness.finish(0)
        #expect(harness.targets == [20])
        #expect(harness.outcomes.isEmpty)
        #expect(coordinator.pendingTime == 2)
        coordinator.setReady(true)
        #expect(harness.targets == [20, 2])
        harness.finish(1)
        #expect(harness.outcomes == [true])
        #expect(!coordinator.suppressesTimeObserver)
    }

    @Test
    func testInterruptedSeekReleasesStateAndNewerTargetStillRuns() {
        let harness = SeekHarness(duration: 30)
        harness.coordinator.request(5)
        harness.finish(0, false)
        #expect(harness.outcomes == [false])
        #expect(!harness.coordinator.suppressesTimeObserver)
        harness.coordinator.request(10)
        harness.coordinator.request(8)
        harness.finish(1, false)
        #expect(harness.targets == [5, 10, 8])
        harness.finish(2)
        #expect(harness.outcomes == [false, true])
    }

    @Test
    func testInvalidTimesAreIgnoredAndTargetsStayInsideDuration() {
        let harness = SeekHarness(duration: 4)
        harness.coordinator.request(.nan)
        harness.coordinator.request(.infinity)
        #expect(harness.targets.isEmpty)
        harness.coordinator.request(-2)
        harness.coordinator.request(100)
        harness.finish(0)
        #expect(harness.targets == [0, 4])
        harness.finish(1)
        harness.coordinator.reset(duration: .nan)
        harness.coordinator.setReady(true)
        harness.coordinator.request(1)
        #expect(harness.targets == [0, 4])
        #expect(!harness.coordinator.suppressesTimeObserver)
    }

    /// Exercises real AVPlayer and controller wiring; native mouse tracking still needs UI QA.
    @Test
    func testPausedTimelineSeeksAndResetsWithoutChangingRegions() async throws {
        _ = NSApplication.shared
        let fixtures = VideoExportTests()
        let directory = try fixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("timeline.mp4")
        try fixtures.ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=128x96:rate=12:duration=4",
                             "-c:v", "libx264", "-pix_fmt", "yuv420p", input.path])
        let shortInput = try fixtures.fixture(in: directory)
        let controller = MainWindowController()
        controller.showWindow(nil)
        defer { controller.close() }
        let container = try #require(controller.window?.contentViewController as? MainContainerViewController)
        #expect(!container.slider.isEnabled)
        #expect(container.slider.accessibilityLabel() == "영상 재생 위치")
        controller.load(url: input)
        try await waitFor { container.slider.isEnabled }
        let player = try #require(container.playerLayer.player)
        try await waitFor { container.liveBlur.contents != nil }
        #expect(player.rate == 0, "The first video frame must appear without pressing Play")
        #expect(abs(container.slider.maxValue - 4) < 0.01)
        #expect(container.slider.doubleValue == 0)
        #expect(player.rate == 0)
        controller.perform(NSSelectorFromString("addRegionTapped"))
        let original = container.canvas.regionsBinding?() ?? []
        #expect(original.count == 1)

        func moveSlider(to time: Double) {
            container.slider.doubleValue = time
            #expect(container.slider.sendAction(container.slider.action, to: container.slider.target))
        }
        container.slider.trackingBegan?()
        moveSlider(to: 3)
        try await waitFor { abs(player.currentTime().seconds - 3) < 0.01 }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(container.slider.doubleValue == 3)
        for time in [1.0, 3.0, 2.0] { moveSlider(to: time) }
        container.slider.trackingEnded?()
        try await waitFor { abs(player.currentTime().seconds - 2) < 0.01 }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(abs(container.slider.doubleValue - 2) < 0.01)
        #expect(container.timeLabel.stringValue.hasPrefix("00:02."))
        #expect(container.canvas.regionsBinding?() == original)
        #expect(player.rate == 0)
        controller.perform(NSSelectorFromString("undoTapped"))
        #expect(container.canvas.regionsBinding?().isEmpty == true, "Seeking must not consume an undo step")

        moveSlider(to: 3)
        controller.load(url: shortInput)
        #expect(!container.slider.isEnabled)
        #expect(container.slider.doubleValue == 0)
        try await waitFor { container.slider.isEnabled && player.currentItem?.status == .readyToPlay }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(abs(container.slider.maxValue - 1) < 0.01)
        #expect(container.slider.doubleValue == 0)
        #expect(container.canvas.currentVideoTime == 0)
        #expect(abs(player.currentTime().seconds) < 0.01)
    }

    @Test
    func testPointerTrackingCommitsMouseUpAndClampsAtEdges() throws {
        let slider = TrackingSlider(frame: CGRect(x: 0, y: 0, width: 300, height: 24))
        slider.minValue = 0; slider.maxValue = 8
        var began = 0; var ended = 0
        slider.trackingBegan = { began += 1 }
        slider.trackingEnded = { ended += 1 }
        func event(_ type: NSEvent.EventType, _ x: Double) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 12), modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        slider.mouseDown(with: try event(.leftMouseDown, 0))
        #expect(slider.doubleValue == 0)
        slider.mouseDragged(with: try event(.leftMouseDragged, 150))
        #expect(abs(slider.doubleValue - 4) < 0.01)
        slider.mouseUp(with: try event(.leftMouseUp, 500))
        #expect(slider.doubleValue == 8)
        #expect(began == 1 && ended == 1)
        slider.mouseDragged(with: try event(.leftMouseDragged, 10))
        #expect(slider.doubleValue == 8)
    }

    /// A flush arriving after the paused still-frame request used to cancel it without
    /// re-requesting, leaving the opened video black until Play or a resize.
    @Test
    func testPausedOutputFlushRedecodesStillFrame() async throws {
        let fixtures = VideoExportTests()
        let directory = try fixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("flush.mp4")
        try fixtures.ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=128x96:rate=12:duration=2",
                             "-c:v", "libx264", "-pix_fmt", "yuv420p", input.path])
        let item = AVPlayerItem(url: input)
        let player = AVPlayer(playerItem: item)
        let layer = LiveBlurCompositor()
        layer.videoSize = CGSize(width: 128, height: 96)
        layer.videoDisplayRect = CGRect(x: 0, y: 0, width: 128, height: 96)
        layer.attach(item: item, player: player)
        defer { layer.detach() }
        try await waitFor { layer.contents != nil }
        let output = try #require(item.outputs.compactMap { $0 as? AVPlayerItemVideoOutput }.first)
        try #require(output.delegate?.outputSequenceWasFlushed != nil)
        output.delegate?.outputSequenceWasFlushed?(output)
        #expect(layer.contents == nil, "A flush must drop the stale frame first")
        try await waitFor { layer.contents != nil }
        #expect(player.rate == 0)
    }

    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try #require(predicate(), "Timed out waiting for the player/timeline")
    }
}

@MainActor
private final class SeekHarness {
    var targets: [Double] = []
    var outcomes: [Bool] = []
    private var completions: [SeekCoordinator.Completion] = []
    lazy var coordinator: SeekCoordinator = {
        let coordinator = SeekCoordinator { [weak self] time, completion in
            self?.targets.append(time)
            self?.completions.append(completion)
        }
        coordinator.didSettle = { [weak self] in self?.outcomes.append($0) }
        return coordinator
    }()

    init(duration: Double) {
        coordinator.reset(duration: duration)
        coordinator.setReady(true)
    }

    func finish(_ index: Int, _ finished: Bool = true) { completions[index](finished) }
}
