import Testing
import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import BlurAction

/// Motion recording shared by regions and drawings, cover styles, and the editing tools.
@Suite(.serialized)
@MainActor
final class MotionAndToolsTests {
    // MARK: Motion rules

    @Test
    func testPausedEditsGlideFromStartAndRecordingOffMovesWholePath() {
        let base = RegionShape.rectangle(id: UUID(), origin: CGPoint(x: 10, y: 10), size: CGSize(width: 20, height: 20))
        let pairs: [RegionEditing.Pair] = [(base, .created(at: 1, videoDuration: 10))]
        func at(_ x: CGFloat) -> RegionShape { base.replacing(rect: CGRect(x: x, y: 10, width: 20, height: 20)) }

        let atStart = RegionEditing.updating([at(15)], in: pairs, time: 1, recording: true)
        #expect(atStart[0].shape == at(15) && atStart[0].effect.keyframes.isEmpty, "An edit at the start time just repositions")

        let first = RegionEditing.updating([at(50)], in: pairs, time: 3, recording: true)
        #expect(first[0].effect.keyframes.map(\.time) == [1, 3])
        #expect(RegionEditing.displayed(first[0], at: 1) == base)
        #expect(RegionEditing.displayed(first[0], at: 2).boundingRect.minX == 30)
        #expect(RegionEditing.displayed(first[0], at: 9) == at(50))

        let second = RegionEditing.updating([at(90)], in: first, time: 5, recording: true)
        #expect(second[0].effect.keyframes.map(\.time) == [1, 3, 5])
        #expect(RegionEditing.displayed(second[0], at: 4).boundingRect.minX == 70)

        // Frame-by-frame stepping keeps every frame's position (k/60 steps are not exactly 1/60 apart).
        for fps in [60.0, 120.0, 240.0] {
            var frames: [RegionKeyframe] = []
            for k in 0..<Int(fps * 5) { frames = MotionTrack.inserting(RegionKeyframe(time: Double(k) / fps, rect: .zero), into: frames) }
            #expect(frames.count == Int(fps * 5), "\(fps) fps")
        }

        let shifted = RegionEditing.updating([at(80)], in: second, time: 4, recording: false)
        #expect(shifted[0].effect.keyframes.map(\.rect.minX) == [20, 60, 100])
        #expect(shifted[0].shape.boundingRect.minX == 20)
    }

    @Test
    func testDrawingTimingVisibilityAndMotion() {
        var drawing = DrawingAnnotation(kind: .line, points: [CGPoint(x: 0, y: 10), CGPoint(x: 40, y: 10)])
        drawing.timeRange = 2...8
        #expect(!drawing.isVisible(at: 1) && drawing.isVisible(at: 5) && drawing.isVisible(at: nil))

        var moved = drawing
        moved.points = [CGPoint(x: 20, y: 30), CGPoint(x: 60, y: 30)]
        let tracked = drawing.applyingEdit(moved, time: 6, recording: true)
        #expect(tracked.points == drawing.points, "Base geometry stays; motion lives in keyframes")
        #expect(tracked.keyframes.map(\.time) == [2, 6])
        #expect(tracked.displayed(at: 4).points == [CGPoint(x: 10, y: 20), CGPoint(x: 50, y: 20)])
        #expect(tracked.displayed(at: 7).points == moved.points)

        var nudged = tracked.displayed(at: 4)
        nudged.points = nudged.points.map { CGPoint(x: $0.x + 5, y: $0.y) }
        let whole = tracked.applyingEdit(nudged, time: 4, recording: false)
        #expect(whole.keyframes.map(\.rect.minX) == [5, 25])
        #expect(whole.points.first == CGPoint(x: 5, y: 10))

        let still = drawing.applyingEdit(moved, time: nil, recording: true)
        #expect(still.points == moved.points && still.keyframes.isEmpty, "Images edit the geometry directly")
    }

    // MARK: Rendering

    @Test
    func testSolidMosaicFillAndDrawingTimeRender() throws {
        let helper = RenderingCoreTests()
        let source = helper.checker()
        let size = helper.size
        let rect = CGRect(x: 32, y: 24, width: 48, height: 40)

        var solid = RegionEffect(blurRadius: 0, featherRadius: 0)
        solid.style = .solid
        solid.color = RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
        let covered = try BlurRenderer.render(image: source, pairs: [(helper.rectangle(rect), solid)], canvasSize: size, time: nil)
        let inside = helper.pixels(covered.cropped(to: CGRect(x: 50, y: 40, width: 4, height: 4)))
        for i in stride(from: 0, to: inside.count, by: 4) {
            #expect(inside[i] >= 253 && inside[i + 1] <= 2 && inside[i + 2] <= 2)
        }
        #expect(helper.difference(source, covered, rect: CGRect(x: 0, y: 0, width: 16, height: 16)) == 0)

        var mosaic = RegionEffect(blurRadius: 8, featherRadius: 0)
        mosaic.style = .mosaic
        let tiled = try BlurRenderer.render(image: source, pairs: [(helper.rectangle(rect), mosaic)], canvasSize: size, time: nil)
        let cell = helper.pixels(tiled.cropped(to: CGRect(x: 40, y: 32, width: 8, height: 8)))
        #expect(Set(stride(from: 0, to: cell.count, by: 4).map { cell[$0] }).count == 1, "One mosaic cell is a single color")
        #expect(helper.difference(source, tiled, rect: CGRect(x: 40, y: 32, width: 8, height: 8)) > 20)

        var filled = DrawingAnnotation(kind: .rectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 50)],
                                       color: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), lineWidth: 2, fillOpacity: 1)
        let painted = try BlurRenderer.render(image: source, pairs: [], canvasSize: size, time: nil, annotations: [filled])
        let center = helper.pixels(painted.cropped(to: CGRect(x: 34, y: 28, width: 2, height: 2)))
        #expect(center[0] <= 2 && center[1] <= 2 && center[2] >= 253)

        filled.timeRange = 5...6
        let before = try BlurRenderer.render(image: source, pairs: [], canvasSize: size, time: 1, annotations: [filled])
        let during = try BlurRenderer.render(image: source, pairs: [], canvasSize: size, time: 5.5, annotations: [filled])
        #expect(helper.difference(source, before, rect: source.extent) == 0, "Drawings are hidden outside their time")
        #expect(helper.difference(source, during, rect: source.extent) > 0)
    }

    @Test
    func testExportedVideoFollowsDrawingMotionAndCoverStyles() async throws {
        let fixtures = VideoExportTests()
        let directory = try fixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("tools.mp4")
        try fixtures.ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=128x96:rate=8:duration=3",
                             "-c:v", "libx264", "-pix_fmt", "yuv420p", input.path])
        let size = CGSize(width: 128, height: 96)
        var solid = RegionEffect(blurRadius: 0, featherRadius: 0)
        solid.style = .solid
        solid.color = RGBAColor(red: 0, green: 1, blue: 0, alpha: 1)
        var mosaic = RegionEffect(blurRadius: 6, featherRadius: 4)
        mosaic.style = .mosaic
        let pairs: [RegionEditing.Pair] = [
            (.rectangle(id: UUID(), origin: CGPoint(x: 4, y: 4), size: CGSize(width: 30, height: 20)), solid),
            (.ellipse(id: UUID(), origin: CGPoint(x: 70, y: 50), size: CGSize(width: 40, height: 30)), mosaic)
        ]
        var drawing = DrawingAnnotation(kind: .ellipse, points: [CGPoint(x: 10, y: 60), CGPoint(x: 40, y: 90)],
                                        color: .systemRed, lineWidth: 3, fillOpacity: 0.35)
        drawing.timeRange = 0.5...2.5
        var moved = drawing
        moved.points = moved.points.map { CGPoint(x: $0.x + 50, y: $0.y - 40) }
        drawing = drawing.applyingEdit(moved, time: 2, recording: true)
        #expect(drawing.keyframes.count == 2)

        let exporter = BlurredVideoExporter()
        await exporter.export(input: input, pairs: pairs, quality: .original, canvasBounds: size, annotations: [drawing])
        let output = try #require(exporter.lastOutputURL, "\(exporter.statusText)")
        let source = AVAssetImageGenerator(asset: AVURLAsset(url: input))
        let result = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        for generator in [source, result] {
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        }
        let helper = RenderingCoreTests()
        for frame in [0, 6, 12, 22] {
            let t = Double(frame) / 8
            let time = CMTime(seconds: t, preferredTimescale: 600)
            let original = CIImage(cgImage: try await source.image(at: time).image)
            let actual = CIImage(cgImage: try await result.image(at: time).image)
            let expected = try BlurRenderer.render(image: original, pairs: pairs, canvasSize: size, time: t, annotations: [drawing])
            #expect(helper.difference(expected, actual, rect: expected.extent) < 12, "frame \(frame)")
        }
    }

    // MARK: Editor tools (image)

    @Test
    func testEraserClearAllDuplicateAndShortcuts() async throws {
        let session = try await ImageSession.open()
        defer { session.close() }
        let canvas = session.canvas
        var drawings: [DrawingAnnotation] { canvas.annotationsBinding?() ?? [] }
        var regions: [RegionShape] { canvas.regionsBinding?() ?? [] }

        session.controller.perform(NSSelectorFromString("addRegionTapped"))
        let region = try #require(regions.first)
        session.tool(1)
        try session.drag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 60, y: 60))
        #expect(drawings.count == 1)
        session.controller.perform(NSSelectorFromString("duplicateSelectedTapped"))
        #expect(drawings.count == 2)
        #expect(drawings[1].points.first == CGPoint(x: drawings[0].points[0].x + 12, y: drawings[0].points[0].y - 12))

        try session.key("e")
        #expect(session.tools.selectedSegment == 2, "E switches to the eraser")
        let center = CGPoint(x: region.boundingRect.midX, y: region.boundingRect.midY)
        try session.drag(from: center, to: center)
        #expect(regions.isEmpty)
        // One rub across both drawings' left edges is one undo step.
        canvas.mouseDown(with: try session.mouse(.leftMouseDown, 20, 40))
        canvas.mouseDragged(with: try session.mouse(.leftMouseDragged, 32, 40))
        canvas.mouseUp(with: try session.mouse(.leftMouseUp, 32, 40))
        #expect(drawings.isEmpty)
        session.controller.perform(NSSelectorFromString("undoTapped"))
        #expect(drawings.count == 2 && regions.isEmpty)
        session.controller.perform(NSSelectorFromString("undoTapped"))
        #expect(regions.count == 1)

        session.controller.clearItems(.all)
        #expect(drawings.isEmpty && regions.isEmpty)
        session.controller.perform(NSSelectorFromString("undoTapped"))
        #expect(drawings.count == 2 && regions.count == 1)
        session.controller.clearItems(.drawings)
        #expect(drawings.isEmpty && regions.count == 1)

        try session.key("b")
        #expect(session.tools.selectedSegment == 0)
    }

    @Test
    func testEyedropperFillAndCoverStyleForNewRegions() async throws {
        let session = try await ImageSession.open(split: true)
        defer { session.close() }
        let canvas = session.canvas
        session.tool(1)
        let width = canvas.bounds.width, height = canvas.bounds.height
        try session.drag(from: CGPoint(x: width * 0.6, y: height * 0.3), to: CGPoint(x: width * 0.9, y: height * 0.7))
        let drawing = try #require(canvas.annotationsBinding?().first)

        // Pick from the red left half, away from the drawing.
        session.controller.perform(NSSelectorFromString("pickAnnotationColor"))
        canvas.mouseDown(with: try session.mouse(.leftMouseDown, width * 0.2, height * 0.5))
        canvas.mouseUp(with: try session.mouse(.leftMouseUp, width * 0.2, height * 0.5))
        let picked = try #require(canvas.annotationsBinding?().first)
        #expect(picked.id == drawing.id)
        #expect(picked.red > 0.95 && picked.green < 0.05 && picked.blue < 0.05, "Picked \(picked.red),\(picked.green),\(picked.blue)")

        let fill = try #require(session.descendants.compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains("불투명 채우기") })
        fill.selectItem(withTitle: "불투명 채우기")
        _ = fill.sendAction(fill.action, to: fill.target)
        #expect(canvas.annotationsBinding?().first?.fillOpacity == 1)

        // Dragging in the color panel sends many changes; they are one undo step.
        let well = try #require(session.descendants.compactMap { $0 as? NSColorWell }.first { !$0.isHiddenOrHasHiddenAncestor })
        for value in stride(from: 0.1, through: 0.9, by: 0.1) {
            well.color = NSColor(srgbRed: value, green: value, blue: 0, alpha: 1)
            _ = well.sendAction(well.action, to: well.target)
        }
        #expect((canvas.annotationsBinding?().first?.green ?? 0) > 0.85)
        session.controller.perform(NSSelectorFromString("undoTapped"))
        #expect(canvas.annotationsBinding?().first?.fillOpacity == 1 && (canvas.annotationsBinding?().first?.green ?? 1) < 0.05)

        session.tool(0)
        let cover = try #require(session.descendants.compactMap { $0 as? NSSegmentedControl }.first { $0.label(forSegment: 1) == "모자이크" })
        cover.selectedSegment = 2
        _ = cover.sendAction(cover.action, to: cover.target)
        session.controller.perform(NSSelectorFromString("addRegionTapped"))
        let region = try #require(canvas.regionsBinding?().first)
        #expect(canvas.effectForID?(region.id)?.style == .solid)
        let export = try #require(session.descendants.compactMap { $0 as? NSButton }.first { $0.title == "내보내기" })
        #expect(export.isEnabled)
    }

    // MARK: Video: move while paused, frame by frame

    @Test
    func testPausedDragsRecordMotionForRegionsAndDrawings() async throws {
        let session = try await VideoSession.open()
        defer { session.close() }
        let canvas = session.container.canvas
        session.controller.perform(NSSelectorFromString("addRegionTapped"))
        let region = try #require(canvas.regionsBinding?().first)
        let start = region.boundingRect

        try await session.seek(2)
        try session.drag(from: CGPoint(x: start.midX, y: start.midY), to: CGPoint(x: start.midX + 40, y: start.midY))
        var effect = try #require(canvas.effectForID?(region.id))
        #expect(effect.keyframes.map(\.time) == [0, 2])
        #expect(abs(RegionEditing.displayed((region, effect), at: 1).boundingRect.minX - (start.minX + 20)) < 0.01)
        #expect(session.container.slider.markers == [0, 2], "Recorded times show on the timeline")

        // Recording off: a later drag moves the whole path instead of adding a position.
        let checkbox = try #require(session.descendants.compactMap { $0 as? NSButton }.first { $0.title == "움직임 기록" })
        checkbox.state = .off
        _ = checkbox.sendAction(checkbox.action, to: checkbox.target)
        try await session.seek(1)
        let shown = RegionEditing.displayed((region, effect), at: 1).boundingRect
        try session.drag(from: CGPoint(x: shown.midX, y: shown.midY), to: CGPoint(x: shown.midX, y: shown.midY + 10))
        effect = try #require(canvas.effectForID?(region.id))
        #expect(effect.keyframes.count == 2)
        #expect(effect.keyframes.allSatisfy { abs($0.rect.minY - (start.minY + 10)) < 0.01 })
        checkbox.state = .on
        _ = checkbox.sendAction(checkbox.action, to: checkbox.target)

        // Drawings: created at 1 s, shown from then on, and tracked when moved at 3 s.
        session.tool(1)
        session.mode(2) // line
        try session.drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 10))
        let line = try #require(canvas.annotationsBinding?().first)
        #expect(abs(line.timeRange.lowerBound - 1) < 0.01 && !line.isVisible(at: 0.5))
        try await session.seek(3)
        try session.drag(from: CGPoint(x: 30, y: 10), to: CGPoint(x: 30, y: 40))
        let tracked = try #require(canvas.annotationsBinding?().first)
        #expect(tracked.keyframes.map(\.time).map { ($0 * 100).rounded() / 100 } == [1, 3])
        #expect(abs((tracked.displayed(at: 2).points.first?.y ?? 0) - 25) < 0.01)
        session.controller.perform(NSSelectorFromString("undoTapped"))
        #expect(canvas.annotationsBinding?().first?.keyframes.isEmpty == true, "One drag is one undo step")
    }
}

// MARK: - Sessions

@MainActor
private func allSubviews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allSubviews) }

@MainActor
private func waitUntil(_ predicate: () -> Bool) async throws {
    for _ in 0..<500 where !predicate() { try await Task.sleep(nanoseconds: 10_000_000) }
    try #require(predicate(), "Timed out")
}

@MainActor
private class EditorSession {
    let controller = MainWindowController()
    let directory: URL
    var window: NSWindow { controller.window! }
    var container: MainContainerViewController { window.contentViewController as! MainContainerViewController }
    var canvas: VideoCanvasView { container.canvas }
    var descendants: [NSView] { allSubviews(window.contentView!) }
    var tools: NSSegmentedControl { descendants.compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 3 && $0.label(forSegment: 2) == "지우개" }! }

    init(directory: URL) { self.directory = directory }

    func close() {
        container.playerLayer.player?.pause()
        controller.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func tool(_ index: Int) { tools.selectedSegment = index; _ = tools.sendAction(tools.action, to: tools.target) }

    func mode(_ index: Int) {
        let modes = descendants.compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 4 }!
        modes.selectedSegment = index; _ = modes.sendAction(modes.action, to: modes.target)
    }

    func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(CGPoint(x: x, y: y), to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    func drag(from a: CGPoint, to b: CGPoint) throws {
        canvas.mouseDown(with: try mouse(.leftMouseDown, a.x, a.y))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, (a.x + b.x) / 2, (a.y + b.y) / 2))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, b.x, b.y))
        canvas.mouseUp(with: try mouse(.leftMouseUp, b.x, b.y))
    }

    func key(_ character: String) throws {
        window.makeFirstResponder(canvas)
        canvas.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0)))
    }
}

@MainActor
private final class ImageSession: EditorSession {
    /// A 320×160 PNG: checkerboard, or (split) solid red left half and blue right half.
    static func open(split: Bool = false) async throws -> ImageSession {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("blur-tools-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("tools.png")
        let ctx = try #require(CGContext(data: nil, width: 320, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        if split {
            ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
            ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); ctx.fill(CGRect(x: 160, y: 0, width: 160, height: 160))
        } else {
            for y in stride(from: 0, to: 160, by: 8) {
                for x in stride(from: 0, to: 320, by: 8) {
                    ctx.setFillColor(gray: (x + y) % 16 == 0 ? 0 : 1, alpha: 1)
                    ctx.fill(CGRect(x: x, y: y, width: 8, height: 8))
                }
            }
        }
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(ctx.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        let session = ImageSession(directory: directory)
        session.controller.showWindow(nil)
        session.controller.load(url: url)
        try await waitUntil { session.canvas.isEditable && session.container.liveBlur.contents != nil }
        session.window.contentView?.layoutSubtreeIfNeeded()
        return session
    }
}

@MainActor
private final class VideoSession: EditorSession {
    static func open() async throws -> VideoSession {
        _ = NSApplication.shared
        let helper = VideoExportTests()
        let directory = try helper.directory()
        let input = directory.appendingPathComponent("motion.mp4")
        try helper.ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=160x90:rate=12:duration=6",
                           "-c:v", "libx264", "-pix_fmt", "yuv420p", input.path])
        let session = VideoSession(directory: directory)
        session.controller.showWindow(nil)
        session.controller.load(url: input)
        try await waitUntil {
            session.container.slider.isEnabled && session.container.playerLayer.player?.currentItem?.status == .readyToPlay
        }
        session.container.view.layoutSubtreeIfNeeded()
        return session
    }

    func seek(_ time: Double) async throws {
        let slider = container.slider
        slider.doubleValue = time
        _ = slider.sendAction(slider.action, to: slider.target)
        let player = try #require(container.playerLayer.player)
        try await waitUntil { abs(player.currentTime().seconds - time) < 0.001 && abs(self.canvas.currentVideoTime - time) < 0.001 }
        try await Task.sleep(nanoseconds: 30_000_000)
    }
}
