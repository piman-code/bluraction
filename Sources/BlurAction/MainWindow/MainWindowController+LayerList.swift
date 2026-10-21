import AppKit
import AVKit
import AVFoundation
import UniformTypeIdentifiers
import os
import Darwin

// MainWindowController: 도구막대 delegate, 레이어 표 data source·delegate.

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension NSToolbarItem.Identifier {
    static let open = NSToolbarItem.Identifier("com.bluraction.open")
    static let addRegion = NSToolbarItem.Identifier("com.bluraction.addRegion")
    static let export = NSToolbarItem.Identifier("com.bluraction.export")
}

extension MainWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.open, .addRegion, .flexibleSpace, .export]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case .open:
            item.label = "열기"; item.paletteLabel = "열기"
            item.toolTip = "영상 파일 열기 (⌘O)"
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "열기")
            item.target = self; item.action = #selector(openTapped)
        case .addRegion:
            item.label = "영역 추가"; item.paletteLabel = "영역 추가"
            item.toolTip = "사각형 영역 추가 (⇧⌘A)"
            item.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: "영역 추가")
            item.target = self; item.action = #selector(addRegionTapped)
        case .export:
            item.label = "내보내기"; item.paletteLabel = "내보내기"
            item.toolTip = "블러 처리해서 저장 (⌘E)"
            item.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "내보내기")
            item.target = self; item.action = #selector(exportTapped)
        default:
            return nil
        }
        return item
    }
}

extension MainWindowController: NSTableViewDataSource, NSTableViewDelegate {
    /// Layer rows, top of the list = drawn on top: drawings (front first), then blur regions.
    var layerRows: [(id: UUID, isDrawing: Bool)] {
        annotations.reversed().map { ($0.id, true) } + pairs.reversed().map { ($0.shape.id, false) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { layerRows.count }

    /// Automatic layer name: kind plus number within its kind (or the text itself).
    func layerName(of id: UUID) -> String {
        if let index = pairs.firstIndex(where: { $0.shape.id == id }) {
            if let name = pairs[index].effect.name, !name.isEmpty { return name }
            let kind: String
            switch pairs[index].shape {
            case .rectangle: kind = "사각형"
            case .ellipse: kind = "원"
            case .polygon: kind = "자유형"
            }
            let cover = ["블러", "모자이크", "단색"][RegionEffect.CoverStyle.allCases.firstIndex(of: pairs[index].effect.style) ?? 0]
            return "\(cover) \(kind) \(index + 1)"
        }
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return "" }
        let drawing = annotations[index]
        if let name = drawing.name, !name.isEmpty { return name }
        switch drawing.kind {
        case .text: return "글자 “\(drawing.text.replacingOccurrences(of: "\n", with: " ").prefix(16))”"
        case .rectangle: return "사각형 그림 \(index + 1)"
        case .ellipse: return "타원 그림 \(index + 1)"
        case .line: return "선 \(index + 1)"
        case .arrow: return "화살표 \(index + 1)"
        case .freehand: return "펜 \(index + 1)"
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let rows = layerRows
        guard row >= 0, row < rows.count else { return nil }
        let item = rows[row]
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        let image = NSImageView()
        let text = NSTextField(labelWithString: layerName(of: item.id))
        text.lineBreakMode = .byTruncatingTail
        text.font = .systemFont(ofSize: 13, weight: .medium)
        let detail = NSTextField(labelWithString: "")
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let eye = NSButton(image: NSImage(), target: self, action: #selector(toggleLayerVisibility(_:)))
        let lock = NSButton(image: NSImage(), target: self, action: #selector(toggleLayerLock(_:)))
        for button in [eye, lock] {
            button.isBordered = false
            button.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
            button.imageScaling = .scaleProportionallyDown
        }
        let hidden: Bool, locked: Bool, timing: ClosedRange<Double>, motion: Bool, grouped: Bool, active: Bool
        if item.isDrawing, let drawing = annotations.first(where: { $0.id == item.id }) {
            hidden = drawing.hidden; locked = drawing.locked; timing = drawing.timeRange
            motion = !drawing.keyframes.isEmpty; grouped = drawing.groupID != nil
            active = drawing.isVisible(at: doc.hasVideo ? canvas.currentVideoTime : nil)
            let symbol: String
            switch drawing.kind {
            case .text: symbol = "textformat"
            case .arrow: symbol = "arrow.up.right"
            case .line: symbol = "line.diagonal"
            case .freehand: symbol = "scribble"
            case .ellipse: symbol = "circle"
            case .rectangle: symbol = "rectangle"
            }
            image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "그림")
            image.contentTintColor = drawing.color
        } else if let pair = pairs.first(where: { $0.shape.id == item.id }) {
            hidden = !pair.effect.enabled; locked = pair.effect.locked; timing = pair.effect.timeRange
            motion = !pair.effect.keyframes.isEmpty; grouped = pair.effect.groupID != nil
            active = pair.effect.isActive(at: doc.hasVideo ? canvas.currentVideoTime : nil)
            let symbol: String
            switch pair.shape {
            case .rectangle: symbol = "rectangle.fill"
            case .ellipse: symbol = "circle.fill"
            case .polygon: symbol = "pentagon.fill"
            }
            image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "블러 영역")
            image.contentTintColor = active ? .systemBlue : .systemGray
        } else { return nil }
        var details: [String] = []
        if doc.hasVideo { details.append(timing.lowerBound == 0 && timing.upperBound == 0 ? "전체" : "\(format(timing.lowerBound))~\(format(timing.upperBound))") }
        if motion { details.append("이동") }
        if grouped { details.append("그룹") }
        detail.stringValue = details.joined(separator: " · ")
        text.textColor = hidden ? .tertiaryLabelColor : .labelColor
        eye.image = NSImage(systemSymbolName: hidden ? "eye.slash" : "eye", accessibilityDescription: hidden ? "숨김" : "보임")
        eye.toolTip = hidden ? "보이기 (미리보기와 내보내기에 포함)" : "숨기기 (미리보기와 내보내기에서 빠짐)"
        eye.setAccessibilityLabel(hidden ? "\(text.stringValue) 보이기" : "\(text.stringValue) 숨기기")
        lock.image = NSImage(systemSymbolName: locked ? "lock.fill" : "lock.open", accessibilityDescription: locked ? "잠김" : "풀림")
        lock.toolTip = locked ? "잠금 풀기" : "잠그기 (캔버스에서 선택·이동·지우기 막기)"
        lock.setAccessibilityLabel(locked ? "\(text.stringValue) 잠금 풀기" : "\(text.stringValue) 잠그기")
        lock.contentTintColor = locked ? .systemOrange : .tertiaryLabelColor
        if currentSelectionID == item.id {
            container.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.25).cgColor
            container.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.65).cgColor
            container.layer?.borderWidth = 1
        } else if multiSelection.contains(item.id) {
            container.layer?.backgroundColor = NSColor.systemPurple.withAlphaComponent(0.12).cgColor
        }
        for view in [image, text, detail, eye, lock] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            image.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 18), image.heightAnchor.constraint(equalToConstant: 18),
            lock.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            lock.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            lock.widthAnchor.constraint(equalToConstant: 18), lock.heightAnchor.constraint(equalToConstant: 18),
            eye.trailingAnchor.constraint(equalTo: lock.leadingAnchor, constant: -4),
            eye.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            eye.widthAnchor.constraint(equalToConstant: 20), eye.heightAnchor.constraint(equalToConstant: 18),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
            text.trailingAnchor.constraint(lessThanOrEqualTo: eye.leadingAnchor, constant: -4),
            detail.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            detail.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 2),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: eye.leadingAnchor, constant: -4)
        ])
        return container
    }

    private func isEffectActive(_ effect: RegionEffect, at time: Double) -> Bool {
        effect.isActive(at: time)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !refreshingList else { return }
        let rows = layerRows
        let picked = regionList.selectedRowIndexes.filter { $0 < rows.count }.map { rows[$0].id }
        guard !picked.isEmpty else { return }
        if picked.count > 1 {
            // Several rows: they become the multi-selection (group, delete, track together).
            let primary = rows.indices.contains(regionList.selectedRow) ? rows[regionList.selectedRow].id : picked[0]
            multiSelection = picked
            selectItem(primary)
            multiSelection = picked
            workflowHint.stringValue = "\(picked.count)개 선택됨 · ⌘G 그룹, Delete 삭제, 자동 추적은 함께 따라갑니다."
            canvas.refreshOverlay()
        } else {
            multiSelection.removeAll()
            selectItem(picked[0])
        }
        refreshSelectedEditor()
        liveBlur.refresh()
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let rows = layerRows
        guard !isExporting, rows.indices.contains(row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(rows[row].id.uuidString, forType: .blurActionLayerRow)
        return item
    }

    /// The one dragged layer. Dragging several selected rows carries one item per row and moves nothing,
    /// so the row under the pointer is never confused with the first selected row.
    private func draggedLayerID(_ info: NSDraggingInfo) -> UUID? {
        guard (info.draggingSource as? NSTableView) === regionList,
              let items = info.draggingPasteboard.pasteboardItems, items.count == 1,
              let text = items[0].string(forType: .blurActionLayerRow) else { return nil }
        return UUID(uuidString: text)
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        if rowIndexes.count > 1 { workflowHint.stringValue = "레이어 순서는 한 번에 한 줄씩 끌어서 바꿉니다." }
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard dropOperation == .above, let id = draggedLayerID(info),
              let from = layerRows.firstIndex(where: { $0.id == id }) else { return [] }
        let drawingCount = annotations.count
        return (layerRows[from].isDrawing ? row <= drawingCount : row >= drawingCount) ? .move : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let id = draggedLayerID(info) else { return false }
        return moveLayer(id, toRow: row)
    }

    /// 레이어 행 우클릭 — 캔버스 우클릭과 같은 메뉴(+ 이름 바꾸기·숨기기·잠금)
    func tableView(_ tableView: NSTableView, menuFor event: NSEvent) -> NSMenu? {
        let rows = layerRows
        let row = tableView.row(at: tableView.convert(event.locationInWindow, from: nil))
        guard row >= 0, row < rows.count else { return nil }
        let id = rows[row].id
        selectItem(id)
        refreshSelectedEditor()
        showRegionContextMenu(for: id, at: .zero, fromList: true)
        return nil
    }
}

final class RegionTableView: NSTableView {
    var contextMenuHandler: ((NSEvent) -> Void)?
    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuHandler?(event)
        return nil
    }
}

final class FlippedDocumentView: NSView { override var isFlipped: Bool { true } }

extension NSPasteboard.PasteboardType {
    static let blurActionLayerRow = NSPasteboard.PasteboardType("local.piman.BlurAction.layer-row")
}
