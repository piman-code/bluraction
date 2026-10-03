import AppKit
import CoreImage
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BlurAction

/// Drives the actual controller/canvas in independent test windows, without OS automation.
@Suite(.serialized)
@MainActor
struct InteractionBoundaryRegressionTests {
    @Test
    func busyLoadsAndDropsPreserveWorkspacePageEditsAndUndo() throws {
        _ = NSApplication.shared
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = try image("a.png", in: folder), b = try image("b.png", in: folder)
        let pdf = try pdf(in: folder)
        let controller = MainWindowController()
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let container = try #require(window.contentViewController as? MainContainerViewController)
        let canvas = container.canvas
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        func drag(_ urls: [URL]) -> BoundaryDraggingInfo {
            board.clearContents()
            #expect(board.writeObjects(urls.map { $0 as NSURL }))
            return BoundaryDraggingInfo(pasteboard: board, window: window)
        }

        #expect(!canvas.isEditable, "An empty canvas still accepts its first file")
        let first = drag([a])
        #expect(canvas.draggingEntered(first) == .copy)
        #expect(canvas.performDragOperation(first))
        controller.load(urls: [a, b])
        controller.perform(NSSelectorFromString("nextPageTapped"))
        canvas.addRegionHandler?()
        let original = try session(controller)
        #expect(original.regions.count == 1)
        let pageLabel = container.pageLabel.stringValue
        let otherProject = try MultiPageProjectFile.from(PageWorkspace.open([pdf]),
            projectURL: folder.appendingPathComponent("other.bluraction"))

        // This is the same busy transition used by export and tracking, with no parallel work.
        controller.setExporting(true)
        #expect(canvas.canLoadFilesBinding?() == false)
        for urls in [[a], [pdf], [a, b], [pdf, a]] {
            let info = drag(urls)
            #expect(canvas.draggingEntered(info).isEmpty)
            #expect(!canvas.performDragOperation(info), "Also rejects a drop that entered before busy")
            controller.load(urls: urls)
            #expect(try session(controller) == original)
            #expect(container.pageLabel.stringValue == pageLabel)
        }
        try controller.openWorkspaceProject(otherProject, relativeTo: folder.appendingPathComponent("other.bluraction"))
        #expect(try session(controller) == original)
        controller.setExporting(false)
        let saved = folder.appendingPathComponent("preserved.bluraction")
        try controller.saveWorkspaceProject(to: saved)
        let restored = try MultiPageProjectFile.decode(Data(contentsOf: saved))
        #expect(restored.pages.map(\.mediaPath) == ["a.png", "b.png"])
        #expect(restored.currentIndex == 1)
        #expect(restored.pages[1].regions.map(\.shape.id) == original.regions.map(\.shape.id))
        controller.perform(NSSelectorFromString("undoTapped"))
        #expect(try session(controller).regions.isEmpty, "Busy rejection preserves the undo stack")
    }

    @Test
    func appDrawsTranslucentSavedAnnotationsOnceAndMatchesPNG() throws {
        _ = NSApplication.shared
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = try image("source.png", in: folder)
        let controller = MainWindowController()
        controller.showWindow(nil)
        defer { controller.close() }
        let container = try #require(controller.window?.contentViewController as? MainContainerViewController)
        controller.load(url: input)
        let drawing = DrawingAnnotation(kind: .rectangle,
            points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.8)],
            color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), lineWidth: 0.005, fillOpacity: 0.35)
        controller.importProjectItems(ProjectFile(mediaPath: input.path, regions: [], drawings: [drawing]))
        let canvas = container.canvas
        #expect(!canvas.drawsSavedAnnotations)
        let live = try layerImage(container.liveBlur)
        // Paint the actual canvas over the actual live frame, as the view hierarchy does.
        let combined = try paint(canvas, over: live)
        let project = try session(controller)
        let source = try readImage(input)
        let output = folder.appendingPathComponent("export.png")
        try BlurredImageExporter.export(source: source, pairs: [], canvasSize: CGSize(width: 1, height: 1),
            inputURL: input, outputURL: output, type: .png, quality: 1, annotations: project.drawings)
        let exported = try readImage(output)
        let preview = pixel(combined, x: 0.5, y: 0.5)
        let expected = pixel(exported, x: 0.5, y: 0.5)
        #expect(abs(preview[1] - expected[1]) <= 3, "35% fill must not become the twice-painted 57.75%")
        #expect(abs(preview[2] - expected[2]) <= 3)
        canvas.drawsSavedAnnotations = true
        let twicePainted = pixel(try paint(canvas, over: live), x: 0.5, y: 0.5)
        canvas.drawsSavedAnnotations = false
        #expect(twicePainted[1] + 5 < preview[1], "The regression comparison must distinguish duplicate paint")
        #expect(abs(twicePainted[1] - expected[1]) > 5)

        let standalone = VideoCanvasView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        standalone.annotationsBinding = { [drawing.scaled(from: CGSize(width: 1, height: 1), to: standalone.bounds.size)] }
        #expect(standalone.drawsSavedAnnotations)
        let standalonePixel = pixel(try paint(standalone, over: source), x: 0.5, y: 0.5)
        standalone.drawsSavedAnnotations = false
        let standaloneWithoutPaint = pixel(try paint(standalone, over: source), x: 0.5, y: 0.5)
        #expect(standalonePixel[1] + 5 < standaloneWithoutPaint[1],
            "A standalone canvas retains saved paint within its own graphics color space")
    }

    @Test
    func timedVideoTemplateOnStillUsesBaseGeometryForRenderingSelectionAndErasing() throws {
        _ = NSApplication.shared
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = try image("still.png", in: folder)
        let controller = MainWindowController()
        controller.showWindow(nil)
        defer { controller.close() }
        let container = try #require(controller.window?.contentViewController as? MainContainerViewController)
        let canvas = container.canvas
        var effect = RegionEffect(blurRadius: 0, featherRadius: 0, timeRange: 2...5)
        effect.style = .solid
        effect.keyframes = [RegionKeyframe(time: 0, rect: CGRect(x: 0.7, y: 0.1, width: 0.2, height: 0.2))]
        let shape = RegionShape.rectangle(id: UUID(), origin: CGPoint(x: 0.1, y: 0.1), size: CGSize(width: 0.2, height: 0.2))
        var drawing = DrawingAnnotation(kind: .rectangle,
            points: [CGPoint(x: 0.15, y: 0.6), CGPoint(x: 0.35, y: 0.8)], color: .red, lineWidth: 0.003, fillOpacity: 1)
        drawing.timeRange = 2...5
        drawing.keyframes = [RegionKeyframe(time: 0, rect: CGRect(x: 0.7, y: 0.6, width: 0.2, height: 0.2))]
        controller.openProject(ProjectFile(mediaPath: input.path,
            regions: [.init(shape: shape, effect: effect)], drawings: [drawing]), media: input)
        #expect(canvas.isVideoBinding?() == false)
        let shown = try XCTUnwrap(canvas.regionsBinding?().first)
        let annotation = try XCTUnwrap(canvas.annotationsBinding?().first)
        #expect(abs(shown.boundingRect.minX / canvas.bounds.width - 0.1) < 1e-9)
        #expect(abs(annotation.bounds.minX / canvas.bounds.width - 0.15) < 1e-9)
        #expect(canvas.motionPathProvider?().isEmpty == true)
        let live = try layerImage(container.liveBlur)
        #expect(pixel(live, x: 0.2, y: 0.2)[0] < 3)
        #expect(pixel(live, x: 0.8, y: 0.2)[0] > 250)
        let exported = folder.appendingPathComponent("static.png")
        try BlurredImageExporter.export(source: try readImage(input), pairs: [(shape, effect)],
            canvasSize: CGSize(width: 1, height: 1), inputURL: input, outputURL: exported,
            type: .png, quality: 1, annotations: [drawing])
        #expect(pixel(try readImage(exported), x: 0.2, y: 0.2)[0] < 3)
        #expect(pixel(try readImage(exported), x: 0.8, y: 0.2)[0] > 250)
        var selected: UUID?
        let selection = canvas.selectionChange
        canvas.selectionChange = { selected = $0; selection?($0) }
        canvas.modeBinding = { .rectangle }
        try click(canvas, window: controller.window!, at: CGPoint(x: shown.boundingRect.midX, y: shown.boundingRect.midY))
        #expect(selected == shown.id, "Static selection uses the same base position as the renderer")
        canvas.modeBinding = { .erase }
        canvas.eraserStyleBinding = { (false, 24) }
        let regionPoint = CGPoint(x: shown.boundingRect.midX, y: shown.boundingRect.midY)
        controller.setLayerLocked(shown.id, true)
        try click(canvas, window: controller.window!, at: regionPoint)
        #expect(try session(controller).regions.count == 1)
        controller.setLayerLocked(shown.id, false)
        controller.setLayerHidden(shown.id, true)
        try click(canvas, window: controller.window!, at: regionPoint)
        #expect(try session(controller).regions.count == 1, "Hidden regions are not erased")
        controller.setLayerHidden(shown.id, false)
        try click(canvas, window: controller.window!, at: regionPoint)
        #expect(try session(controller).regions.isEmpty)
        let drawingPoint = CGPoint(x: annotation.bounds.midX, y: annotation.bounds.midY)
        controller.setLayerHidden(annotation.id, true)
        #expect(canvas.annotationsBinding?().isEmpty == true)
        try click(canvas, window: controller.window!, at: drawingPoint)
        #expect(try session(controller).drawings.count == 1)
        controller.setLayerHidden(annotation.id, false)
        try click(canvas, window: controller.window!, at: drawingPoint)
        #expect(try session(controller).drawings.isEmpty, "Timed drawings on stills erase at their visible base position")
    }

    @Test
    func compositorOwnershipRetainsSelectionHandlesGhostsAndInProgressPaint() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let canvas = VideoCanvasView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView = canvas
        canvas.isEditable = true; canvas.drawsSavedAnnotations = false
        canvas.isVideoBinding = { true }; canvas.currentTimeProvider = { 0 }
        let black = try #require(CIContext().createCGImage(CIImage(color: .black), from: canvas.bounds))
        var drawing = DrawingAnnotation(kind: .rectangle,
            points: [CGPoint(x: 20, y: 20), CGPoint(x: 80, y: 80)], color: .red, lineWidth: 4, fillOpacity: 1)
        drawing.timeRange = 2...5
        canvas.annotationsBinding = { [drawing] }
        let ghost = try paint(canvas, over: black)
        #expect(pixel(ghost, x: 0.5, y: 0.5)[0] < 3, "Out-of-time drawings keep an outline, not their saved fill")
        let ghostEdge = (22...78).map { pixel(ghost, x: CGFloat($0) / 100, y: 0.2)[0] }.max() ?? 0
        #expect(ghostEdge > 20, "The video guide remains visible with compositor ownership")
        canvas.modeBinding = { .drawRectangle }
        canvas.selectAnnotation(id: drawing.id)
        let selected = try paint(canvas, over: black)
        #expect(pixel(selected, x: 0.2, y: 0.2)[1] > 200, "Selection corner handles still paint")
        canvas.resetInteraction()
        canvas.annotationsBinding = { [] }
        canvas.modeBinding = { .drawRectangle }
        canvas.annotationStyleBinding = { (.red, 4, 1) }
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: canvas.convert(CGPoint(x: 20, y: 20), to: nil), modifierFlags: [],
            timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let dragged = try #require(NSEvent.mouseEvent(with: .leftMouseDragged,
            location: canvas.convert(CGPoint(x: 70, y: 70), to: nil), modifierFlags: [],
            timestamp: 2, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: down); canvas.mouseDragged(with: dragged)
        #expect(pixel(try paint(canvas, over: black), x: 0.45, y: 0.45)[0] > 100,
            "A drawing under the pointer paints before it enters the saved model")
        canvas.resetInteraction()
    }

    @Test
    func videoEraserStillHonorsPlayheadAndUnconnectedHostCompatibility() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 120, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let canvas = VideoCanvasView(frame: CGRect(x: 0, y: 0, width: 120, height: 100))
        window.contentView = canvas
        canvas.isEditable = true
        canvas.videoSizeBinding = { CGSize(width: 120, height: 100) }
        canvas.modeBinding = { .erase }; canvas.eraserStyleBinding = { (false, 24) }
        let region = RegionShape.rectangle(id: UUID(), origin: CGPoint(x: 10, y: 10), size: CGSize(width: 35, height: 35))
        var effect = RegionEffect.alwaysOn(); effect.timeRange = 2...5
        var drawing = DrawingAnnotation(kind: .rectangle, points: [CGPoint(x: 70, y: 10), CGPoint(x: 110, y: 45)], fillOpacity: 1)
        drawing.timeRange = 2...5
        canvas.regionsBinding = { [region] }; canvas.effectForID = { _ in effect }
        canvas.annotationsBinding = { [drawing] }
        var now = 0.0, erased = Set<UUID>()
        canvas.currentTimeProvider = { now }
        canvas.itemsErased = { regions, drawings, _ in erased.formUnion(regions); erased.formUnion(drawings) }
        for point in [CGPoint(x: 25, y: 25), CGPoint(x: 90, y: 25)] { try click(canvas, window: window, at: point) }
        #expect(erased.isEmpty, "Legacy standalone size binding still represents a video")
        canvas.isVideoBinding = { true }
        now = 3
        for point in [CGPoint(x: 25, y: 25), CGPoint(x: 90, y: 25)] { try click(canvas, window: window, at: point) }
        #expect(erased == [region.id, drawing.id])
        erased.removeAll(); now = 0; canvas.isVideoBinding = { false }
        for point in [CGPoint(x: 25, y: 25), CGPoint(x: 90, y: 25)] { try click(canvas, window: window, at: point) }
        #expect(erased == [region.id, drawing.id], "Explicit still status overrides a nonzero media size")
    }

    private func session(_ controller: MainWindowController) throws -> ProjectFile {
        try ProjectFile.decode(controller.projectData())
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("blur-boundary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func image(_ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let cg = try #require(CIContext().createCGImage(CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 120, height: 100)),
            from: CGRect(x: 0, y: 0, width: 120, height: 100)))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }
    private func pdf(in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("other.pdf")
        var box = CGRect(x: 0, y: 0, width: 120, height: 100)
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(box)
        context.endPDFPage(); context.closePDF()
        return url
    }
    private func readImage(_ url: URL) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
    private func layerImage(_ layer: CALayer) throws -> CGImage {
        let contents = try #require(layer.contents)
        try #require(CFGetTypeID(contents as CFTypeRef) == CGImage.typeID, "Preview contents must be a CGImage")
        return contents as! CGImage
    }
    private func pixel(_ cg: CGImage, x: CGFloat, y: CGFloat) -> [Int] {
        var rgba = [UInt8](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { bytes in
            CIContext().render(CIImage(cgImage: cg), toBitmap: bytes.baseAddress!, rowBytes: 4,
                bounds: CGRect(x: floor(CGFloat(cg.width) * x), y: floor(CGFloat(cg.height) * y), width: 1, height: 1),
                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        return rgba.map(Int.init)
    }
    private func paint(_ canvas: VideoCanvasView, over image: CGImage) throws -> CGImage {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.bounds.width),
            pixelsHigh: Int(canvas.bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let graphics = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        graphics.cgContext.draw(image, in: canvas.bounds)
        canvas.draw(canvas.bounds)
        return try #require(bitmap.cgImage)
    }
    private func click(_ canvas: VideoCanvasView, window: NSWindow, at point: CGPoint) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { canvas.mouseDown(with: event) } else { canvas.mouseUp(with: event) }
        }
    }
}

private final class BoundaryDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    init(pasteboard: NSPasteboard, window: NSWindow) { draggingPasteboard = pasteboard; draggingDestinationWindow = window }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .link, .generic] }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
