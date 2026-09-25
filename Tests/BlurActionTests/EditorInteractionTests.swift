import Testing
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import BlurAction

@Suite(.serialized)
final class EditorInteractionTests {
    @Test
    func testEffectsFollowIdentityWhenDeletingFirstRegion() {
        let first = RegionShape.rectangle(id: UUID(), origin: .zero, size: CGSize(width: 20, height: 20))
        let second = RegionShape.ellipse(id: UUID(), origin: CGPoint(x: 40, y: 30), size: CGSize(width: 20, height: 20))
        var effect = RegionEffect.alwaysOn(); effect.blurRadius = 61
        let result = RegionEditing.updating([second], in: [(first, .alwaysOn()), (second, effect)], time: nil, recording: false)
        #expect(result.count == 1)
        #expect(result[0].effect.blurRadius == 61)
    }

    @Test
    func testTrackingPreservesBaseAndRescalesAllFrames() {
        let base = RegionShape.rectangle(id: UUID(), origin: CGPoint(x: 10, y: 10), size: CGSize(width: 20, height: 20))
        let end = base.replacing(rect: CGRect(x: 60, y: 40, width: 20, height: 20))
        let pairs = RegionEditing.updating([end], in: [(base, .alwaysOn())], time: 2, recording: true)
        #expect(pairs[0].shape == base)
        #expect(RegionEditing.displayed(pairs[0], at: 0) == base)
        #expect(RegionEditing.displayed(pairs[0], at: 2) == end)
        let resized = RegionEditing.scaled(pairs, from: CGSize(width: 100, height: 100), to: CGSize(width: 200, height: 300))
        #expect(resized[0].shape.boundingRect == CGRect(x: 20, y: 30, width: 40, height: 60))
        #expect(RegionEditing.displayed(resized[0], at: 2).boundingRect == CGRect(x: 120, y: 120, width: 40, height: 60))
    }

    @Test
    func testWaitingBetweenDragsStaysStillAndPolygonVertexEditSurvives() {
        let a = RegionShape.rectangle(id: UUID(), origin: CGPoint(x: 5, y: 5), size: CGSize(width: 20, height: 20))
        let b = a.replacing(rect: CGRect(x: 55, y: 5, width: 20, height: 20))
        let c = a.replacing(rect: CGRect(x: 100, y: 5, width: 20, height: 20))
        let initial: [RegionEditing.Pair] = [(a, .alwaysOn())]
        let first = RegionEditing.updating([b], in: initial, time: 6, recording: true, anchorTime: 5, anchorPairs: initial)
        #expect(RegionEditing.displayed(first[0], at: 4) == a)
        #expect(RegionEditing.displayed(first[0], at: 5) == a)
        #expect(RegionEditing.displayed(first[0], at: 6) == b)
        let second = RegionEditing.updating([c], in: first, time: 9, recording: true, anchorTime: 8, anchorPairs: first)
        #expect(RegionEditing.displayed(second[0], at: 7) == b)
        #expect(RegionEditing.displayed(second[0], at: 8) == b)
        #expect(RegionEditing.displayed(second[0], at: 9) == c)
        let polygon = RegionShape.polygon(id: UUID(), points: [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 20)])
        var effect = RegionEffect.alwaysOn()
        effect.keyframes = [RegionKeyframe(time: 0, rect: polygon.boundingRect)]
        let edited = RegionShape.polygon(id: polygon.id, points: [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 0), CGPoint(x: 12, y: 12), CGPoint(x: 0, y: 20)])
        let result = RegionEditing.updating([edited], in: [(polygon, effect)], time: 1, recording: false)
        #expect(RegionEditing.displayed(result[0], at: 1) == edited)
    }

    @MainActor
    @Test
    func testImageOpensOnceResizesAndUndoRedoSurvives() async throws {
        _ = NSApplication.shared
        let url = try makeImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = MainWindowController()
        controller.showWindow(nil)
        defer { controller.close() }
        controller.load(url: url)
        let root = try #require(controller.window?.contentView)
        let canvas = try #require(descendants(root).compactMap { $0 as? VideoCanvasView }.first)
        for _ in 0..<100 where !canvas.isEditable { try await Task.sleep(nanoseconds: 10_000_000) }
        root.layoutSubtreeIfNeeded()
        #expect(canvas.bounds.width > 200 && canvas.bounds.height > 100)
        #expect(canvas.isEditable, "First open must complete without a second open or manual resize")
        #expect(abs((canvas.bounds.width / canvas.bounds.height) - (2)) <= 0.01)
        let imageLayers = canvas.superview?.layer?.sublayers?.compactMap { $0 as? LiveBlurCompositor } ?? []
        #expect(imageLayers.first?.contents != nil, "First open must render actual image pixels")
        let exportButton = try #require(descendants(root).compactMap { $0 as? NSButton }.first { $0.title == "내보내기" })
        #expect(!exportButton.isEnabled, "An unchanged source must not be exported as blurred")
        controller.perform(NSSelectorFromString("addRegionTapped"))
        #expect(canvas.regionsBinding?().count == 1)
        #expect(exportButton.isEnabled)
        let initial = try #require(canvas.regionsBinding?().first?.boundingRect)
        let size = canvas.bounds.size
        controller.window?.setContentSize(CGSize(width: 760, height: 500))
        root.layoutSubtreeIfNeeded()
        #expect(abs(root.bounds.width - 760) < 1)
        #expect(abs(root.bounds.height - 500) < 1)
        #expect(canvas.bounds.width > size.width, "Enlarging a media-fitted window must enlarge the preview")
        #expect(abs(canvas.bounds.width / canvas.bounds.height - 2) < 0.01)
        let resized = try #require(canvas.regionsBinding?().first?.boundingRect)
        #expect(abs((resized.minX / canvas.bounds.width) - (initial.minX / size.width)) <= 0.001)
        #expect(abs((resized.width / canvas.bounds.width) - (initial.width / size.width)) <= 0.001)
        controller.perform(NSSelectorFromString("undoTapped"))
        #expect(canvas.regionsBinding?().count == 0, "First addition must be undoable")
        #expect(!exportButton.isEnabled)
        controller.perform(NSSelectorFromString("redoTapped"))
        #expect(canvas.regionsBinding?().count == 1, "Restoring state must not discard redo")
        controller.load(url: url)
        for _ in 0..<100 where !canvas.isEditable { try await Task.sleep(nanoseconds: 10_000_000) }
        controller.perform(NSSelectorFromString("undoTapped"))
        #expect(canvas.regionsBinding?().count == 0, "History must never cross documents")
    }

    @MainActor
    @Test(arguments: [(960, 540), (540, 960)])
    func testMediaFitsWindowAndKeepsAspectOnResize(dimensions: (Int, Int)) async throws {
        _ = NSApplication.shared
        let url = try makeImage(width: dimensions.0, height: dimensions.1)
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = MainWindowController()
        controller.showWindow(nil)
        defer { controller.close() }
        controller.load(url: url)
        let window = try #require(controller.window)
        let container = try #require(window.contentViewController as? MainContainerViewController)
        let canvas = container.canvas
        for _ in 0..<100 where !canvas.isEditable { try await Task.sleep(nanoseconds: 10_000_000) }
        for contentSize in [window.contentView?.bounds.size ?? .zero, CGSize(width: 800, height: 500)] {
            window.setContentSize(contentSize)
            container.refreshMediaLayout()
            let media = container.aspectFitVideo.frame
            let available = container.videoContainer.bounds
            #expect(media.minX >= -0.5 && media.minY >= -0.5)
            #expect(media.maxX <= available.maxX + 0.5 && media.maxY <= available.maxY + 0.5)
            #expect(abs(media.width / media.height - CGFloat(dimensions.0) / CGFloat(dimensions.1)) < 0.01)
            #expect(canvas.bounds.size == media.size)
            let mediaInWindow = container.aspectFitVideo.convert(container.aspectFitVideo.bounds, to: nil)
            let visibleContent = window.contentLayoutRect
            #expect(mediaInWindow.minY >= visibleContent.minY - 0.5 &&
                    mediaInWindow.maxY <= visibleContent.maxY + 0.5,
                    "The full media preview must stay below the titlebar and toolbar")
        }
    }

    @MainActor
    @Test
    func testCanvasCreationDragAndOneStepUndo() async throws {
        _ = NSApplication.shared
        let url = try makeImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = MainWindowController()
        controller.showWindow(nil)
        defer { controller.close() }
        controller.load(url: url)
        let root = try #require(controller.window?.contentView)
        let canvas = try #require(descendants(root).compactMap { $0 as? VideoCanvasView }.first)
        for _ in 0..<100 where !canvas.isEditable { try await Task.sleep(nanoseconds: 10_000_000) }
        root.layoutSubtreeIfNeeded()
        #expect(canvas.bounds.width > 200 && canvas.bounds.height > 100)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: controller.window!.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        canvas.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 30, y: 30)))
        canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 100, y: 100)))
        canvas.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 100, y: 100)))
        #expect(canvas.regionsBinding?().count == 1)
        canvas.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 60, y: 60)))
        canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 80, y: 70)))
        canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 90, y: 80)))
        canvas.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 90, y: 80)))
        #expect(canvas.regionsBinding?().first?.boundingRect.origin == CGPoint(x: 60, y: 50))
        controller.perform(NSSelectorFromString("undoTapped"))
        #expect(canvas.regionsBinding?().first?.boundingRect.origin == CGPoint(x: 30, y: 30))
        controller.perform(NSSelectorFromString("undoTapped"))
        #expect(canvas.regionsBinding?().count == 0)
    }

    @MainActor
    @Test
    func testFourDrawingModesShiftAndPolygonBoundaryMovement() async throws {
        _ = NSApplication.shared
        let url = try makeImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = MainWindowController(); controller.showWindow(nil)
        defer { controller.close() }
        controller.load(url: url)
        let root = try #require(controller.window?.contentView)
        let canvas = try #require(descendants(root).compactMap { $0 as? VideoCanvasView }.first)
        let segment = try #require(descendants(root).compactMap { $0 as? NSSegmentedControl }.first(where: { $0.segmentCount == 4 }))
        for _ in 0..<100 where !canvas.isEditable { try await Task.sleep(nanoseconds: 10_000_000) }
        controller.window?.setContentSize(CGSize(width: 1180, height: 700))
        root.layoutSubtreeIfNeeded()
        func mode(_ index: Int) {
            segment.selectedSegment = index
            _ = segment.sendAction(segment.action, to: segment.target)
        }
        func event(_ type: NSEvent.EventType, _ x: Double, _ y: Double, shift: Bool = false) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(CGPoint(x: x, y: y), to: nil),
                modifierFlags: shift ? [.shift] : [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: controller.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        mode(0)
        canvas.mouseDown(with: try event(.leftMouseDown, 30, 30))
        canvas.mouseDragged(with: try event(.leftMouseDragged, 100, 130, shift: true))
        canvas.mouseUp(with: try event(.leftMouseUp, 100, 130, shift: true))
        #expect(canvas.regionsBinding?().first?.boundingRect.size == CGSize(width: 70, height: 70))
        mode(1)
        canvas.mouseDown(with: try event(.leftMouseDown, 150, 30))
        canvas.mouseDragged(with: try event(.leftMouseDragged, 220, 130, shift: true))
        canvas.mouseUp(with: try event(.leftMouseUp, 220, 130, shift: true))
        let ellipse = try #require(canvas.regionsBinding?().last)
        if case .ellipse = ellipse {} else { Issue.record("Ellipse mode must create an ellipse") }
        #expect(ellipse.boundingRect.size == CGSize(width: 70, height: 70))
        mode(2)
        for p in [CGPoint(x: 300, y: 30), CGPoint(x: 360, y: 30), CGPoint(x: 330, y: 100), CGPoint(x: 300, y: 30)] {
            canvas.mouseDown(with: try event(.leftMouseDown, p.x, p.y))
            canvas.mouseUp(with: try event(.leftMouseUp, p.x, p.y))
        }
        #expect(canvas.regionsBinding?().count == 3)
        mode(3)
        canvas.mouseDown(with: try event(.leftMouseDown, 450, 30))
        canvas.mouseDragged(with: try event(.leftMouseDragged, 510, 30))
        canvas.mouseDragged(with: try event(.leftMouseDragged, 480, 100))
        canvas.mouseUp(with: try event(.leftMouseUp, 450, 30))
        #expect(canvas.regionsBinding?().count == 4)
        let polygon = try #require(canvas.regionsBinding?().last)
        let edge = polygon.replacing(rect: CGRect(x: canvas.bounds.width - polygon.boundingRect.width,
                                                 y: 30, width: polygon.boundingRect.width, height: polygon.boundingRect.height))
        canvas.regionsUpdate?([edge]); canvas.selectRegion(id: edge.id)
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: controller.window!.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
        canvas.keyDown(with: key)
        #expect(canvas.regionsBinding?().first == edge, "Boundary arrows must not deform polygon vertices")
    }

    @MainActor
    @Test
    func testAnnotationToolsCreateUndoRedoAndEnableExportWithoutBlurRegions() async throws {
        _ = NSApplication.shared
        let url = try makeImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = MainWindowController(); controller.showWindow(nil)
        defer { controller.close() }
        controller.load(url: url)
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let canvas = try #require(descendants(root).compactMap { $0 as? VideoCanvasView }.first)
        for _ in 0..<100 where !canvas.isEditable { try await Task.sleep(nanoseconds: 10_000_000) }
        root.layoutSubtreeIfNeeded()
        let segments = descendants(root).compactMap { $0 as? NSSegmentedControl }
        let tools = try #require(segments.first(where: { $0.segmentCount == 3 }))
        let modes = try #require(segments.first(where: { $0.segmentCount == 4 }))
        tools.selectedSegment = 1; _ = tools.sendAction(tools.action, to: tools.target)
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(CGPoint(x: x, y: y), to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        var kinds: [DrawingAnnotation.Kind] = []
        for index in 0..<4 {
            modes.selectedSegment = index; _ = modes.sendAction(modes.action, to: modes.target)
            let x = CGFloat(25 + index * 68)
            canvas.mouseDown(with: try event(.leftMouseDown, x, 35))
            canvas.mouseDragged(with: try event(.leftMouseDragged, x + 45, 95))
            canvas.mouseUp(with: try event(.leftMouseUp, x + 45, 95))
            if let shape = canvas.annotationsBinding?().last { kinds.append(shape.kind) }
        }
        #expect(canvas.regionsBinding?().isEmpty == true, "Drawing must not create a blur region")
        #expect(canvas.annotationsBinding?().count == 4)
        #expect(kinds == [.rectangle, .ellipse, .line, .freehand])
        #expect(descendants(root).compactMap { $0 as? NSButton }.first { $0.title == "내보내기" }?.isEnabled == true)
        controller.perform(NSSelectorFromString("undoTapped"))
        #expect(canvas.annotationsBinding?().count == 3)
        controller.perform(NSSelectorFromString("redoTapped"))
        #expect(canvas.annotationsBinding?().count == 4)
    }

    @MainActor
    @Test
    func testDrawingSelectionDeletesOnlyInDrawingModeAndNeverShadowsRegions() async throws {
        _ = NSApplication.shared
        let url = try makeImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = MainWindowController(); controller.showWindow(nil)
        defer { controller.close() }
        controller.load(url: url)
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let canvas = try #require(descendants(root).compactMap { $0 as? VideoCanvasView }.first)
        for _ in 0..<100 where !canvas.isEditable { try await Task.sleep(nanoseconds: 10_000_000) }
        root.layoutSubtreeIfNeeded()
        let tools = try #require(descendants(root).compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 3 })
        func tool(_ index: Int) { tools.selectedSegment = index; _ = tools.sendAction(tools.action, to: tools.target) }
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, clicks: Int = 1) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(CGPoint(x: x, y: y), to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
        }
        func deleteKey() throws {
            canvas.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)))
        }
        func drawRectangle(at x: CGFloat) throws {
            canvas.mouseDown(with: try mouse(.leftMouseDown, x, 30))
            canvas.mouseDragged(with: try mouse(.leftMouseDragged, x + 60, 90))
            canvas.mouseUp(with: try mouse(.leftMouseUp, x + 60, 90))
        }
        var annotations: [DrawingAnnotation] { canvas.annotationsBinding?() ?? [] }

        // Click the stroke to select, Delete removes it, undo restores it.
        tool(1)
        try drawRectangle(at: 30)
        #expect(annotations.count == 1)
        canvas.mouseDown(with: try mouse(.leftMouseDown, 30, 60)); canvas.mouseUp(with: try mouse(.leftMouseUp, 30, 60))
        try deleteKey()
        #expect(annotations.isEmpty)
        controller.perform(NSSelectorFromString("undoTapped"))
        #expect(annotations.count == 1)
        canvas.mouseDown(with: try mouse(.leftMouseDown, 30, 60, clicks: 2))
        #expect(annotations.isEmpty, "Double-clicking a drawing deletes it")
        controller.perform(NSSelectorFromString("undoTapped"))

        // A drawing selected before switching tools must not swallow Delete for a blur region.
        try drawRectangle(at: 120)
        #expect(annotations.count == 2)
        tool(0)
        controller.perform(NSSelectorFromString("addRegionTapped"))
        let region = try #require(canvas.regionsBinding?().last)
        canvas.selectRegion(id: region.id)
        try deleteKey()
        #expect(canvas.regionsBinding?().isEmpty == true)
        #expect(annotations.count == 2)

        // Picking a region from the sidebar while drawing hands Delete to that region.
        tool(1)
        try drawRectangle(at: 210)
        #expect(annotations.count == 3)
        controller.perform(NSSelectorFromString("addRegionTapped"))
        let second = try #require(canvas.regionsBinding?().last)
        canvas.selectRegion(id: second.id)
        try deleteKey()
        #expect(canvas.regionsBinding?().isEmpty == true)
        #expect(annotations.count == 3)
    }

    @MainActor
    @Test
    func testSliderGestureIsOneUndoAndCommandArrowsRespectFocus() async throws {
        _ = NSApplication.shared
        let url = try makeImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = MainWindowController()
        controller.showWindow(nil)
        defer { controller.close() }
        controller.load(url: url)
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        root.layoutSubtreeIfNeeded()
        let canvas = try #require(descendants(root).compactMap { $0 as? VideoCanvasView }.first)
        for _ in 0..<100 where !canvas.isEditable { try await Task.sleep(nanoseconds: 10_000_000) }
        controller.perform(NSSelectorFromString("addRegionTapped"))
        let slider = try #require(descendants(root).compactMap { $0 as? EditingSlider }.first { !$0.isHiddenOrHasHiddenAncestor })
        slider.editingBegan?()
        for value in 30...65 {
            slider.doubleValue = Double(value)
            _ = slider.sendAction(slider.action, to: slider.target)
        }
        slider.editingEnded?()
        controller.perform(NSSelectorFromString("undoTapped"))
        #expect(canvas.regionsBinding?().count == 1)
        controller.perform(NSSelectorFromString("undoTapped"))
        #expect(canvas.regionsBinding?().isEmpty == true, "One continuous slider gesture must consume exactly one undo")
        controller.perform(NSSelectorFromString("redoTapped"))
        let region = try #require(canvas.regionsBinding?().first)
        canvas.selectRegion(id: region.id)
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
        window.makeFirstResponder(slider)
        #expect(window.firstResponder !== canvas)
        #expect(!canvas.performKeyEquivalent(with: key))
        #expect(canvas.regionsBinding?().first == region)
        window.makeFirstResponder(canvas)
        #expect(canvas.performKeyEquivalent(with: key))
        let moved = try #require(canvas.regionsBinding?().first)
        #expect(abs(moved.boundingRect.minX - region.boundingRect.minX - 0.1) < 0.001)
    }

    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private func makeImage(width: Int = 320, height: Int = 160) throws -> URL {
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                ctx.setFillColor(gray: (x + y) % 16 == 0 ? 0 : 1, alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: 8, height: 8))
            }
        }
        let image = try #require(ctx.makeImage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }
}
