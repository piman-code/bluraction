import AppKit
import Testing
@testable import BlurAction

struct ResizeCursorTests {
    @MainActor
    @Test(arguments: [false, true])
    func selectedRectangleAndEllipseMapEveryHandleToItsResizeDirection(ellipse: Bool) {
        _ = NSApplication.shared
        let canvas = VideoCanvasView(frame: NSRect(x: 0, y: 0, width: 240, height: 180))
        let id = UUID()
        let origin = CGPoint(x: 40, y: 30)
        let size = CGSize(width: 100, height: 80)
        let region: RegionShape = ellipse
            ? .ellipse(id: id, origin: origin, size: size)
            : .rectangle(id: id, origin: origin, size: size)
        canvas.regionsBinding = { [region] }
        canvas.isEditable = true
        canvas.selectRegion(id: id)

        let expected: [(CGPoint, VideoCanvasView.ResizeCursorDirection)] = [
            (CGPoint(x: 40, y: 30), .ascendingDiagonal),
            (CGPoint(x: 140, y: 110), .ascendingDiagonal),
            (CGPoint(x: 140, y: 30), .descendingDiagonal),
            (CGPoint(x: 40, y: 110), .descendingDiagonal),
            (CGPoint(x: 90, y: 30), .vertical),
            (CGPoint(x: 90, y: 110), .vertical),
            (CGPoint(x: 40, y: 70), .horizontal),
            (CGPoint(x: 140, y: 70), .horizontal),
        ]
        for (point, direction) in expected {
            #expect(canvas.resizeCursorDirection(at: point) == direction)
        }
        #expect(canvas.resizeCursorDirection(at: CGPoint(x: 90, y: 70)) == nil)
        #expect(canvas.resizeCursorDirection(at: CGPoint(x: 5, y: 5)) == nil)
        canvas.isEditable = false
        #expect(canvas.resizeCursorDirection(at: CGPoint(x: 40, y: 30)) == nil)
    }

    @MainActor
    @Test
    func unselectedAndPolygonVerticesKeepTheirExistingCursorBehavior() {
        _ = NSApplication.shared
        let canvas = VideoCanvasView(frame: NSRect(x: 0, y: 0, width: 240, height: 180))
        let rectangle = RegionShape.rectangle(id: UUID(), origin: CGPoint(x: 40, y: 30), size: CGSize(width: 100, height: 80))
        let polygon = RegionShape.polygon(id: UUID(), points: [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 10), CGPoint(x: 20, y: 30)])
        canvas.regionsBinding = { [rectangle, polygon] }
        canvas.isEditable = true
        #expect(canvas.resizeCursorDirection(at: CGPoint(x: 40, y: 30)) == nil)
        canvas.selectRegion(id: polygon.id)
        #expect(canvas.resizeCursorDirection(at: CGPoint(x: 10, y: 10)) == nil)
        #expect(canvas.resizeCursorDirection(at: CGPoint(x: 40, y: 30)) == nil)
    }
}
