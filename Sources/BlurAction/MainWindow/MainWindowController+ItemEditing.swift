import AppKit
import AVKit
import AVFoundation
import UniformTypeIdentifiers
import os
import Darwin

// MainWindowController: 레이어 순서 끌기, 그리기·지우기·복제, 그룹, 레이어 속성, 겹침 순서.

extension MainWindowController {
    // MARK: - Layer list: drag to reorder

    /// Moves a layer to sit above list row `row` (top of the list = front). Drawings move among
    /// drawings and regions among regions. One undo step. Internal for tests.
    @discardableResult
    func moveLayer(_ id: UUID, toRow row: Int) -> Bool {
        guard !isExporting else { return false }
        let rows = layerRows
        guard let from = rows.firstIndex(where: { $0.id == id }), row >= 0, row <= rows.count else { return false }
        let drawingCount = annotations.count
        func reordered<T>(_ topFirst: [T], from: Int, to: Int) -> [T]? {
            var items = topFirst
            let item = items.remove(at: from)
            let destination = to > from ? to - 1 : to
            guard destination != from, destination >= 0, destination <= items.count else { return nil }
            items.insert(item, at: destination)
            return items
        }
        if rows[from].isDrawing {
            guard row <= drawingCount, let top = reordered(Array(annotations.reversed()), from: from, to: row) else { return false }
            endGesture(); checkpoint()
            annotations = top.reversed()
        } else {
            guard row >= drawingCount,
                  let top = reordered(Array(pairs.reversed()), from: from - drawingCount, to: row - drawingCount) else { return false }
            endGesture(); checkpoint()
            pairs = top.reversed()
        }
        refreshAfterEdit()
        return true
    }

    @objc func pickHiddenChanged(_ sender: NSButton) {
        canvas.resetInteraction()
        canvas.refreshOverlay()
    }

    private var hasEffectiveBlur: Bool {
        pairs.contains { pair in
            let effect = pair.effect
            let rect = pair.shape.boundingRect
            guard effect.enabled, effect.blurRadius.isFinite, effect.style == .solid || effect.blurRadius > 0,
                  rect.width > 0, rect.height > 0 else { return false }
            guard doc.hasVideo, !effect.appliesToEntireVideo else { return true }
            return effect.timeRange.lowerBound < doc.duration && effect.timeRange.upperBound > 0
                && effect.timeRange.lowerBound < effect.timeRange.upperBound
        }
    }

    var hasEffectiveEffect: Bool {
        if hasEffectiveBlur || annotations.contains(where: { !$0.hidden }) { return true }
        return pageWorkspace?.pages.contains { page in
            page.regions.contains(where: { $0.effect.enabled }) || page.drawings.contains(where: { !$0.hidden })
        } ?? false
    }

    // MARK: - Drawings, erasing, duplicating

    func refreshAfterEdit() {
        canvas.refreshOverlay()
        liveBlur.refresh()
        refreshRegionList()
        refreshSelectedEditor()
    }

    func addAnnotation(_ created: DrawingAnnotation) {
        guard !isExporting else { return }
        var drawing = created
        if doc.hasVideo {
            // Like regions: a new drawing shows from the time it was started to the end.
            let start = canvas.creationStartTime ?? playheadTime ?? 0
            drawing.timeRange = min(doc.duration, max(0, start))...doc.duration
        }
        if gestureSnapshot == nil { checkpoint() }
        annotations.append(drawing)
        // Select on the canvas too (text is placed from a prompt, not a canvas drag).
        canvas.selectAnnotation(id: drawing.id)
        refreshAfterEdit()
    }

    func editAnnotation(_ edited: DrawingAnnotation) {
        guard !isExporting, let index = annotations.firstIndex(where: { $0.id == edited.id }) else { return }
        let anchor = gestureStartTime.flatMap { time in
            gestureAnnotations?.first(where: { $0.id == edited.id }).map { (time: time, annotation: $0) }
        }
        let before = annotations[index]
        let updated = before.applyingEdit(edited, time: editTime, recording: motionRecording, anchor: anchor)
        guard updated != before else { return }
        if gestureSnapshot == nil { checkpoint() }
        annotations[index] = updated
        if let move = groupMove(from: before.displayed(at: editTime).bounds, to: edited.bounds, group: before.groupID) {
            moveGroupMembers(move, except: before.id)
        }
        refreshAfterEdit()
    }

    func eraseItems(regions: Set<UUID>, drawings: Set<UUID>) {
        guard !isExporting else { return }
        let keptPairs = pairs.filter { !regions.contains($0.shape.id) }
        let keptDrawings = annotations.filter { !drawings.contains($0.id) }
        guard keptPairs.count != pairs.count || keptDrawings.count != annotations.count else { return }
        if gestureSnapshot == nil { checkpoint() }
        pairs = keptPairs
        annotations = keptDrawings
        if let id = selectedID, regions.contains(id) { selectedID = nil }
        if let id = selectedDrawingID, drawings.contains(id) { selectedDrawingID = nil }
        canvas.setRegionsFromExternal(pairs.map(\.shape))
        refreshAfterEdit()
    }

    enum ClearScope { case regions, drawings, all }

    @objc func clearRegionsTapped() { confirmClear(.regions) }
    @objc func clearDrawingsTapped() { confirmClear(.drawings) }
    @objc func clearAllTapped() { confirmClear(.all) }

    private func confirmClear(_ scope: ClearScope) {
        guard !isExporting else { return }
        let count = (scope == .drawings ? 0 : pairs.count) + (scope == .regions ? 0 : annotations.count)
        guard count > 0 else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = scope == .regions ? "블러 영역 \(pairs.count)개를 모두 지울까요?"
            : scope == .drawings ? "그림 \(annotations.count)개를 모두 지울까요?" : "영역과 그림 \(count)개를 모두 지울까요?"
        alert.informativeText = "⌘Z로 되돌릴 수 있습니다."
        alert.addButton(withTitle: "지우기")
        alert.addButton(withTitle: "취소")
        guard let window else { clearItems(scope); return }
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.clearItems(scope) }
        }
    }

    /// One undo step. Internal for tests (the confirmation sheet cannot be clicked there).
    func clearItems(_ scope: ClearScope) {
        endGesture()
        // Locked layers are kept.
        eraseItems(regions: scope == .drawings ? [] : Set(pairs.filter { !$0.effect.locked }.map(\.shape.id)),
                   drawings: scope == .regions ? [] : Set(annotations.filter { !$0.locked }.map(\.id)))
    }

    /// ⌘D: copies the selected item, or its whole group (as a new group), 12pt down-right.
    @objc func duplicateSelectedTapped() {
        guard !isExporting, let selected = currentSelectionID else { NSSound.beep(); return }
        endGesture()
        let dx: CGFloat = 12, dy: CGFloat = -12
        func moved(_ r: CGRect) -> CGRect { r.offsetBy(dx: dx, dy: dy) }
        let group = groupIDOfItem(selected)
        let newGroup: UUID? = group == nil ? nil : UUID()
        func included(_ id: UUID, _ itemGroup: UUID?) -> Bool { id == selected || (group != nil && itemGroup == group) }
        var copiedSelection: UUID?
        var newDrawings: [DrawingAnnotation] = []
        for drawing in annotations where included(drawing.id, drawing.groupID) {
            var copy = drawing
            copy.id = UUID()
            copy.groupID = newGroup
            copy.name = drawing.name.map { $0 + " 사본" }
            copy.points = drawing.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            copy.erasures = drawing.replacingBounds(drawing.bounds.offsetBy(dx: dx, dy: dy)).erasures
            copy.keyframes = drawing.keyframes.map { RegionKeyframe(time: $0.time, rect: moved($0.rect)) }
            if drawing.id == selected { copiedSelection = copy.id }
            newDrawings.append(copy)
        }
        var newPairs: [RegionEditing.Pair] = []
        for pair in pairs where included(pair.shape.id, pair.effect.groupID) {
            let newID = UUID()
            let shape: RegionShape
            switch pair.shape {
            case .rectangle(_, let o, let size): shape = .rectangle(id: newID, origin: CGPoint(x: o.x + dx, y: o.y + dy), size: size)
            case .ellipse(_, let o, let size): shape = .ellipse(id: newID, origin: CGPoint(x: o.x + dx, y: o.y + dy), size: size)
            case .polygon(_, let points): shape = .polygon(id: newID, points: points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) })
            }
            var effect = pair.effect
            effect.groupID = newGroup
            effect.name = pair.effect.name.map { $0 + " 사본" }
            effect.keyframes = effect.keyframes.map { RegionKeyframe(time: $0.time, rect: moved($0.rect)) }
            effect.erasures = effect.erasures.map { $0.mapped(from: pair.shape.boundingRect, to: shape.boundingRect) }
            if pair.shape.id == selected { copiedSelection = newID }
            newPairs.append((shape, effect))
        }
        guard let copiedSelection else { NSSound.beep(); return }
        checkpoint()
        annotations.append(contentsOf: newDrawings)
        pairs.append(contentsOf: newPairs)
        if newPairs.contains(where: { $0.shape.id == copiedSelection }) { canvas.selectRegion(id: copiedSelection) }
        else { canvas.selectAnnotation(id: copiedSelection) }
        if newGroup != nil { workflowHint.stringValue = "그룹 전체(\(newDrawings.count + newPairs.count)개)를 복제했습니다." }
        refreshAfterEdit()
    }

    func handleShortcut(_ key: Character) -> Bool {
        switch key {
        case "b": selectTool(0)
        case "d": selectTool(1)
        case "e": selectTool(2)
        case "i": startColorPick(toolSegment.selectedSegment == 1 ? .drawing : .cover)
        case ",": previousFrame()
        case ".": nextFrame()
        case "<": previousKeyframe()
        case ">": nextKeyframe()
        default: return false
        }
        return true
    }

    private func selectTool(_ index: Int) {
        guard !isExporting, toolSegment.selectedSegment != index else { return }
        toolSegment.selectedSegment = index
        toolChanged(toolSegment)
    }

    // MARK: - Grouping

    var currentSelectionID: UUID? { selectedID ?? selectedDrawingID }

    func groupIDOfItem(_ id: UUID) -> UUID? {
        if let pair = pairs.first(where: { $0.shape.id == id }) { return pair.effect.groupID }
        return annotations.first(where: { $0.id == id })?.groupID
    }

    private func displayedBounds(of id: UUID) -> CGRect? {
        if let pair = pairs.first(where: { $0.shape.id == id }) { return RegionEditing.displayed(pair, at: editTime).boundingRect }
        return annotations.first(where: { $0.id == id }).map { $0.displayed(at: editTime).bounds }
    }

    func toggleMultiSelection(_ id: UUID) {
        if multiSelection.isEmpty, let current = currentSelectionID, current != id { multiSelection.append(current) }
        if let index = multiSelection.firstIndex(of: id) { multiSelection.remove(at: index) } else { multiSelection.append(id) }
        workflowHint.stringValue = multiSelection.count >= 2
            ? "\(multiSelection.count)개 선택됨 · ⌘G 또는 [그룹 만들기]로 묶습니다."
            : "Shift+클릭으로 묶을 항목을 더 고르세요."
        canvas.refreshOverlay()
    }

    func selectionDecorations() -> (multi: [CGRect], group: CGRect?) {
        let multi = multiSelection.compactMap { displayedBounds(of: $0) }
        guard let current = currentSelectionID, let group = groupIDOfItem(current) else { return (multi, nil) }
        let members = pairs.filter { $0.effect.groupID == group }.map(\.shape.id) + annotations.filter { $0.groupID == group }.map(\.id)
        let union = members.compactMap { displayedBounds(of: $0) }.reduce(CGRect.null) { $0.union($1) }
        return (multi, union.isNull ? nil : union)
    }

    @objc func groupTapped() {
        guard !isExporting else { return }
        var ids = multiSelection
        if let current = currentSelectionID, !ids.contains(current) { ids.append(current) }
        ids = ids.filter { keyframesOfItem($0) != nil }
        guard ids.count >= 2 else {
            NSSound.beep()
            workflowHint.stringValue = "Shift+클릭으로 두 개 이상 고른 뒤 묶으세요."
            return
        }
        endGesture()
        checkpoint()
        let group = UUID()
        for index in pairs.indices where ids.contains(pairs[index].shape.id) { pairs[index].effect.groupID = group }
        for index in annotations.indices where ids.contains(annotations[index].id) { annotations[index].groupID = group }
        multiSelection.removeAll()
        workflowHint.stringValue = "\(ids.count)개를 그룹으로 묶었습니다. 하나를 옮기면 함께 움직입니다."
        refreshAfterEdit()
    }

    @objc func ungroupTapped() {
        guard !isExporting else { return }
        let groups = Set((multiSelection + [currentSelectionID].compactMap { $0 }).compactMap { groupIDOfItem($0) })
        guard !groups.isEmpty else { NSSound.beep(); return }
        endGesture()
        checkpoint()
        for index in pairs.indices where pairs[index].effect.groupID.map(groups.contains) == true { pairs[index].effect.groupID = nil }
        for index in annotations.indices where annotations[index].groupID.map(groups.contains) == true { annotations[index].groupID = nil }
        multiSelection.removeAll()
        workflowHint.stringValue = "그룹을 풀었습니다."
        refreshAfterEdit()
    }

    /// Equal up to rounding (a polygon moved by its box is not bit-identical).
    static func sameGeometry(_ a: RegionShape, _ b: RegionShape) -> Bool {
        func points(_ shape: RegionShape) -> [CGPoint] {
            if case .polygon(_, let pts) = shape { return pts }
            let r = shape.boundingRect
            return [r.origin, CGPoint(x: r.maxX, y: r.maxY)]
        }
        let pa = points(a), pb = points(b)
        return pa.count == pb.count && zip(pa, pb).allSatisfy { abs($0.x - $1.x) < 0.01 && abs($0.y - $1.y) < 0.01 }
    }

    /// A grouped item's box change; the other members get the same change relative to it.
    struct GroupChange {
        let group: UUID
        let from: CGRect
        let to: CGRect

        /// Maps another member's box: same offset for a move, scaled about the edited box for a resize.
        func apply(_ rect: CGRect) -> CGRect {
            let sx = from.width > 0 ? to.width / from.width : 1
            let sy = from.height > 0 ? to.height / from.height : 1
            return CGRect(x: to.minX + (rect.minX - from.minX) * sx, y: to.minY + (rect.minY - from.minY) * sy,
                          width: rect.width * sx, height: rect.height * sy)
        }
    }

    func groupMove(from old: CGRect, to new: CGRect, group: UUID?) -> GroupChange? {
        guard let group, old != new else { return nil }
        return GroupChange(group: group, from: old, to: new)
    }

    /// Applies the same box change to the other members of a group, with the same motion rules.
    func moveGroupMembers(_ move: GroupChange, except source: UUID) {
        let shapes = pairs.map { pair -> RegionShape in
            let shown = RegionEditing.displayed(pair, at: editTime)
            guard pair.effect.groupID == move.group, pair.shape.id != source, !pair.effect.locked else { return shown }
            return shown.replacing(rect: move.apply(shown.boundingRect))
        }
        pairs = preservingReviewExterior(RegionEditing.updating(shapes, in: pairs, time: editTime, recording: motionRecording,
                                       anchorTime: gestureStartTime, anchorPairs: gestureSnapshot), before: pairs)
        for index in annotations.indices where annotations[index].groupID == move.group && annotations[index].id != source
            && !annotations[index].locked {
            let shown = annotations[index].displayed(at: editTime)
            let moved = shown.replacingBounds(move.apply(shown.bounds))
            let anchor = gestureStartTime.flatMap { time in
                gestureAnnotations?.first(where: { $0.id == moved.id }).map { (time: time, annotation: $0) }
            }
            annotations[index] = annotations[index].applyingEdit(moved, time: editTime, recording: motionRecording, anchor: anchor)
        }
    }

    // MARK: - Layers: name, visibility, lock

    func layerState(_ id: UUID) -> (hidden: Bool, locked: Bool) {
        if let pair = pairs.first(where: { $0.shape.id == id }) { return (!pair.effect.enabled, pair.effect.locked) }
        if let drawing = annotations.first(where: { $0.id == id }) { return (drawing.hidden, drawing.locked) }
        return (false, false)
    }

    /// Hidden = left out of preview and export (regions use `enabled`). Internal for tests.
    func setLayerHidden(_ id: UUID, _ hidden: Bool) {
        guard !isExporting else { return }
        if !hidden, var drawing = annotations.first(where: { $0.id == id }) {
            drawing.hidden = false
            do { try VideoProjectFile.requireAvailableFonts([drawing]) }
            catch { showError(error.localizedDescription); return }
        }
        endGesture()
        if let index = pairs.firstIndex(where: { $0.shape.id == id }), pairs[index].effect.enabled == hidden {
            checkpoint()
            pairs[index].effect.enabled = !hidden
        } else if let index = annotations.firstIndex(where: { $0.id == id }), annotations[index].hidden != hidden {
            checkpoint()
            annotations[index].hidden = hidden
            if hidden, selectedDrawingID == id {
                // A hidden drawing is off the canvas; don't keep it as the target of Delete.
                selectedDrawingID = nil
                canvas.clearAnnotationSelection()
            }
        } else { return }
        refreshAfterEdit()
    }

    /// Locked = cannot be picked, moved or erased on the canvas. Internal for tests.
    func setLayerLocked(_ id: UUID, _ locked: Bool) {
        guard !isExporting else { return }
        endGesture()
        if let index = pairs.firstIndex(where: { $0.shape.id == id }), pairs[index].effect.locked != locked {
            checkpoint()
            pairs[index].effect.locked = locked
        } else if let index = annotations.firstIndex(where: { $0.id == id }), annotations[index].locked != locked {
            checkpoint()
            annotations[index].locked = locked
        } else { return }
        refreshAfterEdit()
    }

    /// Empty or whitespace names fall back to the automatic name. Internal for tests.
    func renameLayer(_ id: UUID, to name: String) {
        guard !isExporting else { return }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let value: String? = trimmed.isEmpty ? nil : trimmed
        endGesture()
        if let index = pairs.firstIndex(where: { $0.shape.id == id }), pairs[index].effect.name != value {
            checkpoint()
            pairs[index].effect.name = value
        } else if let index = annotations.firstIndex(where: { $0.id == id }), annotations[index].name != value {
            checkpoint()
            annotations[index].name = value
        } else { return }
        refreshAfterEdit()
    }

    private func layerID(from sender: Any?) -> UUID? {
        if let item = sender as? NSMenuItem { return item.representedObject as? UUID }
        return (sender as? NSView)?.identifier.flatMap { UUID(uuidString: $0.rawValue) }
    }

    @objc func toggleLayerVisibility(_ sender: Any?) {
        guard let id = layerID(from: sender) else { return }
        setLayerHidden(id, !layerState(id).hidden)
    }

    @objc func toggleLayerLock(_ sender: Any?) {
        guard let id = layerID(from: sender) else { return }
        setLayerLocked(id, !layerState(id).locked)
    }

    @objc func toggleVisibilityFromMenu(_ sender: NSMenuItem) { toggleLayerVisibility(sender) }
    @objc func toggleLockFromMenu(_ sender: NSMenuItem) { toggleLayerLock(sender) }

    @objc func reverseFromMenu(_ sender: NSMenuItem) {
        guard let id = layerID(from: sender) else { return }
        setLayerReversed(id, !(pairs.first { $0.shape.id == id }?.effect.inverted ?? false))
    }

    /// Keeps the selected shape and covers the rest of the frame (video only). Internal for tests.
    func setLayerReversed(_ id: UUID, _ reversed: Bool) {
        guard !isExporting, doc.hasVideo,
              let index = pairs.firstIndex(where: { $0.shape.id == id }),
              pairs[index].effect.inverted != reversed else { return }
        if reversed, !pairs[index].effect.erasures.isEmpty {
            showError("지우개로 지운 부분이 있는 영역은 역가림으로 바꿀 수 없습니다. 지운 부분을 되돌린 뒤 다시 시도하세요.")
            return
        }
        if reversed, pairs[index].effect.decoration != nil {
            workflowHint.stringValue = "붙인 글자·이모지를 먼저 없앤 뒤 역가림으로 바꿔 주세요."
            return
        }
        endGesture()
        checkpoint()
        pairs[index].effect.inverted = reversed
        refreshAfterEdit()
    }

    @objc func renameFromMenu(_ sender: NSMenuItem) {
        guard let id = layerID(from: sender) else { return }
        promptRename(id)
    }

    @objc func layerDoubleClicked() {
        let rows = layerRows
        let row = regionList.clickedRow
        guard row >= 0, row < rows.count else { return }
        promptRename(rows[row].id)
    }

    private func promptRename(_ id: UUID) {
        let alert = NSAlert()
        alert.messageText = "레이어 이름"
        alert.informativeText = "비워 두면 자동 이름을 씁니다."
        let field = NSTextField(string: layerName(of: id))
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        // Leaving the shown (possibly automatic) name unchanged must not freeze it as a custom name.
        guard alert.runModal() == .alertFirstButtonReturn, field.stringValue != layerName(of: id) else { return }
        renameLayer(id, to: field.stringValue)
    }

    // MARK: - Stacking order

    enum StackMove { case forward, backward, front, back }

    @objc func bringForwardTapped() { restack(.forward) }
    @objc func sendBackwardTapped() { restack(.backward) }
    @objc func bringToFrontTapped() { restack(.front) }
    @objc func sendToBackTapped() { restack(.back) }

    private func restacked<T>(_ items: [T], index: Int, _ move: StackMove) -> [T] {
        var result = items
        let item = result.remove(at: index)
        switch move {
        case .forward: result.insert(item, at: min(result.count, index + 1))
        case .backward: result.insert(item, at: max(0, index - 1))
        case .front: result.append(item)
        case .back: result.insert(item, at: 0)
        }
        return result
    }

    /// Later items draw on top: blur regions among regions, drawings among drawings
    /// (drawings always sit above regions).
    func restack(_ move: StackMove) {
        guard !isExporting else { return }
        endGesture()
        if let id = selectedID, let index = pairs.firstIndex(where: { $0.shape.id == id }) {
            let result = restacked(pairs, index: index, move)
            guard !RegionEditing.equal(result, pairs) else { return }
            checkpoint()
            pairs = result
        } else if let id = selectedDrawingID, let index = annotations.firstIndex(where: { $0.id == id }) {
            let result = restacked(annotations, index: index, move)
            guard result != annotations else { return }
            checkpoint()
            annotations = result
        } else { NSSound.beep(); return }
        refreshAfterEdit()
    }
}
