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
    func testErasureIsTimedAndFollowsItsDrawing() throws {
        let helper = RenderingCoreTests()
        let source = helper.checker()
        let size = helper.size
        var erased = DrawingAnnotation(kind: .rectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 80)],
                                       color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), lineWidth: 2, fillOpacity: 1)
        erased.erasures = [.init(points: [CGPoint(x: 0, y: 45), CGPoint(x: 70, y: 45)], width: 12, from: 2)]
        let other = DrawingAnnotation(kind: .ellipse, points: [CGPoint(x: 20, y: 35), CGPoint(x: 40, y: 55)],
                                      color: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), lineWidth: 2, fillOpacity: 1)
        func pixel(_ image: CIImage, _ x: CGFloat, _ y: CGFloat) -> [UInt8] {
            helper.pixels(image.cropped(to: CGRect(x: x, y: y, width: 1, height: 1)))
        }
        func render(_ items: [DrawingAnnotation], _ time: Double) throws -> CIImage {
            try BlurRenderer.render(image: source, pairs: [], canvasSize: size, time: time, annotations: items)
        }
        // The other drawing is under the erased one, then on top: the erasure only affects its owner.
        let before = try render([other, erased], 1), during = try render([other, erased], 3)
        #expect(pixel(before, 50, 45)[0] >= 253, "Before the erase time the drawing is whole")
        #expect(pixel(during, 50, 45) == pixel(source, 50, 45), "The rubbed band shows the video")
        #expect(pixel(during, 50, 70)[0] >= 253, "Only the rubbed band is erased")
        #expect(pixel(during, 30, 45)[2] >= 253, "A drawing underneath is not erased")
        let reordered = try render([erased, other], 3)
        #expect(pixel(reordered, 30, 45)[2] >= 253 && pixel(reordered, 50, 45) == pixel(source, 50, 45))

        // Moving the drawing (here by recorded motion) carries the hole with it.
        var moved = erased
        moved.points = erased.points.map { CGPoint(x: $0.x + 50, y: $0.y) }
        let tracked = erased.applyingEdit(moved.replacingBounds(moved.bounds), time: 4, recording: true)
        let late = try render([tracked], 5)
        #expect(pixel(late, 100, 45) == pixel(source, 100, 45), "The erased band moved with the drawing")
        #expect(pixel(late, 100, 70)[0] >= 253)
        #expect(tracked.displayed(at: 5).erasures.first?.points.first == CGPoint(x: 50, y: 45))
    }

    /// Every way of moving a drawing must carry its holes (the canvas drag moves only points).
    @Test
    func testHolesFollowDragGroupMoveAndDuplicate() async throws {
        let session = try await ImageSession.open()
        defer { session.close() }
        let canvas = session.canvas
        session.tool(1)
        try session.drag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 80, y: 80))
        let drawing = try XCTUnwrap(canvas.annotationsBinding?().first)
        session.tool(2)
        session.eraserMode(0)
        try session.drag(from: CGPoint(x: 10, y: 50), to: CGPoint(x: 90, y: 50))
        func hole(_ id: UUID) -> CGPoint? { canvas.annotationsBinding?().first { $0.id == id }?.erasures.first?.points.first }
        let start = try #require(hole(drawing.id))

        session.tool(1)
        try session.drag(from: CGPoint(x: 20, y: 40), to: CGPoint(x: 60, y: 40))
        #expect(hole(drawing.id) == CGPoint(x: start.x + 40, y: start.y), "A canvas drag moves the hole")

        session.controller.perform(NSSelectorFromString("duplicateSelectedTapped"))
        let copy = try XCTUnwrap(canvas.annotationsBinding?().last)
        #expect(hole(copy.id) == CGPoint(x: start.x + 52, y: start.y - 12), "A duplicate keeps its hole in place")

        session.tool(0)
        session.controller.perform(NSSelectorFromString("addRegionTapped"))
        let region = try XCTUnwrap(canvas.regionsBinding?().first)
        try session.shiftClick(CGPoint(x: region.boundingRect.midX, y: region.boundingRect.midY))
        session.tool(1)
        try session.shiftClick(CGPoint(x: 60, y: 40))
        session.controller.perform(NSSelectorFromString("groupTapped"))
        session.tool(0)
        let center = CGPoint(x: region.boundingRect.midX, y: region.boundingRect.midY)
        try session.drag(from: center, to: CGPoint(x: center.x, y: center.y + 10))
        #expect(hole(drawing.id) == CGPoint(x: start.x + 40, y: start.y + 10), "A group move carries the hole")
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
        let region = try XCTUnwrap(canvas.regionsBinding?().first)
        session.tool(1)
        try session.drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 40))
        let drawing = try XCTUnwrap(canvas.annotationsBinding?().first)

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

        // Partial (brush) erasing is stored on the drawing, from now on.
        session.tool(1)
        try session.drag(from: CGPoint(x: 60, y: 60), to: CGPoint(x: 100, y: 90))
        let target = try XCTUnwrap(canvas.annotationsBinding?().last)
        session.tool(2)
        session.eraserMode(0)
        try session.drag(from: CGPoint(x: 50, y: 75), to: CGPoint(x: 110, y: 75))
        let rubbed = try #require(canvas.annotationsBinding?().first { $0.id == target.id })
        #expect(rubbed.erasures.count == 1 && abs((rubbed.erasures.first?.from ?? 0) - 2) < 0.01)
        session.controller.perform(NSSelectorFromString("undoTapped"))
        #expect(canvas.annotationsBinding?().first { $0.id == target.id }?.erasures.isEmpty == true, "One rub is one undo")
        session.controller.perform(NSSelectorFromString("undoTapped")) // the new drawing

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
        let region = try XCTUnwrap(canvas.regionsBinding?().first)
        let center = CGPoint(x: region.boundingRect.midX, y: region.boundingRect.midY)
        session.tool(1)
        try session.drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 40))
        let drawing = try XCTUnwrap(canvas.annotationsBinding?().first)
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
        let moved = try XCTUnwrap(canvas.regionsBinding?().first).boundingRect
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
        let text = try XCTUnwrap(canvas.annotationsBinding?().last)
        #expect(text.kind == .text && text.text == "안녕")
        #expect(abs(text.bounds.maxY - 120) < 0.01, "The click point is the text's top-left")
        session.controller.replaceText(of: text.id, with: "안녕하세요")
        let longer = try XCTUnwrap(canvas.annotationsBinding?().last)
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
        let region = try XCTUnwrap(canvas.regionsBinding?().first)
        try await session.seek(2)
        let center = CGPoint(x: region.boundingRect.midX, y: region.boundingRect.midY)
        try session.drag(from: center, to: CGPoint(x: center.x + 30, y: center.y))
        session.tool(1)
        try session.drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 40))
        // A bound native video is now saved as v3. Test executables have no app
        // Bundle Info producer version, so supply only this test API's version.
        let data = try session.controller.projectData(producerVersion: "test.groups")
        let videoProject = try VideoProjectFile.decode(data)
        #expect(videoProject.payload.version == 3)
        let project = videoProject.edits
        #expect(project.regions.count == 1 && project.drawings.count == 1)
        #expect(project.regions[0].effect.keyframes.map(\.time) == [0, 2])
        #expect(project.regions[0].shape.boundingRect.maxX <= 1.0001, "Geometry is normalized")

        let reopened = MainWindowController()
        reopened.showWindow(nil)
        defer { reopened.close() }
        let container = try #require(reopened.window?.contentViewController as? MainContainerViewController)
        reopened.window?.setContentSize(NSSize(width: 900, height: 600))
        reopened.openVideoProject(videoProject, media: URL(fileURLWithPath: project.mediaPath))
        try await waitUntil { container.canvas.regionsBinding?().count == 1 }
        let restored = try XCTUnwrap(container.canvas.regionsBinding?().first)
        let effect = try #require(container.canvas.effectForID?(restored.id))
        #expect(effect.keyframes.map(\.time) == [0, 2])
        let sx = container.canvas.bounds.width / canvas.bounds.width
        #expect(abs(restored.boundingRect.width - region.boundingRect.width * sx) < 0.5, "Scaled to the new window")
        #expect(container.canvas.annotationsBinding?().count == 1)
        // Widths survive a round trip through a non-square canvas exactly (no growth per save).
        let savedWidth = try #require(canvas.annotationsBinding?().first?.lineWidth)
        let reopenedWidth = try #require(container.canvas.annotationsBinding?().first?.lineWidth)
        let widthScale = DrawingAnnotation.widthScale(sx: container.canvas.bounds.width / canvas.bounds.width,
                                                      sy: container.canvas.bounds.height / canvas.bounds.height)
        #expect(abs(reopenedWidth - savedWidth * widthScale) < 0.0001)
        let twiceVideo = try VideoProjectFile.decode(reopened.projectData(producerVersion: "test.groups"))
        #expect(twiceVideo.timeline == videoProject.timeline)
        #expect(twiceVideo.sourceSHA256 == videoProject.sourceSHA256)
        let twice = twiceVideo.edits
        #expect(abs(twice.drawings[0].lineWidth - project.drawings[0].lineWidth) < 1e-9)

        let currentJSON = try #require(String(data: data, encoding: .utf8))
        #expect(currentJSON.contains("\"version\":3"))
        let unsupportedCurrent = Data(currentJSON.replacingOccurrences(of: "\"version\":3", with: "\"version\":99").utf8)
        #expect(throws: ProjectFile.ProjectError.self) { _ = try VideoProjectFile.decode(unsupportedCurrent) }

        // Keep legacy encode/decode/open and every previous rejection oracle.
        // A v3 editable projection is NOT a claim that the v1 decoder reads v3.
        let legacyData = try project.encoded()
        let legacy = try ProjectFile.decode(legacyData)
        let checkedLegacy = try VideoProjectFile.decodeLegacy(legacyData)
        #expect(legacy == project && checkedLegacy == project)
        let legacyReopened = MainWindowController()
        legacyReopened.showWindow(nil)
        defer { legacyReopened.close() }
        let legacyContainer = try #require(legacyReopened.window?.contentViewController as? MainContainerViewController)
        legacyReopened.openProject(legacy, media: URL(fileURLWithPath: legacy.mediaPath))
        try await waitUntil { legacyContainer.canvas.regionsBinding?().count == 1 }
        let legacyRestored = try XCTUnwrap(legacyContainer.canvas.regionsBinding?().first)
        let legacyEffect = try #require(legacyContainer.canvas.effectForID?(legacyRestored.id))
        #expect(legacyEffect.keyframes.map(\.time) == [0, 2])
        #expect(legacyContainer.canvas.annotationsBinding?().count == 1)
        let promoted = try VideoProjectFile.decode(legacyReopened.projectData(producerVersion: "test.groups"))
        #expect(promoted.edits.regions[0].shape.id == project.regions[0].shape.id)
        #expect(promoted.edits.regions[0].effect.timeRange == project.regions[0].effect.timeRange)
        #expect(promoted.edits.regions[0].effect.keyframes.map(\.time) == [0, 2])
        #expect(promoted.edits.drawings[0].id == project.drawings[0].id)
        #expect(promoted.edits.drawings[0].timeRange == project.drawings[0].timeRange)
        #expect(abs(promoted.edits.drawings[0].lineWidth - project.drawings[0].lineWidth) < 1e-9)

        var json = try #require(String(data: legacyData, encoding: .utf8))
        #expect(json.contains("\"version\" : 1"))
        json = json.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 99")
        #expect(throws: ProjectFile.ProjectError.self) { try ProjectFile.decode(Data(json.utf8)) }
        var wild = project
        wild.drawings[0].points[0] = CGPoint(x: 1e9, y: 0)
        #expect(throws: ProjectFile.ProjectError.self) { try ProjectFile.decode(try wild.encoded()) }
        #expect(throws: ProjectFile.ProjectError.self) { try ProjectFile.decode(Data("{}".utf8)) }
        var duplicate = project
        duplicate.regions.append(project.regions[0])
        #expect(throws: ProjectFile.ProjectError.self) { try ProjectFile.decode(try duplicate.encoded()) }
        var negative = project
        negative.regions[0].shape = .rectangle(id: UUID(), origin: .zero, size: CGSize(width: -1, height: 0.2))
        #expect(throws: ProjectFile.ProjectError.self) { try ProjectFile.decode(try negative.encoded()) }

        // Next to the media, a project stores only the file name (no user folders).
        let media = URL(fileURLWithPath: project.mediaPath)
        let beside = media.deletingLastPathComponent().appendingPathComponent("edit.bluraction")
        let localCurrent = try VideoProjectFile.decode(session.controller.projectData(projectURL: beside, producerVersion: "test.groups"))
        let local = localCurrent.edits
        #expect(local.mediaPath == media.lastPathComponent)
        #expect(localCurrent.timeline == videoProject.timeline)
        #expect(local.mediaURL(relativeTo: beside).standardizedFileURL == media.standardizedFileURL)
        var sneaky = local
        sneaky.mediaPath = "../../secret.mp4"
        #expect(sneaky.mediaURL(relativeTo: beside).deletingLastPathComponent().standardizedFileURL
                == beside.deletingLastPathComponent().standardizedFileURL, "Relative names never leave the folder")
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
