import Testing
import AppKit
import AVFoundation
@testable import BlurAction

/// Timed erasing, groups, stacking order, arrows and text, and project files.
@Suite(.serialized)
@MainActor
final class GroupsEraserProjectTests {
    // MARK: Rendering

    @Test
    func testBrushEraserIsTimedAndClearsOnlyDrawingsBelow() throws {
        let helper = RenderingCoreTests()
        let source = helper.checker()
        let size = helper.size
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let below = DrawingAnnotation(kind: .rectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 80)],
                                      color: red, lineWidth: 2, fillOpacity: 1)
        var eraser = DrawingAnnotation(kind: .eraser, points: [CGPoint(x: 0, y: 45), CGPoint(x: 128, y: 45)], lineWidth: 12)
        eraser.timeRange = 2...5
        let above = DrawingAnnotation(kind: .ellipse, points: [CGPoint(x: 70, y: 35), CGPoint(x: 90, y: 55)],
                                      color: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), lineWidth: 2, fillOpacity: 1)
        let items = [below, eraser, above]
        func pixel(_ image: CIImage, _ x: CGFloat, _ y: CGFloat) -> [UInt8] {
            helper.pixels(image.cropped(to: CGRect(x: x, y: y, width: 1, height: 1)))
        }
        let before = try BlurRenderer.render(image: source, pairs: [], canvasSize: size, time: 1, annotations: items)
        let during = try BlurRenderer.render(image: source, pairs: [], canvasSize: size, time: 3, annotations: items)
        #expect(pixel(before, 30, 45)[0] >= 253, "Before the eraser's time the drawing is whole")
        #expect(pixel(during, 30, 45) == pixel(source, 30, 45), "The stroke reveals the video under the drawing")
        #expect(pixel(during, 30, 70)[0] >= 253, "Only the brushed band is erased")
        #expect(pixel(during, 80, 45)[2] >= 253, "A drawing added after the eraser stays")
    }

    @Test
    func testArrowAndTextRender() throws {
        let helper = RenderingCoreTests()
        let source = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: helper.size))
        let arrow = DrawingAnnotation(kind: .arrow, points: [CGPoint(x: 10, y: 20), CGPoint(x: 100, y: 20)],
                                      color: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1), lineWidth: 3)
        let head = try #require(arrow.arrowHead)
        #expect(head.boundingBox.maxX >= 99 && head.boundingBox.height > 10)
        let text = DrawingAnnotation.text("AB", at: CGPoint(x: 10, y: 40), fontSize: 30, color: .white)
        #expect(abs(text.bounds.height - 37.5) < 0.01 && text.bounds.width > 20)
        let out = try BlurRenderer.render(image: source, pairs: [], canvasSize: helper.size, time: nil, annotations: [arrow, text])
        let box = helper.pixels(out.cropped(to: text.bounds))
        #expect(stride(from: 0, to: box.count, by: 4).contains { box[$0] > 200 }, "Text pixels are drawn inside its box")
        let tip = helper.pixels(out.cropped(to: CGRect(x: 92, y: 18, width: 4, height: 4)))
        #expect(tip[1] > 200)
    }

    // MARK: Video eraser

    @Test
    func testEraserOnVideoKeepsEarlierTraces() async throws {
        let session = try await VideoSession.open()
        defer { session.close() }
        let canvas = session.container.canvas
        session.controller.perform(NSSelectorFromString("addRegionTapped"))
        let region = try #require(canvas.regionsBinding?().first)
        session.tool(1)
        try session.drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 40))
        let drawing = try #require(canvas.annotationsBinding?().first)

        try await session.seek(2)
        session.tool(2)
        session.eraserMode(1)
        let center = CGPoint(x: region.boundingRect.midX, y: region.boundingRect.midY)
        try session.drag(from: center, to: center)
        let effect = try #require(canvas.effectForID?(region.id))
        #expect(effect.isActive(at: 1.9) && !effect.isActive(at: 2) && !effect.isActive(at: 4), "Ends at the erase time")
        try session.drag(from: CGPoint(x: 10, y: 25), to: CGPoint(x: 10, y: 25))
        let ended = try #require(canvas.annotationsBinding?().first { $0.id == drawing.id })
        #expect(ended.isVisible(at: 1) && !ended.isVisible(at: 2))

        // Partial (brush) erasing adds a timed eraser stroke from now on.
        session.eraserMode(0)
        try session.drag(from: CGPoint(x: 5, y: 20), to: CGPoint(x: 50, y: 20))
        let stroke = try #require(canvas.annotationsBinding?().last)
        #expect(stroke.isEraser && abs(stroke.timeRange.lowerBound - 2) < 0.01)

        // Turning "from now" off removes items entirely.
        let fromNow = try #require(session.descendants.compactMap { $0 as? NSButton }.first { $0.title == "영상: 지금 시점부터 지우기" })
        fromNow.state = .off
        _ = fromNow.sendAction(fromNow.action, to: fromNow.target)
        session.controller.perform(NSSelectorFromString("undoTapped"))
        session.controller.perform(NSSelectorFromString("undoTapped"))
        session.controller.perform(NSSelectorFromString("undoTapped"))
        #expect(canvas.effectForID?(region.id)?.isActive(at: 3) == true, "Undo restores the region's full time")
        session.eraserMode(1)
        try session.drag(from: center, to: center)
        #expect(canvas.regionsBinding?().contains { $0.id == region.id } == false)
    }

    // MARK: Groups and order

    @Test
    func testGroupMovesTogetherSharesTimeAndUngroups() async throws {
        let session = try await VideoSession.open()
        defer { session.close() }
        let canvas = session.container.canvas
        session.controller.perform(NSSelectorFromString("addRegionTapped"))
        let region = try #require(canvas.regionsBinding?().first)
        let center = CGPoint(x: region.boundingRect.midX, y: region.boundingRect.midY)
        session.tool(1)
        try session.drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 40))
        let drawing = try #require(canvas.annotationsBinding?().first)
        // Shift-picks survive switching tools, so regions and drawings can be grouped together.
        session.tool(0)
        try session.shiftClick(center)
        session.tool(1)
        try session.shiftClick(CGPoint(x: 10, y: 25))
        session.controller.perform(NSSelectorFromString("groupTapped"))
        let group = try #require(canvas.effectForID?(region.id)?.groupID)
        #expect(canvas.annotationsBinding?().first?.groupID == group)

        // Moving the drawing at 2 s moves the region by the same offset, both recorded at 2 s.
        try await session.seek(2)
        try session.drag(from: CGPoint(x: 10, y: 25), to: CGPoint(x: 30, y: 25))
        let moved = try #require(canvas.regionsBinding?().first).boundingRect
        #expect(abs(moved.minX - (region.boundingRect.minX + 20)) < 0.01 && abs(moved.minY - region.boundingRect.minY) < 0.01)
        #expect(canvas.effectForID?(region.id)?.keyframes.last.map { abs($0.time - 2) < 0.01 } == true)
        session.controller.perform(NSSelectorFromString("undoTapped"))
        #expect(canvas.regionsBinding?().first?.boundingRect == region.boundingRect, "The group move is one undo step")

        // A time range applies to the whole group.
        canvas.selectAnnotation(id: drawing.id)
        let fields = session.descendants.compactMap { $0 as? NSTextField }
        let start = try #require(fields.first { $0.accessibilityLabel() == "블러 시작 시간 (초)" })
        let end = try #require(fields.first { $0.accessibilityLabel() == "블러 끝 시간 (초)" })
        start.stringValue = "1"; end.stringValue = "3"
        session.controller.perform(NSSelectorFromString("applyTimeRange"))
        #expect(canvas.effectForID?(region.id)?.timeRange == 1...3)
        #expect(canvas.annotationsBinding?().first?.timeRange == 1...3)

        session.controller.perform(NSSelectorFromString("ungroupTapped"))
        #expect(canvas.effectForID?(region.id)?.groupID == nil && canvas.annotationsBinding?().first?.groupID == nil)
    }

    @Test
    func testStackingOrderForDrawingsAndRegions() async throws {
        let session = try await ImageSession.open()
        defer { session.close() }
        let canvas = session.canvas
        session.tool(1)
        try session.drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 50))
        try session.drag(from: CGPoint(x: 60, y: 10), to: CGPoint(x: 100, y: 50))
        let ids = (canvas.annotationsBinding?() ?? []).map(\.id)
        canvas.selectAnnotation(id: ids[0])
        session.controller.perform(NSSelectorFromString("bringToFrontTapped"))
        #expect((canvas.annotationsBinding?() ?? []).map(\.id) == [ids[1], ids[0]])
        session.controller.perform(NSSelectorFromString("sendBackwardTapped"))
        #expect((canvas.annotationsBinding?() ?? []).map(\.id) == ids)
        session.controller.perform(NSSelectorFromString("undoTapped"))
        #expect((canvas.annotationsBinding?() ?? []).map(\.id) == [ids[1], ids[0]])

        session.tool(0)
        session.controller.perform(NSSelectorFromString("addRegionTapped"))
        session.controller.perform(NSSelectorFromString("addRegionTapped"))
        let regions = (canvas.regionsBinding?() ?? []).map(\.id)
        canvas.selectRegion(id: regions[1])
        session.controller.perform(NSSelectorFromString("sendToBackTapped"))
        #expect((canvas.regionsBinding?() ?? []).map(\.id) == [regions[1], regions[0]])
    }

    @Test
    func testArrowModeAndTextEditing() async throws {
        let session = try await ImageSession.open()
        defer { session.close() }
        let canvas = session.canvas
        session.tool(1)
        session.mode(4)
        try session.drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 80, y: 40))
        #expect(canvas.annotationsBinding?().last?.kind == .arrow)

        session.controller.addText("안녕", at: CGPoint(x: 20, y: 120))
        let text = try #require(canvas.annotationsBinding?().last)
        #expect(text.kind == .text && text.text == "안녕")
        #expect(abs(text.bounds.maxY - 120) < 0.01, "The click point is the text's top-left")
        session.controller.replaceText(of: text.id, with: "안녕하세요")
        let longer = try #require(canvas.annotationsBinding?().last)
        #expect(longer.text == "안녕하세요" && longer.bounds.width > text.bounds.width * 1.5)
        #expect(abs(longer.bounds.height - text.bounds.height) < 0.01)
    }

    // MARK: Project files

    @Test
    func testProjectRoundTripAndRejectsBadFiles() async throws {
        let session = try await VideoSession.open()
        defer { session.close() }
        let canvas = session.container.canvas
        session.controller.perform(NSSelectorFromString("addRegionTapped"))
        let region = try #require(canvas.regionsBinding?().first)
        try await session.seek(2)
        let center = CGPoint(x: region.boundingRect.midX, y: region.boundingRect.midY)
        try session.drag(from: center, to: CGPoint(x: center.x + 30, y: center.y))
        session.tool(1)
        try session.drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 40))
        let data = try session.controller.projectData()
        let project = try ProjectFile.decode(data)
        #expect(project.regions.count == 1 && project.drawings.count == 1)
        #expect(project.regions[0].effect.keyframes.map(\.time) == [0, 2])
        #expect(project.regions[0].shape.boundingRect.maxX <= 1.0001, "Geometry is normalized")

        let reopened = MainWindowController()
        reopened.showWindow(nil)
        defer { reopened.close() }
        let container = try #require(reopened.window?.contentViewController as? MainContainerViewController)
        reopened.window?.setContentSize(NSSize(width: 900, height: 600))
        reopened.openProject(project, media: URL(fileURLWithPath: project.mediaPath))
        try await waitUntil { container.canvas.regionsBinding?().count == 1 }
        let restored = try #require(container.canvas.regionsBinding?().first)
        let effect = try #require(container.canvas.effectForID?(restored.id))
        #expect(effect.keyframes.map(\.time) == [0, 2])
        let sx = container.canvas.bounds.width / canvas.bounds.width
        #expect(abs(restored.boundingRect.width - region.boundingRect.width * sx) < 0.5, "Scaled to the new window")
        #expect(container.canvas.annotationsBinding?().count == 1)

        var json = try #require(String(data: data, encoding: .utf8))
        json = json.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 99")
        #expect(throws: ProjectFile.ProjectError.self) { try ProjectFile.decode(Data(json.utf8)) }
        var wild = project
        wild.drawings[0].points[0] = CGPoint(x: 1e9, y: 0)
        #expect(throws: ProjectFile.ProjectError.self) { try ProjectFile.decode(try wild.encoded()) }
        #expect(throws: ProjectFile.ProjectError.self) { try ProjectFile.decode(Data("{}".utf8)) }
    }
}

extension EditorSession {
    func shiftClick(_ point: CGPoint) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [.shift],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { canvas.mouseDown(with: event) } else { canvas.mouseUp(with: event) }
        }
    }
}
