import AppKit
import Testing
@testable import BlurAction

/// Representative native states for visual inspection; synthetic media only.
@Suite(.serialized)
@MainActor
struct InspectorVisualTests {
    @Test func videoInspectorStatesHaveReadableControlsAndPreserveSelection() async throws {
        let session = try await VideoSession.open()
        defer {
            session.container.playerLayer.player?.pause()
            session.controller.close()
        }
        session.window.setContentSize(.init(width: 1180, height: 700))
        session.window.appearance = NSAppearance(named: .darkAqua)
        let tabs = try #require(session.descendants.first {
            $0.identifier?.rawValue == "taskPanelSelector"
        } as? NSSegmentedControl)
        func choose(_ index: Int) {
            tabs.selectedSegment = index
            #expect(tabs.sendAction(tabs.action, to: tabs.target))
            session.window.contentView?.layoutSubtreeIfNeeded()
        }
        @discardableResult
        func capture(_ name: String) throws -> NSBitmapImageRep {
            let content = try #require(session.window.contentView)
            content.layoutSubtreeIfNeeded()
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
            if let folder = ProcessInfo.processInfo.environment["BLURACTION_GUI_CAPTURE_DIR"] {
                let destination = URL(fileURLWithPath: folder).appendingPathComponent("inspector-\(name)-\(UUID()).png")
                try bytes.write(to: destination, options: .withoutOverwriting)
                print("Native inspector capture: \(destination.path)")
            }
            return bitmap
        }
        choose(0)
        try capture("video-find-empty")
        let item = try #require(session.window.toolbar?.items.first { $0.label == "영역 추가" })
        #expect(NSApplication.shared.sendAction(try #require(item.action), to: item.target, from: item))
        let region = try #require(session.canvas.regionsBinding?().last)
        #expect(session.controller.setCoverDecoration(region.id, text: "학생 A 🙂"))
        session.canvas.selectRegion(id: region.id)
        choose(1)
        try capture("video-selected-dark")
        session.window.appearance = NSAppearance(named: .aqua)
        session.window.contentView?.needsDisplay = true
        try await Task.sleep(nanoseconds: 50_000_000)
        let light = try capture("video-selected-light")
        let lightBackground = try #require(light.colorAt(x: light.pixelsWide - 4, y: light.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        #expect(lightBackground.redComponent > 0.7 && lightBackground.greenComponent > 0.7,
                "Light appearance must refresh the rendered sidebar background for readable dark labels")
        #expect(session.canvas.effectForID?(region.id)?.decoration?.text == "학생 A 🙂")
        #expect(session.canvas.regionsBinding?().count == 1)
        #expect(session.container.slider.isEnabled)
        choose(2)
        try capture("video-review")
        session.window.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(nanoseconds: 50_000_000)
        let dark = try capture("video-review-dark")
        let darkBackground = try #require(dark.colorAt(x: dark.pixelsWide - 4, y: dark.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        #expect(darkBackground.redComponent < 0.3 && darkBackground.greenComponent < 0.3)
    }
}
