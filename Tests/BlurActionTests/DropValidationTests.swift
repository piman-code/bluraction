import Foundation
import AppKit
import Testing
@testable import BlurAction

struct DropValidationTests {
    @MainActor
    @Test
    func acceptsOnlyReadableRegularSupportedMediaFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("blur-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func file(_ name: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data([0x01]).write(to: url)
            return url
        }

        for name in ["still.PNG", "photo.JpEg", "graphic.webp", "clip.MOV", "movie.mp4", "video.m4v"] {
            #expect(VideoCanvasView.isSupportedDropFile(try file(name)), "Expected \(name) to pass the drop gate")
        }
        #expect(!VideoCanvasView.isSupportedDropFile(try file("notes.txt")))
        #expect(!VideoCanvasView.isSupportedDropFile(try file("sound.mp3")))
        #expect(!VideoCanvasView.isSupportedDropFile(try file("no-extension")))

        let disguisedDirectory = directory.appendingPathComponent("folder.mp4", isDirectory: true)
        try FileManager.default.createDirectory(at: disguisedDirectory, withIntermediateDirectories: true)
        #expect(!VideoCanvasView.isSupportedDropFile(disguisedDirectory))
        #expect(!VideoCanvasView.isSupportedDropFile(directory.appendingPathComponent("missing.png")))
        #expect(!VideoCanvasView.isSupportedDropFile(URL(string: "https://example.com/clip.mp4")!))

        let target = try file("target.png")
        let link = directory.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(!VideoCanvasView.isSupportedDropFile(link))
    }

    @MainActor
    @Test
    func finderStyleFileURLsDecodeFromPasteboard() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("blur-pasteboard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for name in ["sample.png", "sample.mp4"] {
            let url = directory.appendingPathComponent(name)
            try Data([0x01]).write(to: url)
            pasteboard.clearContents()
            #expect(pasteboard.writeObjects([url as NSURL]))
            #expect(VideoCanvasView.supportedDroppedURL(from: pasteboard) == url)
        }
        pasteboard.clearContents()
        #expect(VideoCanvasView.supportedDroppedURL(from: pasteboard) == nil)
    }

    /// Drives the real window's drop handlers with a Finder-style pasteboard. The OS drag
    /// session itself still needs a manual Finder check (automation lacks Accessibility).
    @MainActor
    @Test
    func finderStyleDropShowsWholeMediaImmediatelyAndKeepsAspectOnResize() async throws {
        _ = NSApplication.shared
        let fixtures = VideoExportTests()
        let directory = try fixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("wide.mp4")
        try fixtures.ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24:duration=2",
                             "-c:v", "libx264", "-pix_fmt", "yuv420p", video.path])
        let image = directory.appendingPathComponent("tall.png")
        try fixtures.ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=300x500", "-frames:v", "1", image.path])
        let text = directory.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: text)

        let controller = MainWindowController()
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let container = try #require(window.contentViewController as? MainContainerViewController)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        func drop(_ url: URL) -> (NSDragOperation, Bool) {
            pasteboard.clearContents()
            pasteboard.writeObjects([url as NSURL])
            let info = FakeDraggingInfo(pasteboard: pasteboard, window: window)
            let operation = container.canvas.draggingEntered(info)
            return (operation, operation.isEmpty ? false : container.canvas.performDragOperation(info))
        }
        func expectWholeMediaFits(_ aspect: CGFloat, _ label: String) {
            let fit = container.aspectFitVideo.frame
            let available = container.videoContainer.bounds
            #expect(fit.width > 0 && fit.height > 0, "\(label): media area is empty")
            #expect(abs(fit.width / fit.height - aspect) < 0.01, "\(label): aspect \(fit.width / fit.height) != \(aspect)")
            #expect(available.insetBy(dx: -0.5, dy: -0.5).contains(fit), "\(label): media is cropped")
            #expect(container.canvas.frame.size == fit.size && container.liveBlur.frame.size == fit.size)
        }

        #expect(drop(text).0.isEmpty, "Unsupported files must be refused at drag-enter")

        let (videoOperation, videoAccepted) = drop(video)
        #expect(videoOperation == .copy && videoAccepted)
        try await waitFor { container.liveBlur.contents != nil }
        #expect(container.playerLayer.player?.rate == 0, "The first frame must appear without Play or a resize")
        expectWholeMediaFits(640.0 / 360.0, "video after drop")
        window.setContentSize(CGSize(width: 1300, height: 560))
        container.view.layoutSubtreeIfNeeded()
        expectWholeMediaFits(640.0 / 360.0, "video after resize")
        #expect(container.liveBlur.contents != nil)

        let (imageOperation, imageAccepted) = drop(image)
        #expect(imageOperation == .copy && imageAccepted)
        try await waitFor { container.liveBlur.contents != nil && container.playerLayer.isHidden }
        expectWholeMediaFits(300.0 / 500.0, "image after drop")
        window.setContentSize(CGSize(width: 1400, height: 520))
        container.view.layoutSubtreeIfNeeded()
        expectWholeMediaFits(300.0 / 500.0, "image after resize")
        #expect(container.liveBlur.contents != nil)
    }

    @MainActor
    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try #require(predicate(), "Timed out waiting for the dropped media to appear")
    }
}

/// Minimal NSDraggingInfo carrying a Finder-style file URL pasteboard.
private final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    init(pasteboard: NSPasteboard, window: NSWindow) {
        draggingPasteboard = pasteboard
        draggingDestinationWindow = window
    }
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
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
