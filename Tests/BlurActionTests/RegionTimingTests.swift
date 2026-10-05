import Testing
import AppKit
import AVFoundation
import CoreImage
@testable import BlurAction

@Suite(.serialized)
@MainActor
struct RegionTimingTests {
    @Test
    func testCreationAndPresetRangesDriveActualRenderedPixels() throws {
        let renderer = RenderingCoreTests()
        let source = renderer.checker()
        let shape = renderer.rectangle(CGRect(x: 10, y: 10, width: 70, height: 60))
        let pairs = RegionEditing.updating([shape], in: [], time: 5, recording: true,
                                           creationTime: 2, videoDuration: 8)
        let effect = try #require(pairs.first?.effect)
        #expect(effect.timeRange == 2...8)
        let sample = CGRect(x: 25, y: 25, width: 30, height: 25)
        for time in [0.0, 1.99, 8.01] {
            let frame = try BlurRenderer.render(image: source, pairs: pairs, canvasSize: renderer.size, time: time)
            #expect(renderer.pixels(frame) == renderer.pixels(source))
        }
        for time in [2.0, 5.0, 8.0] {
            let frame = try BlurRenderer.render(image: source, pairs: pairs, canvasSize: renderer.size, time: time)
            #expect(renderer.difference(frame, source, rect: sample) > 10)
        }
        var preset = effect
        preset.timeRange = try #require(RegionEffect.durationRange(startingAt: 3, seconds: 0.5, videoDuration: 8))
        for (time, active) in [(2.99, false), (3.0, true), (3.5, true), (3.51, false)] {
            let frame = try BlurRenderer.render(image: source, pairs: [(shape, preset)], canvasSize: renderer.size, time: time)
            #expect((renderer.difference(frame, source, rect: sample) > 10) == active)
        }
        let atEOF = RegionEffect.created(at: 8, videoDuration: 8)
        #expect(atEOF.timeRange == 8...8)
        #expect(!atEOF.appliesToEntireVideo)
        #expect(RegionEffect.created(at: 12, videoDuration: 12).timeRange == 12...12,
                "The model retains an explicit EOF timestamp; controller editing uses the displayed last frame")
        let frameBeforeEOF = try BlurRenderer.render(image: source, pairs: [(shape, atEOF)], canvasSize: renderer.size, time: 1)
        #expect(renderer.pixels(frameBeforeEOF) == renderer.pixels(source))
        #expect(!RegionEffect.created(at: 0, videoDuration: 0).isActive(at: 0))
        #expect(!RegionEffect.created(at: .nan, videoDuration: 8).isActive(at: 1))
        #expect(RegionEffect.durationRange(startingAt: 8, seconds: 1, videoDuration: 8) == nil)
        #expect(RegionEffect.durationRange(startingAt: 7.8, seconds: 10, videoDuration: 8) == 7.8...8)
        #expect(RegionEffect.created(at: nil, videoDuration: nil) == .alwaysOn())
    }

    @Test
    func testEveryCanvasCreationModeRetainsFirstPointTimeAndUndoRedo() async throws {
        let fixture = try await TimingFixture.open()
        defer { fixture.close() }
        let canvas = fixture.container.canvas
        let mode = try #require(descendants(fixture.container.view).compactMap { $0 as? NSSegmentedControl }.first(where: { $0.segmentCount == 4 }))
        var clock = 2.0
        canvas.creationTimeProvider = { clock }
        // Rectangle, ellipse, free polygon; click polygons closed by Enter, first point, or double-click.
        for scenario in 0..<6 {
            mode.selectedSegment = [0, 1, 3, 2, 2, 2][scenario]
            #expect(mode.sendAction(mode.action, to: mode.target))
            clock = 2
            canvas.mouseDown(with: try fixture.mouse(.leftMouseDown, 30, 30))
            if scenario < 2 {
                clock = 6
                canvas.mouseDragged(with: try fixture.mouse(.leftMouseDragged, 110, 120))
                canvas.mouseUp(with: try fixture.mouse(.leftMouseUp, 110, 120))
            } else if scenario == 2 {
                clock = 6
                canvas.mouseDragged(with: try fixture.mouse(.leftMouseDragged, 110, 30))
                canvas.mouseDragged(with: try fixture.mouse(.leftMouseDragged, 65, 120))
                canvas.mouseUp(with: try fixture.mouse(.leftMouseUp, 30, 30))
            } else {
                canvas.mouseUp(with: try fixture.mouse(.leftMouseUp, 30, 30))
                #expect(canvas.creationStartTime == 2, "First vertex time must survive mouse-up")
                clock = 6
                for point in [CGPoint(x: 110, y: 30), CGPoint(x: 65, y: 120)] {
                    canvas.mouseDown(with: try fixture.mouse(.leftMouseDown, point.x, point.y))
                    canvas.mouseUp(with: try fixture.mouse(.leftMouseUp, point.x, point.y))
                }
                if scenario == 3 {
                    canvas.keyDown(with: try fixture.key(36))
                } else {
                    let point = scenario == 4 ? CGPoint(x: 30, y: 30) : CGPoint(x: 65, y: 120)
                    canvas.mouseDown(with: try fixture.mouse(.leftMouseDown, point.x, point.y))
                    canvas.mouseUp(with: try fixture.mouse(.leftMouseUp, point.x, point.y))
                }
            }
            let shapes = canvas.regionsBinding?() ?? []
            #expect(shapes.count == 1)
            let shape = try #require(shapes.first)
            #expect(canvas.effectForID?(shape.id)?.timeRange == 2...12)
            #expect(canvas.creationStartTime == nil)
            fixture.controller.perform(NSSelectorFromString("undoTapped"))
            #expect(canvas.regionsBinding?().isEmpty == true)
            fixture.controller.perform(NSSelectorFromString("redoTapped"))
            #expect(canvas.effectForID?(shape.id)?.timeRange == 2...12)
            fixture.controller.perform(NSSelectorFromString("undoTapped"))
        }
        // Cancelling a polygon must not give its timestamp to the next polygon.
        clock = 3
        canvas.mouseDown(with: try fixture.mouse(.leftMouseDown, 30, 30))
        canvas.mouseUp(with: try fixture.mouse(.leftMouseUp, 30, 30))
        canvas.keyDown(with: try fixture.key(53))
        clock = 7
        canvas.mouseDown(with: try fixture.mouse(.leftMouseDown, 30, 30))
        canvas.mouseUp(with: try fixture.mouse(.leftMouseUp, 30, 30))
        #expect(canvas.creationStartTime == 7)
    }

    @Test
    func testPlaybackGestureUsesMouseDownClockAndToolbarUsesCurrentClock() async throws {
        let fixture = try await TimingFixture.open()
        defer { fixture.close() }
        try await fixture.seek(2)
        fixture.controller.perform(NSSelectorFromString("togglePlay"))
        try await waitFor { fixture.player.rate > 0 && fixture.player.currentTime().seconds > 2.1 }
        let before = fixture.player.currentTime().seconds
        // Edits stamp the frame on screen, which trails the player clock by up to one frame (12 fps fixture).
        let frameLag = 1.0 / 12 + 0.03
        fixture.container.canvas.mouseDown(with: try fixture.mouse(.leftMouseDown, 30, 30))
        let captured = try #require(fixture.container.canvas.creationStartTime)
        #expect(captured >= before - frameLag)
        #expect(captured <= fixture.player.currentTime().seconds + 0.03)
        try await waitFor { fixture.player.currentTime().seconds > captured + 0.25 }
        fixture.container.canvas.mouseDragged(with: try fixture.mouse(.leftMouseDragged, 110, 120))
        fixture.container.canvas.mouseUp(with: try fixture.mouse(.leftMouseUp, 110, 120))
        let drawn = try XCTUnwrap(fixture.container.canvas.regionsBinding?().first)
        #expect(fixture.container.canvas.effectForID?(drawn.id)?.timeRange == captured...12)
        #expect(fixture.container.canvas.effectForID?(drawn.id)?.isActive(at: 0) == false)

        let toolbarStart = fixture.player.currentTime().seconds
        fixture.controller.perform(NSSelectorFromString("addRegionTapped"))
        let added = try XCTUnwrap(fixture.container.canvas.regionsBinding?().last)
        let effect = try #require(fixture.container.canvas.effectForID?(added.id))
        #expect(effect.timeRange.lowerBound >= toolbarStart - frameLag)
        #expect(effect.timeRange.lowerBound <= fixture.player.currentTime().seconds + 0.03)
        #expect(effect.timeRange.upperBound == 12)
        #expect(!effect.isActive(at: 0))
        fixture.controller.perform(NSSelectorFromString("togglePlay"))
    }

    @Test
    func testSharedContextMenuPresetsTargetRegionClampAndUndo() async throws {
        let fixture = try await TimingFixture.open()
        defer { fixture.close() }
        try await fixture.seek(0.5)
        fixture.controller.perform(NSSelectorFromString("addRegionTapped"))
        let first = try XCTUnwrap(fixture.container.canvas.regionsBinding?().first)
        let firstEffect = try #require(fixture.container.canvas.effectForID?(first.id))
        try await fixture.seek(1)
        fixture.controller.perform(NSSelectorFromString("addRegionTapped"))
        let second = try XCTUnwrap(fixture.container.canvas.regionsBinding?().last)
        let original = try #require(fixture.container.canvas.effectForID?(second.id))
        try await fixture.seek(2)
        let menu = fixture.controller.makeRegionContextMenu(for: second.id)
        let presets = menu.items.filter { $0.action == NSSelectorFromString("applyDurationPreset:") }
        #expect(presets.map(\.title) == ["0.5", "1", "3", "5", "10"].map { "현재 위치부터 \($0)초" })
        // Selecting later must retain the menu-open clock, even when playback has advanced.
        try await fixture.seek(4)
        for (item, seconds) in zip(presets, [0.5, 1.0, 3.0, 5.0, 10.0]) {
            fixture.container.canvas.selectRegion(id: first.id)
            #expect(item.isEnabled)
            let action = try #require(item.action)
            #expect(NSApp.sendAction(action, to: item.target, from: item))
            let expected = 2.0...min(12, 2 + seconds)
            #expect(fixture.container.canvas.effectForID?(second.id)?.timeRange == expected)
            #expect(fixture.container.canvas.effectForID?(first.id) == firstEffect)
            fixture.controller.perform(NSSelectorFromString("undoTapped"))
            #expect(fixture.container.canvas.effectForID?(second.id) == original)
            fixture.controller.perform(NSSelectorFromString("redoTapped"))
            #expect(fixture.container.canvas.effectForID?(second.id)?.timeRange == expected)
            fixture.controller.perform(NSSelectorFromString("undoTapped"))
        }
        let entire = try #require(menu.items.first { $0.title == "영상 전체" })
        let entireAction = try #require(entire.action)
        #expect(NSApp.sendAction(entireAction, to: entire.target, from: entire))
        #expect(fixture.container.canvas.effectForID?(second.id)?.timeRange == 0...0)
        #expect(fixture.container.canvas.effectForID?(first.id) == firstEffect)
        fixture.controller.perform(NSSelectorFromString("undoTapped"))
        #expect(fixture.container.canvas.effectForID?(second.id) == original)
        fixture.controller.perform(NSSelectorFromString("redoTapped"))
        #expect(fixture.container.canvas.effectForID?(second.id)?.timeRange == 0...0)
        fixture.controller.perform(NSSelectorFromString("undoTapped"))
        try await fixture.seek(11.75)
        let nearEnd = try #require(fixture.controller.makeRegionContextMenu(for: second.id).items.first)
        let nearEndAction = try #require(nearEnd.action)
        #expect(NSApp.sendAction(nearEndAction, to: nearEnd.target, from: nearEnd))
        #expect(fixture.container.canvas.effectForID?(second.id)?.timeRange == 11.75...12)
        try await fixture.seek(12)
        let atEnd = fixture.controller.makeRegionContextMenu(for: second.id).items.filter { $0.action == NSSelectorFromString("applyDurationPreset:") }
        let lastDisplayedPTS = 143.0 / 12
        #expect(atEnd.count == 5 && atEnd.allSatisfy { $0.isEnabled })
        // At transport EOF the last decoded frame remains displayed and editable.
        // An earlier menu still retains its own displayed-frame anchor.
        #expect(NSApp.sendAction(nearEndAction, to: nearEnd.target, from: nearEnd))
        #expect(fixture.container.canvas.effectForID?(second.id)?.timeRange == 11.75...12)
        let eofItem = try #require(atEnd.first)
        let eofAction = try #require(eofItem.action)
        #expect(NSApp.sendAction(eofAction, to: eofItem.target, from: eofItem))
        #expect(fixture.container.canvas.effectForID?(second.id)?.timeRange == lastDisplayedPTS...12)
        fixture.controller.perform(NSSelectorFromString("addRegionTapped"))
        let eofShape = try XCTUnwrap(fixture.container.canvas.regionsBinding?().last)
        #expect(fixture.container.canvas.effectForID?(eofShape.id)?.timeRange == lastDisplayedPTS...12)
        #expect(fixture.container.canvas.effectForID?(eofShape.id)?.isActive(at: lastDisplayedPTS) == true)
        #expect(fixture.container.canvas.effectForID?(eofShape.id)?.isActive(at: 1) == false)
    }

    @Test
    func testPrecisePixelPositionRecordsMotionFromStartAndSpecsStayVisible() async throws {
        let fixture = try await TimingFixture.open()
        defer { fixture.close() }
        let root = try #require(fixture.controller.window?.contentView)
        let labels = descendants(root).compactMap { $0 as? NSTextField }
        let original = try #require(labels.first { $0.accessibilityLabel() == "원본 파일 사양" })
        let output = try #require(labels.first { $0.accessibilityLabel() == "내보내기 사양" })
        #expect(original.stringValue.contains("128 × 96px"))
        #expect(original.stringValue.contains("12.00 fps"))
        #expect(output.stringValue.contains("H.264"))
        #expect(output.stringValue.contains("목표"))

        fixture.controller.perform(NSSelectorFromString("addRegionTapped"))
        let base = try XCTUnwrap(fixture.container.canvas.regionsBinding?().first)
        try await fixture.seek(2)
        for (label, value) in [("왼쪽 X (원본 픽셀)", "12"), ("위쪽 Y (원본 픽셀)", "8"),
                               ("너비 (원본 픽셀)", "40"), ("높이 (원본 픽셀)", "30")] {
            let field = try #require(labels.first { $0.accessibilityLabel() == label })
            field.stringValue = value
        }
        fixture.controller.perform(NSSelectorFromString("applyPrecisePosition"))
        let after = try #require(fixture.container.canvas.effectForID?(base.id))
        // Motion recording (default on): the pre-edit placement holds from the region start
        // and the region glides to the typed position at 2 s, like a drag at that time.
        #expect(after.keyframes.count == 2)
        #expect(after.keyframes.first?.time == 0 && after.keyframes.first?.rect == base.boundingRect)
        #expect(abs(after.keyframes[1].time - 2) < 0.001)
        let rect = after.keyframes[1].rect
        let sx = fixture.container.canvas.bounds.width / 128
        let sy = fixture.container.canvas.bounds.height / 96
        #expect(abs(rect.minX - 12 * sx) < 0.2)
        #expect(abs(rect.minY - (96 - 8 - 30) * sy) < 0.2)
        #expect(abs(rect.width - 40 * sx) < 0.2)
        #expect(abs(rect.height - 30 * sy) < 0.2)
        #expect(RegionEditing.displayed((base, after), at: 0) == base)
        let midway = RegionEditing.displayed((base, after), at: 1).boundingRect
        #expect(abs(midway.minX - (base.boundingRect.minX + rect.minX) / 2) < 0.2)
        fixture.controller.perform(NSSelectorFromString("undoTapped"))
        #expect(fixture.container.canvas.effectForID?(base.id)?.keyframes.isEmpty == true)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

@MainActor
private func waitFor(_ predicate: () -> Bool) async throws {
    for _ in 0..<500 {
        if predicate() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try #require(predicate(), "Timed out waiting for synthetic video")
}

@MainActor
private struct TimingFixture {
    let controller: MainWindowController
    let container: MainContainerViewController
    let player: AVPlayer
    let directory: URL

    static func open() async throws -> TimingFixture {
        _ = NSApplication.shared
        let helper = VideoExportTests()
        let directory = try helper.directory()
        let controller = MainWindowController()
        do {
            let input = directory.appendingPathComponent("timing.mp4")
            try helper.ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=128x96:rate=12:duration=12",
                               "-c:v", "libx264", "-pix_fmt", "yuv420p", input.path])
            controller.showWindow(nil)
            controller.load(url: input)
            let container = try #require(controller.window?.contentViewController as? MainContainerViewController)
            let player = try #require(container.playerLayer.player)
            try await waitFor { container.slider.isEnabled && player.currentItem?.status == .readyToPlay }
            container.view.layoutSubtreeIfNeeded()
            return TimingFixture(controller: controller, container: container, player: player, directory: directory)
        } catch {
            controller.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func close() {
        player.pause()
        controller.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func seek(_ time: Double) async throws {
        container.slider.doubleValue = time
        #expect(container.slider.sendAction(container.slider.action, to: container.slider.target))
        // This fixture has exactly 144 frames at 12fps. A seek must settle its actual
        // decoded frame and edit providers, not only the transport's requested clock.
        let expectedPTS = min(floor(time * 12), 143) / 12
        try await waitFor {
            guard let pts = container.liveBlur.presentedFrameTime?.seconds,
                  let contents = container.liveBlur.contents,
                  CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return false }
            return abs(player.currentTime().seconds - time) < 0.001
                && abs(pts - expectedPTS) < 0.000001
                && container.canvas.currentVideoTime == pts
                && container.canvas.currentTimeProvider?() == pts
                && container.canvas.creationTimeProvider?() == pts
        }
    }

    func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: container.canvas.convert(CGPoint(x: x, y: y), to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: controller.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    func key(_ code: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: controller.window!.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }
}
