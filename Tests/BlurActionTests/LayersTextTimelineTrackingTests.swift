import Testing
import AppKit
import AVFoundation
@testable import BlurAction

/// 0.6: partial erasing of blur regions, layers, text options, group resize/duplicate,
/// timeline editing, project templates and automatic tracking.
@Suite(.serialized)
@MainActor
final class LayersTextTimelineTrackingTests {
    // MARK: Region partial erase

    @Test
    func testRegionHolesAreTimedAndFollowTheRegion() throws {
        let helper = RenderingCoreTests()
        let source = helper.checker()
        let rect = CGRect(x: 20, y: 20, width: 80, height: 50)
        let base = RegionShape.rectangle(id: UUID(), origin: rect.origin, size: rect.size)
        var effect = RegionEffect(blurRadius: 0, featherRadius: 0)
        effect.style = .solid
        effect.color = RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
        effect.erasures = [EraseStroke(points: [CGPoint(x: 10, y: 45), CGPoint(x: 110, y: 45)], width: 10, from: 2)]
        func pixel(_ image: CIImage, _ x: CGFloat, _ y: CGFloat) -> [UInt8] {
            helper.pixels(image.cropped(to: CGRect(x: x, y: y, width: 1, height: 1)))
        }
        func render(_ pair: RegionEditing.Pair, _ time: Double) throws -> CIImage {
            try BlurRenderer.render(image: source, pairs: [pair], canvasSize: helper.size, time: time)
        }
        #expect(pixel(try render((base, effect), 1), 60, 45)[0] >= 253, "Before the erase time the cover is whole")
        let during = try render((base, effect), 3)
        #expect(pixel(during, 60, 45) == pixel(source, 60, 45), "The rubbed band shows the video")
        #expect(pixel(during, 60, 30)[0] >= 253)

        // A static move carries the hole; so does recorded motion.
        let moved = RegionEditing.updating([base.replacing(rect: rect.offsetBy(dx: 0, dy: 20))], in: [(base, effect)], time: nil, recording: false)
        #expect(moved[0].effect.erasures.first?.points.first == CGPoint(x: 10, y: 65))
        let later = RegionEditing.updating([base.replacing(rect: rect.offsetBy(dx: 0, dy: 20))], in: [(base, effect)], time: 4, recording: true)
        let shown = try render(later[0], 5)
        #expect(pixel(shown, 60, 65) == pixel(source, 60, 65) && pixel(shown, 60, 50)[0] >= 253)
    }

    @Test
    func testBrushTargetsLockedLayersAndClearAll() async throws {
        let session = try await ImageSession.open()
        defer { session.close() }
        let canvas = session.canvas
        let controller = session.controller
        controller.perform(NSSelectorFromString("addRegionTapped"))
        let region = try XCTUnwrap(canvas.regionsBinding?().first)
        let r = region.boundingRect
        session.tool(1)
        try session.drag(from: CGPoint(x: r.minX - 10, y: r.midY - 10), to: CGPoint(x: r.maxX + 10, y: r.midY + 10))
        let drawing = try XCTUnwrap(canvas.annotationsBinding?().first)
        func holes() -> (Int, Int) {
            (canvas.effectForID?(region.id)?.erasures.count ?? -1, canvas.annotationsBinding?().first?.erasures.count ?? -1)
        }
        session.tool(2)
        session.eraserMode(0)
        let target = try #require(session.descendants.compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains("그림만") })
        func rub() throws { try session.drag(from: CGPoint(x: r.minX, y: r.midY), to: CGPoint(x: r.maxX, y: r.midY)) }
        try rub()
        #expect(holes() == (1, 1), "Both: blur region and drawing")
        target.selectItem(withTitle: "그림만"); _ = target.sendAction(target.action, to: target.target)
        try rub()
        #expect(holes() == (1, 2))
        target.selectItem(withTitle: "블러 영역만"); _ = target.sendAction(target.action, to: target.target)
        try rub()
        #expect(holes() == (2, 2))

        controller.setLayerLocked(region.id, true)
        try rub()
        #expect(holes() == (2, 2), "A locked layer is not erased")
        controller.clearItems(.all)
        #expect(canvas.regionsBinding?().map(\.id) == [region.id] && canvas.annotationsBinding?().isEmpty == true,
                "Clear all keeps locked layers")
        controller.perform(NSSelectorFromString("undoTapped"))
        #expect(canvas.annotationsBinding?().first?.id == drawing.id)
    }

    // MARK: Layers

    @Test
    func testLayerListNamesHideAndLock() async throws {
        let session = try await ImageSession.open()
        defer { session.close() }
        let canvas = session.canvas
        let controller = session.controller
        controller.perform(NSSelectorFromString("addRegionTapped"))
        let region = try XCTUnwrap(canvas.regionsBinding?().first)
        session.tool(1)
        try session.drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 50))
        let drawing = try XCTUnwrap(canvas.annotationsBinding?().first)
        #expect(controller.layerRows.map(\.id) == [drawing.id, region.id], "Top of the list is drawn on top")
        #expect(controller.layerName(of: region.id) == "블러 사각형 1")

        controller.renameLayer(region.id, to: "  얼굴  ")
        #expect(controller.layerName(of: region.id) == "얼굴")
        controller.renameLayer(region.id, to: " ")
        #expect(controller.layerName(of: region.id) == "블러 사각형 1", "Blank names return to automatic")

        canvas.selectAnnotation(id: drawing.id)
        controller.setLayerHidden(drawing.id, true)
        #expect(canvas.annotationsBinding?().isEmpty == true, "Hidden drawings leave the canvas")
        controller.perform(NSSelectorFromString("deleteSelectedTapped"))
        #expect(controller.layerRows.contains { $0.id == drawing.id }, "Delete does not reach a hidden drawing")
        controller.setLayerHidden(region.id, true)
        #expect(canvas.effectForID?(region.id)?.enabled == false)
        let export = try #require(session.descendants.compactMap { $0 as? NSButton }.first { $0.title == "내보내기" })
        #expect(!export.isEnabled, "Nothing visible left to export")
        controller.perform(NSSelectorFromString("undoTapped"))
        controller.perform(NSSelectorFromString("undoTapped"))
        #expect(canvas.annotationsBinding?().count == 1 && canvas.effectForID?(region.id)?.enabled == true)

        // Locked: clicks pass through and Delete is refused.
        session.tool(0)
        controller.setLayerLocked(region.id, true)
        canvas.resetInteraction()
        let center = CGPoint(x: region.boundingRect.midX, y: region.boundingRect.midY)
        try session.drag(from: center, to: CGPoint(x: center.x + 30, y: center.y))
        #expect(canvas.regionsBinding?().first?.boundingRect == region.boundingRect, "A locked region does not move")
        canvas.selectRegion(id: region.id)
        controller.perform(NSSelectorFromString("deleteSelectedTapped"))
        #expect(canvas.regionsBinding?().count == 1)
    }

    // MARK: Text

    @Test
    func testMultilineTextFontAndBackground() async throws {
        let one = DrawingAnnotation.text("가나다", at: .zero, fontSize: 20, color: .white)
        let two = DrawingAnnotation.text("가나다\n라마바사아", at: .zero, fontSize: 20, color: .white,
                                         background: RGBAColor(red: 0, green: 0, blue: 0, alpha: 1))
        #expect(abs(two.bounds.height - one.bounds.height * 2) < 0.01 && two.bounds.width > one.bounds.width)
        #expect(abs(two.textFontSize - 20) < 0.01)
        let edited = two.withText("짧게")
        #expect(abs(edited.bounds.maxY - two.bounds.maxY) < 0.01 && abs(edited.textFontSize - 20) < 0.01, "Top-left and size stay")

        let helper = RenderingCoreTests()
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(origin: .zero, size: helper.size))
        var placed = two
        placed.points = placed.points.map { CGPoint(x: $0.x + 10, y: $0.y + 10) }
        let out = try BlurRenderer.render(image: white, pairs: [], canvasSize: helper.size, time: nil, annotations: [placed])
        let corner = helper.pixels(out.cropped(to: CGRect(x: placed.bounds.minX + 1, y: placed.bounds.minY + 1, width: 1, height: 1)))
        #expect(corner[0] < 10, "The background box is drawn behind the text")

        let session = try await ImageSession.open()
        defer { session.close() }
        session.tool(1)
        session.mode(5)
        session.controller.addText("첫 줄\n둘째 줄", at: CGPoint(x: 20, y: 150))
        let text = try XCTUnwrap(session.canvas.annotationsBinding?().last)
        #expect(text.text == "첫 줄\n둘째 줄")
        let background = try #require(session.descendants.compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains("검정 배경") })
        background.selectItem(withTitle: "검정 배경"); _ = background.sendAction(background.action, to: background.target)
        let bold = try #require(session.descendants.compactMap { $0 as? NSButton }.first { $0.title == "굵게" })
        bold.state = .off; _ = bold.sendAction(bold.action, to: bold.target)
        let styled = try XCTUnwrap(session.canvas.annotationsBinding?().last)
        #expect(styled.textBackground == RGBAColor(red: 0, green: 0, blue: 0, alpha: 1) && !styled.bold)
        #expect(MainWindowController.cleanedText("  a \n\n b  ") == "a\n\nb")
    }

    // MARK: Groups

    @Test
    func testGroupResizeScalesMembersAndDuplicateCopiesGroup() async throws {
        let session = try await ImageSession.open()
        defer { session.close() }
        let canvas = session.canvas
        session.controller.perform(NSSelectorFromString("addRegionTapped"))
        let region = try XCTUnwrap(canvas.regionsBinding?().first)
        let r = region.boundingRect
        session.tool(1)
        try session.drag(from: CGPoint(x: r.maxX + 10, y: r.minY), to: CGPoint(x: r.maxX + 30, y: r.minY + 20))
        session.tool(0)
        try session.shiftClick(CGPoint(x: r.midX, y: r.midY))
        session.tool(1)
        try session.shiftClick(CGPoint(x: r.maxX + 10, y: r.minY + 10))
        session.controller.perform(NSSelectorFromString("groupTapped"))
        let before = try XCTUnwrap(canvas.annotationsBinding?().first).bounds

        // Drag the region's right edge handle: width doubles, the drawing scales about the region.
        session.tool(0)
        canvas.selectRegion(id: region.id)
        try session.drag(from: CGPoint(x: r.maxX, y: r.midY), to: CGPoint(x: r.maxX + r.width, y: r.midY))
        let after = try XCTUnwrap(canvas.annotationsBinding?().first).bounds
        #expect(abs(after.minX - (r.minX + (before.minX - r.minX) * 2)) < 0.5, "Scaled about the edited box")
        #expect(abs(after.width - before.width * 2) < 0.5 && abs(after.height - before.height) < 0.5)

        session.controller.perform(NSSelectorFromString("duplicateSelectedTapped"))
        let regions = canvas.regionsBinding?() ?? [], drawings = canvas.annotationsBinding?() ?? []
        #expect(regions.count == 2 && drawings.count == 2, "The whole group is copied")
        let newGroup = try #require(canvas.effectForID?(regions[1].id)?.groupID)
        #expect(newGroup != canvas.effectForID?(regions[0].id)?.groupID && drawings[1].groupID == newGroup)
    }

    // MARK: Timeline

    @Test
    func testTimelineRetimeRangeEdgesAndKeyNavigation() async throws {
        let session = try await VideoSession.open()
        defer { session.close() }
        let canvas = session.container.canvas
        let controller = session.controller
        controller.perform(NSSelectorFromString("addRegionTapped"))
        let region = try XCTUnwrap(canvas.regionsBinding?().first)
        try await session.seek(2)
        let c = CGPoint(x: region.boundingRect.midX, y: region.boundingRect.midY)
        try session.drag(from: c, to: CGPoint(x: c.x + 20, y: c.y))
        let slider = session.container.slider
        #expect(slider.markers == [0, 2])
        #expect(slider.rangeBand == 0...6)

        controller.retimeKeyframe(1, to: 3)
        #expect(canvas.effectForID?(region.id)?.keyframes.map(\.time) == [0, 3])
        controller.retimeKeyframe(1, to: -5)
        #expect((canvas.effectForID?(region.id)?.keyframes.last?.time ?? 0) > 0, "Kept after its neighbour")
        controller.retimeKeyframe(1, to: 3)
        controller.moveRangeEdge(start: true, to: 1)
        #expect(canvas.effectForID?(region.id)?.timeRange == 1...6)
        controller.moveRangeEdge(start: false, to: 0.5)
        #expect(canvas.effectForID?(region.id)?.timeRange == 1...6, "An end before the start is refused")

        try await session.seek(0.5)
        controller.perform(NSSelectorFromString("nextKeyframe"))
        try await waitUntil { abs(canvas.currentVideoTime - 3) < 0.01 }
        controller.perform(NSSelectorFromString("previousKeyframe"))
        try await waitUntil { abs(canvas.currentVideoTime) < 0.01 }

        // Dragging a tick in the strip under the timeline retimes it through the callback.
        var moved: (Int, Double)?
        let strip = TrackingSlider(frame: CGRect(x: 0, y: 0, width: 300, height: 30))
        strip.minValue = 0; strip.maxValue = 6; strip.markers = [0, 3]
        strip.markerMoved = { moved = ($0, $1) }
        let y = 4.0 // window coordinates (bottom-left): the strip along the slider's bottom edge
        let x3 = try #require(strip.x(forTime: 3)), x4 = try #require(strip.x(forTime: 4))
        func event(_ type: NSEvent.EventType, _ x: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
                                            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        strip.mouseDown(with: try event(.leftMouseDown, x3 + 2))
        strip.mouseUp(with: try event(.leftMouseUp, x3 + 2))
        #expect(moved == nil, "A click without a drag changes nothing")
        strip.mouseDown(with: try event(.leftMouseDown, x3))
        strip.mouseDragged(with: try event(.leftMouseDragged, x4))
        strip.mouseUp(with: try event(.leftMouseUp, x4))
        #expect(moved?.0 == 1 && abs((moved?.1 ?? 0) - 4) < 0.05)
    }

    // MARK: Templates

    @Test
    func testImportProjectItemsAsNewItems() async throws {
        let source = try await ImageSession.open()
        defer { source.close() }
        source.controller.perform(NSSelectorFromString("addRegionTapped"))
        source.tool(1)
        try source.drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 50))
        let project = try ProjectFile.decode(try source.controller.projectData())

        let target = try await ImageSession.open(split: true)
        defer { target.close() }
        target.controller.importProjectItems(project)
        target.controller.importProjectItems(project)
        let regions = target.canvas.regionsBinding?() ?? [], drawings = target.canvas.annotationsBinding?() ?? []
        #expect(regions.count == 2 && drawings.count == 2)
        #expect(Set(regions.map(\.id)).count == 2 && !regions.contains { $0.id == project.regions[0].shape.id }, "New IDs")
        let scale = target.canvas.bounds.width / source.canvas.bounds.width
        #expect(abs(regions[0].boundingRect.width - (source.canvas.regionsBinding?().first?.boundingRect.width ?? 0) * scale) < 0.5)
        target.controller.perform(NSSelectorFromString("undoTapped"))
        #expect(target.canvas.regionsBinding?().count == 1, "One import is one undo step")
    }

    @Test
    func testHolesOnATinyRecordedRegionStaySmallAndReopen() async throws {
        let session = try await VideoSession.open()
        defer { session.close() }
        let canvas = session.container.canvas
        session.controller.perform(NSSelectorFromString("addRegionTapped"))
        let region = try XCTUnwrap(canvas.regionsBinding?().first)
        try await session.seek(2)
        // Record a nearly collapsed size at 2 s, then rub across it with a wide brush.
        let tiny = CGRect(x: region.boundingRect.midX, y: region.boundingRect.midY, width: 1.5, height: 1.5)
        canvas.regionsUpdate?([region.replacing(rect: tiny)])
        session.controller.applyEraserStroke([CGPoint(x: 0, y: tiny.midY), CGPoint(x: canvas.bounds.width, y: tiny.midY)], width: 40)
        #expect(canvas.effectForID?(region.id)?.erasures.count == 1)
        let current = try VideoProjectFile.decode(session.controller.projectData(producerVersion: "test.layers"))
        #expect(current.payload.version == 3)
        let project = current.edits
        #expect(project.regions[0].effect.erasures.count == 1, "The saved project reopens")
        let legacy = try ProjectFile.decode(project.encoded())
        #expect(legacy.regions[0].effect.erasures == project.regions[0].effect.erasures,
                "The v1 edit DTO still preserves the same eraser geometry and timing")
    }

    @Test
    func testProjectsSavedBeforeNewFieldsStillOpen() throws {
        var drawing = DrawingAnnotation(kind: .text, points: [.zero, CGPoint(x: 0.2, y: 0.1)], lineWidth: 0.01)
        drawing.text = "옛 프로젝트"
        let region = ProjectFile.Region(shape: .rectangle(id: UUID(), origin: CGPoint(x: 0.1, y: 0.1), size: CGSize(width: 0.3, height: 0.2)),
                                        effect: RegionEffect(blurRadius: 25, featherRadius: 12))
        let data = try ProjectFile(mediaPath: "old.mp4", regions: [region], drawings: [drawing]).encoded()
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let newKeys = ["erasures", "name", "locked", "hidden", "fontName", "bold", "textBackground"]
        json["regions"] = (json["regions"] as? [[String: Any]])?.map { item in
            var item = item
            item["effect"] = (item["effect"] as? [String: Any])?.filter { !newKeys.contains($0.key) }
            return item
        }
        json["drawings"] = (json["drawings"] as? [[String: Any]])?.map { $0.filter { !newKeys.contains($0.key) } }
        let old = try JSONSerialization.data(withJSONObject: json)
        #expect(!String(decoding: old, as: UTF8.self).contains("erasures"))
        let project = try ProjectFile.decode(old)
        #expect(project.drawings[0].text == "옛 프로젝트" && project.drawings[0].bold && !project.drawings[0].locked)
        #expect(project.regions[0].effect.erasures.isEmpty && project.regions[0].effect.name == nil)
    }

    // MARK: Automatic tracking

    @Test
    func testVisionTracksAMovingTargetAndRecordsIt() async throws {
        let fixtures = VideoExportTests()
        let directory = try fixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("moving.mp4")
        // A 48×48 textured patch moving right at 60 px/s over a dark frame (320×180).
        try fixtures.ffmpeg(["-f", "lavfi", "-i", "color=c=0x202020:s=320x180:d=3:r=30",
                             "-f", "lavfi", "-i", "testsrc2=s=48x48:d=3:r=30",
                             "-filter_complex", "[0][1]overlay=x='20+t*60':y=66", "-c:v", "libx264", "-pix_fmt", "yuv420p", input.path])
        // Normalized, bottom-left: x 20/320, y (180-66-48)/180.
        let box = CGRect(x: 20.0 / 320, y: 66.0 / 180, width: 48.0 / 320, height: 48.0 / 180)
        let outcome = try await ObjectTracker.track(url: input, from: 0, until: 2.5, box: box, cancellation: .init()) { _ in }
        let at2 = try #require(outcome.samples.min { abs($0.time - 2) < abs($1.time - 2) })
        #expect(abs(at2.box.midX * 320 - (20 + 120 + 24)) < 12, "Tracked x \(at2.box.midX * 320)")
        #expect(abs(at2.box.midY * 180 - 90) < 12)

        let cancelled = ObjectTracker.Cancellation()
        cancelled.cancel()
        #expect(try await ObjectTracker.track(url: input, from: 0, until: 2.5, box: box, cancellation: cancelled) { _ in }.cancelled)
        await #expect(throws: ObjectTracker.TrackError.self) {
            try await ObjectTracker.track(url: input, from: 0, until: 1, box: CGRect(x: 0, y: 0, width: 0.001, height: 0.001), cancellation: .init()) { _ in }
        }

        // Through the app: select an area on the target at 0 s and track it.
        let controller = MainWindowController()
        controller.showWindow(nil)
        defer { controller.close() }
        let container = try #require(controller.window?.contentViewController as? MainContainerViewController)
        controller.load(url: input)
        try await waitUntil { container.slider.isEnabled && container.playerLayer.player?.currentItem?.status == .readyToPlay }
        container.view.layoutSubtreeIfNeeded()
        let size = container.canvas.bounds.size
        let rect = CGRect(x: box.minX * size.width, y: box.minY * size.height, width: box.width * size.width, height: box.height * size.height)
        container.canvas.regionsUpdate?([.rectangle(id: UUID(), origin: rect.origin, size: rect.size)])
        let region = try XCTUnwrap(container.canvas.regionsBinding?().first)
        container.canvas.selectRegion(id: region.id)
        controller.perform(NSSelectorFromString("autoTrackTapped"))
        try await waitUntil { (container.canvas.effectForID?(region.id)?.keyframes.count ?? 0) > 30 }
        let effect = try #require(container.canvas.effectForID?(region.id))
        let shown = RegionEditing.displayed((region, effect), at: 2).boundingRect
        #expect(abs(shown.midX / size.width * 320 - 164) < 14, "Region follows the target: \(shown.midX / size.width * 320)")
        controller.perform(NSSelectorFromString("undoTapped"))
        #expect(container.canvas.effectForID?(region.id)?.keyframes.isEmpty == true, "Tracking is one undo step")
    }
}
