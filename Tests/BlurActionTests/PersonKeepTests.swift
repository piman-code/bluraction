import AppKit
import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import BlurAction

/// 사람 고르기: the mask geometry, the real person detector on a frame with no people, and the editor flow.
/// Synthetic frames have no people, so the editor flow uses a stubbed detector (real faces are not used in tests).
@Suite(.serialized)
struct PersonKeepTests {
    /// A 100×50 label mask: label 3 in columns 10...29 and rows 5...14 (rows from the top).
    private func labelMask(value: UInt8 = 3) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 100, 50, kCVPixelFormatType_OneComponent8, nil, &buffer) == kCVReturnSuccess)
        let mask = try #require(buffer)
        CVPixelBufferLockBaseAddress(mask, [])
        let base = try #require(CVPixelBufferGetBaseAddress(mask)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(mask)
        for row in 0..<50 { for column in 0..<100 { base[row * stride + column] = 0 } }
        for row in 5...14 { for column in 10...29 { base[row * stride + column] = value } }
        CVPixelBufferUnlockBaseAddress(mask, [])
        return mask
    }

    @Test
    func theMaskBoxIsTheTightBoxInBottomLeftCoordinates() throws {
        // The generated instance mask is binary (0 or 255), unlike the label mask.
        let box = try #require(AutoDetector.maskBox(try labelMask(value: 255)))
        #expect(abs(box.minX - 0.10) < 1e-9 && abs(box.width - 0.20) < 1e-9)
        // Rows 5...14 from the top of a 50-row mask are y 0.7...0.9 from the bottom.
        #expect(abs(box.minY - 0.70) < 1e-9 && abs(box.height - 0.20) < 1e-9)
    }

    @Test
    func theLabelUnderAPointIsReadAtThatPlace() throws {
        let mask = try labelMask()
        // Column 15, row 10 from the top: x 15.5/100, y from the bottom (1 - 10.5/50).
        #expect(AutoDetector.instanceLabel(in: mask, at: CGPoint(x: 0.155, y: 1 - 10.5 / 50)) == 3)
        #expect(AutoDetector.instanceLabel(in: mask, at: CGPoint(x: 0.9, y: 0.1)) == 0, "Background is 0")
    }

    @Test
    func aFrameWithNoPeopleHasNoPersonBox() throws {
        let plain = CIImage(color: CIColor(red: 0.4, green: 0.6, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
        #expect(try AutoDetector.personBox(in: plain, at: CGPoint(x: 0.5, y: 0.5)) == nil)
    }

    @MainActor
    @Test
    func theEditorKeepsThePersonClickedAndCoversTheRest() async throws {
        _ = NSApplication.shared
        let session = try await VideoSession.open()
        defer { session.close() }
        let controller = session.controller
        controller.findPersonBox = { _, point in
            // The stub finds one person around the clicked point.
            #expect(point.x > 0 && point.x < 1)
            return CGRect(x: 0.2, y: 0.1, width: 0.3, height: 0.8)
        }
        let size = session.canvas.displayRect.size
        controller.keepPerson(atCanvasPoint: CGPoint(x: size.width / 2, y: size.height / 2))
        try await waitUntil { !controller.isExporting }
        let saved = try VideoProjectFile.decode(controller.projectData(producerVersion: "test.person"))
        #expect(saved.payload.version == 4, "A reverse cover makes the file format 4")
        let region = try #require(saved.payload.regions.first)
        #expect(region.effect.inverted)
        #expect(region.effect.name == "사람 1")
        guard case .rectangle(_, let origin, let size) = region.shape else {
            Issue.record("The kept person is a rectangle around the body")
            return
        }
        // The box is padded by 4% of its size on each side, so the body stays inside the kept area.
        let expectedX: CGFloat = 0.2 - 0.3 * 0.04
        let expectedY: CGFloat = 0.1 - 0.8 * 0.04
        let expectedWidth: CGFloat = 0.3 * 1.08
        #expect(abs(origin.x - expectedX) < 1e-6, "\(origin)")
        #expect(abs(origin.y - expectedY) < 1e-6, "\(origin)")
        #expect(abs(size.width - expectedWidth) < 1e-6, "\(size)")
    }

    @MainActor
    @Test
    func aClickWithNoPersonUnderItAddsNothing() async throws {
        _ = NSApplication.shared
        let session = try await VideoSession.open()
        defer { session.close() }
        let controller = session.controller
        controller.findPersonBox = { _, _ in nil }
        let size = session.canvas.displayRect.size
        controller.keepPerson(atCanvasPoint: CGPoint(x: size.width / 2, y: size.height / 2))
        try await waitUntil { !controller.isExporting }
        let saved = try VideoProjectFile.decode(controller.projectData(producerVersion: "test.person"))
        #expect(saved.payload.regions.isEmpty)
        #expect(saved.payload.version == 3)
    }
}
