import Testing
import AppKit
@testable import BlurAction

@Suite(.serialized)
@MainActor
struct TimeRangeEditorTests {
    @Test
    func testSelectedRegionRangeValidationUndoAndEntireVideo() async throws {
        _ = NSApplication.shared
        let fixtures = VideoExportTests()
        let directory = try fixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try fixtures.fixture(in: directory)
        let controller = MainWindowController()
        controller.showWindow(nil)
        defer { controller.close() }
        controller.load(url: input)
        let container = try #require(controller.window?.contentViewController as? MainContainerViewController)
        for _ in 0..<300 where !container.slider.isEnabled { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(container.slider.isEnabled)
        controller.window?.setContentSize(CGSize(width: 760, height: 500))
        container.view.layoutSubtreeIfNeeded()
        #expect(abs(container.view.bounds.width - 760) < 1)
        #expect(abs(container.view.bounds.height - 500) < 1)
        let fields = descendants(container.view).compactMap { $0 as? NSTextField }
        let start = try #require(fields.first { $0.placeholderString == "시작 (초)" })
        let end = try #require(fields.first { $0.placeholderString == "끝 (초)" })
        #expect(!start.isEnabled)
        controller.perform(NSSelectorFromString("addRegionTapped"))
        let first = try #require(container.canvas.regionsBinding?().first)
        controller.perform(NSSelectorFromString("addRegionTapped"))
        let second = try #require(container.canvas.regionsBinding?().last)
        start.stringValue = "0.25"; end.stringValue = "0.75"
        controller.perform(NSSelectorFromString("applyTimeRange"))
        let effect = try #require(container.canvas.effectForID?(second.id))
        #expect(effect.timeRange == 0.25...0.75)
        #expect(!effect.isActive(at: 0.1) && effect.isActive(at: 0.5) && !effect.isActive(at: 0.9))
        #expect(container.canvas.effectForID?(first.id)?.timeRange == 0...container.slider.maxValue)
        start.stringValue = "0.9"; end.stringValue = "0.2"
        controller.perform(NSSelectorFromString("applyTimeRange"))
        #expect(container.canvas.effectForID?(second.id)?.timeRange == 0.25...0.75)
        start.stringValue = "1.001"; end.stringValue = "1.004"
        controller.perform(NSSelectorFromString("applyTimeRange"))
        #expect(container.canvas.effectForID?(second.id)?.timeRange == 0.25...0.75)
        start.stringValue = "nan"; end.stringValue = "100"
        controller.perform(NSSelectorFromString("applyTimeRange"))
        #expect(container.canvas.effectForID?(second.id)?.timeRange == 0.25...0.75)
        controller.perform(NSSelectorFromString("undoTapped"))
        #expect(container.canvas.effectForID?(second.id)?.timeRange == 0...container.slider.maxValue)
        controller.perform(NSSelectorFromString("redoTapped"))
        #expect(container.canvas.effectForID?(second.id)?.timeRange == 0.25...0.75)
        controller.perform(NSSelectorFromString("applyEntireVideo"))
        #expect(container.canvas.effectForID?(second.id)?.timeRange == 0...0)
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
