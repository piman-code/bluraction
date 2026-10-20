import AppKit
import Foundation
import PDFKit
import Testing
@testable import BlurAction

/// Exercises the controls in the real AppKit window with generated local media.
/// Fixtures are kept available for inspection; only test-owned windows/players close.
@Suite(.serialized)
@MainActor
struct TaskSidebarTests {
    private func close(_ session: EditorSession) {
        session.container.playerLayer.player?.pause()
        session.controller.close()
    }

    private func view<T: NSView>(_ id: String, in session: EditorSession, as type: T.Type = T.self) throws -> T {
        try #require(session.descendants.first { $0.identifier?.rawValue == id } as? T,
                     "Native sidebar is missing \(id)")
    }

    private func button(_ title: String, in session: EditorSession) throws -> NSButton {
        try #require(session.descendants.compactMap { $0 as? NSButton }.first { $0.title == title })
    }

    private func choose(_ index: Int, in session: EditorSession) throws {
        let tabs: NSSegmentedControl = try view("taskPanelSelector", in: session)
        tabs.selectedSegment = index
        #expect(tabs.sendAction(tabs.action, to: tabs.target))
        session.window.contentView?.layoutSubtreeIfNeeded()
    }

    @discardableResult
    private func addCover(in session: EditorSession) throws -> RegionShape {
        let item = try #require(session.window.toolbar?.items.first { $0.label == "영역 추가" })
        #expect(NSApplication.shared.sendAction(try #require(item.action), to: item.target, from: item))
        return try #require(session.canvas.regionsBinding?().last)
    }

    private func assertVisible(_ view: NSView, in session: EditorSession) {
        session.window.contentView?.layoutSubtreeIfNeeded()
        #expect(!view.isHiddenOrHasHiddenAncestor)
        #expect(view.bounds.width > 0 && view.bounds.height > 0)
        #expect(view.visibleRect.width > 0 && view.visibleRect.height > 0,
                "A fixed area must remain reachable without scrolling its inspector")
        if let content = session.window.contentView {
            let box = view.convert(view.bounds, to: content)
            #expect(box.minX >= content.bounds.minX - 1 && box.maxX <= content.bounds.maxX + 1)
            #expect(box.minY >= content.bounds.minY - 1 && box.maxY <= content.bounds.maxY + 1)
        }
    }

    private func capture(_ name: String, in session: EditorSession) throws {
        guard let folder = ProcessInfo.processInfo.environment["BLURACTION_GUI_CAPTURE_DIR"] else { return }
        let content = try #require(session.window.contentView)
        content.layoutSubtreeIfNeeded()
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
        let destination = URL(fileURLWithPath: folder, isDirectory: true)
            .appendingPathComponent("task-sidebar-\(name)-\(UUID()).png")
        try bytes.write(to: destination, options: .withoutOverwriting)
        print("Native task sidebar capture: \(destination.path)")
    }

    @Test func taskTabsContextAndAdvancedControlsOperateOnTheRealImageSelection() async throws {
        let session = try await ImageSession.open(split: true)
        defer { close(session) }
        let source = session.directory.appendingPathComponent("tools.png")
        let original = try Data(contentsOf: source)
        let tabs: NSSegmentedControl = try view("taskPanelSelector", in: session)
        #expect((0..<tabs.segmentCount).map { tabs.label(forSegment: $0) } == ["찾기", "선택한 영역", "확인"])
        try choose(0, in: session)
        let find: NSStackView = try view("findPanel", in: session)
        let selected: NSStackView = try view("selectedPanel", in: session)
        let review: NSStackView = try view("reviewPanel", in: session)
        #expect(!find.isHiddenOrHasHiddenAncestor && selected.isHiddenOrHasHiddenAncestor && review.isHiddenOrHasHiddenAncestor)
        let shape = try addCover(in: session)
        session.canvas.selectRegion(id: shape.id)
        try choose(1, in: session)
        #expect(find.isHiddenOrHasHiddenAncestor && !selected.isHiddenOrHasHiddenAncestor)
        let field = try #require(session.descendants.compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "가림에 붙일 내용" })
        #expect(!field.isHiddenOrHasHiddenAncestor && field.isEnabled)
        field.stringValue = "학생 A 🙂"
        try button("붙이기", in: session).performClick(nil)
        #expect(session.canvas.effectForID?(shape.id)?.decoration?.text == "학생 A 🙂")
        let advanced: NSView = try view("advancedSettingsContent", in: session)
        let toggle: NSButton = try view("advancedSettingsToggle", in: session)
        #expect(advanced.isHiddenOrHasHiddenAncestor)
        toggle.performClick(nil)
        #expect(!advanced.isHiddenOrHasHiddenAncestor)
        let precise = try button("좌표·크기 적용", in: session)
        #expect(!precise.isHiddenOrHasHiddenAncestor && precise.isEnabled)
        let x = try #require(session.descendants.compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "왼쪽 X (원본 픽셀)" })
        x.stringValue = "16"
        precise.performClick(nil)
        let saved = try ProjectFile.decode(session.controller.projectData())
        #expect(abs(try #require(saved.regions.first).shape.boundingRect.minX - 16 / 320.0) < 0.001)
        #expect(saved.regions.first?.effect.decoration?.text == "학생 A 🙂")
        try capture("image-selection-advanced", in: session)
        toggle.performClick(nil)
        #expect(advanced.isHiddenOrHasHiddenAncestor)
        try choose(2, in: session)
        #expect(!review.isHiddenOrHasHiddenAncestor && selected.isHiddenOrHasHiddenAncestor)
        #expect(try button("이 구간 다시 추적", in: session).isHiddenOrHasHiddenAncestor,
                "Images show static checking guidance rather than video repair actions")
        #expect(try Data(contentsOf: source) == original)
        try capture("image-check", in: session)
    }

    @Test func fixedLayersToolsAndOutputRemainReachableAcrossTabsAtTheSmallWindowSize() async throws {
        let session = try await ImageSession.open()
        defer { close(session) }
        _ = try addCover(in: session)
        let layers: NSStackView = try view("pinnedLayers", in: session)
        let tools: NSStackView = try view("editorToolBar", in: session)
        let output: NSStackView = try view("outputArea", in: session)
        let table = try #require(session.descendants.compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "레이어 목록" })
        for size in [CGSize(width: 760, height: 500), CGSize(width: 640, height: 420)] {
            session.window.setContentSize(size)
            for index in 0..<3 {
                try choose(index, in: session)
                assertVisible(layers, in: session)
                assertVisible(tools, in: session)
                assertVisible(output, in: session)
                assertVisible(try button("내보내기", in: session), in: session)
                #expect(table.numberOfRows == 1)
                #expect(!table.isHiddenOrHasHiddenAncestor && table.visibleRect.height > 0)
                #expect(session.canvas.bounds.width > 100 && session.canvas.bounds.height > 50)
                try capture("small-\(Int(size.width))-tab-\(index)", in: session)
            }
        }
        let toggle: NSButton = try view("outputSettingsToggle", in: session)
        let content: NSView = try view("outputSettingsContent", in: session)
        #expect(content.isHiddenOrHasHiddenAncestor)
        let shortcut: NSButton = try view("outputSettingsShortcut", in: session)
        shortcut.performClick(nil)
        let tabs: NSSegmentedControl = try view("taskPanelSelector", in: session)
        #expect(tabs.selectedSegment == 1)
        let format = try #require(session.descendants.compactMap { $0 as? NSPopUpButton }
            .first { $0.itemTitles == ["PNG", "JPEG", "HEIC", "TIFF"] })
        #expect(!content.isHiddenOrHasHiddenAncestor && !format.isHiddenOrHasHiddenAncestor)
        #expect(format.isEnabled)
        try capture("image-output-formats", in: session)
        format.selectItem(withTitle: "TIFF")
        try choose(0, in: session)
        #expect(format.titleOfSelectedItem == "TIFF", "Task changes keep the selected image output format")
        try choose(1, in: session)
        toggle.performClick(nil)
        assertVisible(layers, in: session)
        assertVisible(try button("내보내기", in: session), in: session)
    }

    @Test func drawingAndEraserModesRetainTheirNativeControlsAfterTaskChanges() async throws {
        let session = try await ImageSession.open()
        defer { close(session) }
        try choose(1, in: session)
        session.tool(1)
        session.mode(5) // Existing text drawing mode.
        let bold = try button("굵게", in: session)
        #expect(!bold.isHiddenOrHasHiddenAncestor && bold.isEnabled)
        let previousBold = bold.state
        bold.performClick(nil)
        #expect(bold.state == (previousBold == .on ? .off : .on))
        session.tool(2)
        let eraser = try #require(session.descendants.compactMap { $0 as? NSSegmentedControl }
            .first { $0.label(forSegment: 0) == "부분 지우개" })
        #expect(!eraser.isHiddenOrHasHiddenAncestor && eraser.isEnabled)
        eraser.selectedSegment = 1
        #expect(eraser.sendAction(eraser.action, to: eraser.target))
        try choose(0, in: session)
        try choose(1, in: session)
        #expect(eraser.selectedSegment == 1 && !eraser.isHiddenOrHasHiddenAncestor)
        session.tool(0)
        session.mode(1)
        try session.drag(from: CGPoint(x: 30, y: 30), to: CGPoint(x: 100, y: 80))
        let shape = try #require(session.canvas.regionsBinding?().last)
        if case .ellipse = shape {} else { Issue.record("The preserved shape tool must create an ellipse") }
    }

    @Test func multiPagePDFAndImagesKeepNavigationEditsCopyAllAndSeparateSavedResults() async throws {
        let session = try await ImageSession.open(split: true)
        defer { close(session) }
        let image = session.directory.appendingPathComponent("tools.png")
        let pdf = session.directory.appendingPathComponent("synthetic-pages.pdf")
        var box = CGRect(x: 0, y: 0, width: 160, height: 120)
        let writer = try #require(CGContext(pdf as CFURL, mediaBox: &box, nil))
        for color in [NSColor.white, NSColor.systemYellow] {
            writer.beginPage(mediaBox: &box)
            writer.setFillColor(color.cgColor)
            writer.fill(box)
            writer.endPage()
        }
        writer.closePDF()
        let originals = try [pdf, image].map { try Data(contentsOf: $0) }
        session.controller.load(urls: [pdf, image])
        try await waitUntil { session.canvas.isEditable && session.container.pageLabel.stringValue == "1 / 3" }
        let copy = try button("현재 페이지 작업을 모든 페이지에 적용…", in: session)
        #expect(!copy.isHiddenOrHasHiddenAncestor && copy.isEnabled && copy.action != nil && copy.target != nil)
        let cover = try addCover(in: session)
        #expect(session.controller.setCoverDecoration(cover.id, text: "문서 🙂"))
        session.controller.applyCurrentPageToAll()
        session.container.nextPageButton.performClick(nil)
        #expect(session.container.pageLabel.stringValue == "2 / 3")
        #expect(session.canvas.regionsBinding?().count == 1)
        _ = try addCover(in: session)
        session.container.nextPageButton.performClick(nil)
        #expect(session.container.pageLabel.stringValue == "3 / 3")
        #expect(session.canvas.regionsBinding?().count == 1)
        session.container.previousPageButton.performClick(nil)
        #expect(session.canvas.regionsBinding?().count == 2)
        try capture("multipage-page-two", in: session)
        try choose(2, in: session)
        let outputShortcut: NSButton = try view("outputSettingsShortcut", in: session)
        outputShortcut.performClick(nil)
        let format = try #require(session.descendants.compactMap { $0 as? NSPopUpButton }
            .first { $0.itemTitles == ["PNG", "JPEG", "HEIC", "TIFF"] })
        #expect(format.isHiddenOrHasHiddenAncestor, "Multi-page output keeps its PDF and per-image PNG contract")
        let destination = session.directory.appendingPathComponent("task-sidebar.bluraction")
        try session.controller.saveWorkspaceProject(to: destination)
        let savedBytes = try Data(contentsOf: destination)
        let project = try MultiPageProjectFile.decode(savedBytes)
        #expect(project.currentIndex == 1 && project.pages.count == 3)
        let workspace = try project.workspace(relativeTo: destination)
        let result = session.directory.appendingPathComponent("task-sidebar-result.pdf")
        try workspace.exportPDF(to: result)
        #expect(PDFDocument(url: result)?.pageCount == 3)
        let images = try #require(try workspace.exportImageFiles(near: result))
        #expect(try FileManager.default.contentsOfDirectory(atPath: images.path).count == 1)
        try session.controller.openWorkspaceProject(project, relativeTo: destination)
        #expect(session.container.pageLabel.stringValue == "2 / 3")
        #expect(session.canvas.regionsBinding?().count == 2)
        #expect(try [pdf, image].map { try Data(contentsOf: $0) } == originals)
        #expect(try Data(contentsOf: destination) == savedBytes)
    }

    @Test func phraseWorkLocksHiddenEditorsAndRealCancelRestoresControlsWithoutApplyingLateResults() async throws {
        let session = try await VideoSession.open()
        defer { close(session) }
        let cover = try addCover(in: session)
        #expect(session.controller.setCoverDecoration(cover.id, text: "기존 편집"))
        let before = try session.controller.projectData(producerVersion: "task-sidebar-test")
        let source = session.directory.appendingPathComponent("motion.mp4")
        let identity = try VideoProjectSourceBinding.Source.capture(source)
        session.controller.trackPhrases = { _, _, _, cancellation, _, _ in
            while !cancellation.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
            let track = PhraseTracker.Track(phrase: "늦은 결과", samples: [
                .init(time: 0, box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
            ], start: 0, end: 2)
            return .init(tracks: [track], reviews: [], cancelled: false, recognitionStep: 1)
        }
        try choose(0, in: session)
        let phrase = try #require(session.descendants.compactMap { $0 as? NSTextField }
            .first { $0.placeholderString == "가릴 문구 (쉼표로 여러 개)" })
        phrase.stringValue = "늦은 결과"
        let start = try #require(session.descendants.compactMap { $0 as? NSButton }.first { $0.title.hasPrefix("문구 찾아") })
        start.performClick(nil)
        #expect(session.controller.isExporting && !session.canvas.isEditable)
        let field = try #require(session.descendants.compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "가림에 붙일 내용" })
        #expect(!field.isEnabled && !start.isEnabled && !session.tools.isEnabled)
        #expect(!session.container.slider.isEnabled)
        let cancel = try button("취소", in: session)
        #expect(!cancel.isHiddenOrHasHiddenAncestor && cancel.isEnabled)
        try capture("video-busy-cancel", in: session)
        cancel.performClick(nil)
        try await waitUntil { !session.controller.isExporting }
        #expect(session.canvas.isEditable && field.isEnabled && start.isEnabled && session.tools.isEnabled)
        #expect(session.container.slider.isEnabled)
        #expect(try session.controller.projectData(producerVersion: "task-sidebar-test") == before)
        #expect(try VideoProjectSourceBinding.Source.capture(source) == identity)
    }
}
