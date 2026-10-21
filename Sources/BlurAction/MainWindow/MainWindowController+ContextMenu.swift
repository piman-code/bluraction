import AppKit
import AVKit
import AVFoundation
import UniformTypeIdentifiers
import os
import Darwin

// MainWindowController: 우클릭 메뉴.

extension MainWindowController {
    // MARK: - Context menu

    func showRegionContextMenu(for id: UUID?, at pt: NSPoint) {
        showRegionContextMenu(for: id, at: pt, fromList: false)
    }

    func showItemContextMenu(for id: UUID, at pt: NSPoint) {
        showRegionContextMenu(for: id, at: pt, fromList: false)
    }

    func showRegionContextMenu(for id: UUID?, at pt: NSPoint, fromList: Bool) {
        guard !isExporting else { return }
        let menu = makeRegionContextMenu(for: id)
        if fromList {
            // 사이드바 행 우클릭: 행의 우측에 표시
            if let view = regionList.window?.contentView {
                let row = layerRows.firstIndex(where: { $0.id == id }) ?? -1
                if row >= 0 {
                    let rectInWindow = regionList.convert(regionList.rect(ofRow: row), to: nil)
                    let locationInView = view.convert(rectInWindow.origin, from: nil)
                    menu.popUp(positioning: nil, at: NSPoint(x: locationInView.x + 200, y: locationInView.y), in: view)
                }
            }
        } else if let view = canvas.window?.contentView {
            let locationInView = view.convert(pt, from: canvas)
            menu.popUp(positioning: nil, at: locationInView, in: view)
        }
    }

    private static let durationPresets: [Double] = [0.5, 1, 3, 5, 10]
    private struct DurationPreset {
        let regionID: UUID
        let start: Double?
        let seconds: Double
    }

    /// Shared by canvas and list; kept separate from the blocking menu popup for verification.
    func makeRegionContextMenu(for id: UUID?) -> NSMenu {
        let menu = NSMenu(title: "영역")
        menu.autoenablesItems = false
        guard !isExporting, let id, let keyframes = keyframesOfItem(id) else { return menu }
        let isDrawing = !pairs.contains(where: { $0.shape.id == id })
        if doc.hasVideo {
            let start = playheadTime // Freeze the menu-open playhead while playback may continue.
            for (index, seconds) in Self.durationPresets.enumerated() {
                let label = seconds == 0.5 ? "0.5" : String(Int(seconds))
                let item = NSMenuItem(title: "현재 위치부터 \(label)초", action: #selector(applyDurationPreset(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = DurationPreset(regionID: id, start: start, seconds: seconds)
                item.tag = index
                item.isEnabled = start.map {
                    RegionEffect.durationRange(startingAt: $0, seconds: seconds, videoDuration: doc.duration) != nil
                } ?? false
                menu.addItem(item)
            }
            let entire = NSMenuItem(title: "영상 전체", action: #selector(applyEntireVideoFromMenu(_:)), keyEquivalent: "")
            entire.target = self
            entire.representedObject = id
            menu.addItem(entire)
            menu.addItem(NSMenuItem.separator())
        }
        let reset = NSMenuItem(title: "이동 기록 지우기", action: #selector(clearMotion(_:)), keyEquivalent: "")
        reset.target = self; reset.representedObject = id
        reset.isEnabled = !keyframes.isEmpty
        menu.addItem(reset)
        let rename = NSMenuItem(title: "이름 바꾸기…", action: #selector(renameFromMenu(_:)), keyEquivalent: "")
        rename.target = self; rename.representedObject = id
        menu.addItem(rename)
        let state = layerState(id)
        let visibility = NSMenuItem(title: state.hidden ? "보이기" : "숨기기", action: #selector(toggleVisibilityFromMenu(_:)), keyEquivalent: "")
        visibility.target = self; visibility.representedObject = id
        menu.addItem(visibility)
        let lockItem = NSMenuItem(title: state.locked ? "잠금 풀기" : "잠그기", action: #selector(toggleLockFromMenu(_:)), keyEquivalent: "")
        lockItem.target = self; lockItem.representedObject = id
        menu.addItem(lockItem)
        // Reverse covers are video-only: their project format (4) is refused by older apps.
        if doc.hasVideo, let pair = pairs.first(where: { $0.shape.id == id }) {
            let reverse = NSMenuItem(title: pair.effect.inverted ? "역가림 끄기" : "역가림 (이 영역만 남기고 나머지 가리기)",
                                     action: #selector(reverseFromMenu(_:)), keyEquivalent: "")
            reverse.target = self; reverse.representedObject = id
            // Rubbed-out parts have no meaning on a reverse cover; clear them first.
            reverse.isEnabled = pair.effect.inverted || pair.effect.erasures.isEmpty
            reverse.toolTip = reverse.isEnabled ? nil : "지우개로 지운 부분을 먼저 되돌려야 바꿀 수 있습니다."
            menu.addItem(reverse)
        }
        let duplicate = NSMenuItem(title: "복제", action: #selector(duplicateFromMenu(_:)), keyEquivalent: "")
        duplicate.target = self; duplicate.representedObject = id
        menu.addItem(duplicate)
        for (index, title) in ["맨 앞으로", "앞으로", "뒤로", "맨 뒤로"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(restackFromMenu(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = id; item.tag = index
            menu.addItem(item)
        }
        if annotations.first(where: { $0.id == id })?.erasures.isEmpty == false
            || pairs.first(where: { $0.shape.id == id })?.effect.erasures.isEmpty == false {
            let restore = NSMenuItem(title: "지운 부분 되살리기", action: #selector(restoreErasedFromMenu(_:)), keyEquivalent: "")
            restore.target = self; restore.representedObject = id
            menu.addItem(restore)
        }
        if groupIDOfItem(id) != nil {
            let ungroup = NSMenuItem(title: "그룹 풀기", action: #selector(ungroupFromMenu(_:)), keyEquivalent: "")
            ungroup.target = self; ungroup.representedObject = id
            menu.addItem(ungroup)
        }
        menu.addItem(NSMenuItem.separator())
        let delItem = NSMenuItem(title: isDrawing ? "그림 삭제" : "영역 삭제", action: #selector(deleteRegionFromMenu(_:)), keyEquivalent: "")
        delItem.target = self
        delItem.representedObject = id
        menu.addItem(delItem)
        return menu
    }

    func keyframesOfItem(_ id: UUID) -> [RegionKeyframe]? {
        if let pair = pairs.first(where: { $0.shape.id == id }) { return pair.effect.keyframes }
        return annotations.first(where: { $0.id == id })?.keyframes
    }

    func selectItem(_ id: UUID) {
        if pairs.contains(where: { $0.shape.id == id }) { canvas.selectRegion(id: id) }
        else if annotations.contains(where: { $0.id == id }) { canvas.selectAnnotation(id: id) }
    }

    @objc private func applyDurationPreset(_ sender: NSMenuItem) {
        guard doc.hasVideo, !isExporting, let preset = sender.representedObject as? DurationPreset,
              keyframesOfItem(preset.regionID) != nil, let time = preset.start,
              let range = RegionEffect.durationRange(startingAt: time, seconds: preset.seconds, videoDuration: doc.duration) else { return }
        endGesture()
        selectItem(preset.regionID)
        setSelectedTimeRange(range)
        refreshSelectedEditor()
    }

    @objc private func applyEntireVideoFromMenu(_ sender: NSMenuItem) {
        guard doc.hasVideo, !isExporting, let id = sender.representedObject as? UUID,
              keyframesOfItem(id) != nil else { return }
        selectItem(id)
        applyEntireVideo()
    }

    @objc private func clearMotion(_ sender: NSMenuItem) {
        guard !isExporting, let id = sender.representedObject as? UUID else { return }
        endGesture()
        if let index = pairs.firstIndex(where: { $0.shape.id == id }) {
            checkpoint()
            let frozen = RegionEditing.displayed(pairs[index], at: editTime)
            pairs[index].effect.erasures = pairs[index].effect.erasures.map {
                $0.mapped(from: pairs[index].shape.boundingRect, to: frozen.boundingRect)
            }
            pairs[index].shape = frozen
            pairs[index].effect.automaticCover = nil
            pairs[index].effect.keyframes = []
        } else if let index = annotations.firstIndex(where: { $0.id == id }) {
            checkpoint()
            let frozen = annotations[index].displayed(at: editTime)
            annotations[index].points = frozen.points
            annotations[index].erasures = frozen.erasures
            annotations[index].keyframes = []
        } else { return }
        refreshAfterEdit()
    }

    @objc private func restackFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        selectItem(id)
        restack([StackMove.front, .forward, .backward, .back][max(0, min(3, sender.tag))])
    }

    @objc private func ungroupFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        selectItem(id)
        ungroupTapped()
    }

    @objc private func duplicateFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        selectItem(id)
        duplicateSelectedTapped()
    }

    @objc private func deleteRegionFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        endGesture()
        eraseItems(regions: [id], drawings: [id])
    }
}
