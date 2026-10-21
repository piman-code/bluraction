import AppKit
import AVKit
import AVFoundation
import UniformTypeIdentifiers
import os
import Darwin

// MainWindowController: 영상 내보내기.

extension MainWindowController {
    @objc func exportTapped() {
        guard !isExporting, doc.mediaKind != .none, let input = doc.url else { return }
        do {
            try validateExportFonts()
            // Image snapshot worker performs cancellable original verification.
            // Do not repeat its full file hash on the GUI actor before the panel.
            if doc.mediaKind != .image || pageWorkspace != nil { try doc.validateSourceUnchanged() }
        }
        catch { showError(error.localizedDescription); return }
        if pageWorkspace != nil {
            endGesture()
            saveCurrentWorkspacePage()
            exportWorkspace()
            return
        }
        guard hasEffectiveEffect else {
            showError("블러 영역을 추가하거나 그리기 도구로 표시할 내용을 추가하세요.")
            return
        }
        endGesture()
        stopPlayback()

        // 이미지 모드: BlurredImageExporter.exportImage 호출
        if doc.mediaKind == .image {
            guard let cg = doc.currentCGImage else {
                BLog("[export] abort: currentCGImage nil")
                return
            }
            exportImage(cgImage: cg)
            return
        }

        let displayRect = canvas.displayRect
        // 매핑은 appliedVideoSize 기준 — exporter가 transform 적용한 size와 일치.
        // (자연 회전된 영상에서 위치 어긋남 방지)
        let videoSize = doc.appliedVideoSize
        guard displayRect.width > 0 else {
            BLog("[export] abort: displayRect.width=0")
            return
        }
        guard videoSize.width > 0 else {
            BLog("[export] abort: videoSize.width=0 (비디오 메타 아직 로딩 안 됨)")
            return
        }
        BLog("[export] videoSize=\(videoSize) (natural=\(doc.videoSize) t=\(doc.preferredTransform)) displayRect=\(displayRect) pairs=\(pairs.count)")
        // pairs는 캔버스 좌표 그대로 전달 — exporter(makeUnionMaskImage)가 canvasBounds → renderSize 변환을 단독 수행.
        // (이전: 여기서도 변환했음 → 이중 변환으로 영역 위치/크기 어긋남)
        let mapped: [(shape: RegionShape, effect: RegionEffect)] = pairs
        let exportCanvasSize = canvas.bounds.size
        setExporting(true)
        progressIndicator.doubleValue = 0
        progressIndicator.isHidden = false
        progressLabel.stringValue = "내보내기 준비 중…"
        cancelButton.isHidden = false
        exportButton.isEnabled = false
        Task {
            await exporter.export(input: input, pairs: mapped, quality: quality, canvasBounds: exportCanvasSize,
                                  annotations: annotations, expectedSourceSHA256: doc.sourceSHA256, progressCallback: { p, txt in
                Task { @MainActor in
                    self.progressIndicator.doubleValue = p
                    self.progressLabel.stringValue = txt
                }
            })
            await MainActor.run { self.exportFinished() }
        }
    }

    func validateExportFonts() throws {
        try VideoProjectFile.requireAvailableFonts(annotations)
        if let workspace = pageWorkspace {
            for page in workspace.pages { try VideoProjectFile.requireAvailableFonts(page.drawings) }
        }
    }

    private func exportWorkspace() {
        guard let workspace = pageWorkspace else { return }
        let hasEdits = workspace.pages.contains { page in
            page.regions.contains { $0.effect.enabled } || page.drawings.contains { !$0.hidden }
        }
        guard hasEdits else {
            showError("블러 영역이나 그리기를 적어도 한 페이지에 추가하세요.")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = ImageSavePanel.boundedName(stem: URL(fileURLWithPath: workspace.title)
            .deletingPathExtension().lastPathComponent, ending: "_blurred.pdf")
        guard panel.runModal() == .OK, let output = panel.url else { return }
        setExporting(true)
        let cancellation = PageExportCancellation()
        pageExportCancellation = cancellation
        progressIndicator.isIndeterminate = false
        progressIndicator.doubleValue = 0
        progressIndicator.isHidden = false
        cancelButton.isHidden = false
        progressLabel.stringValue = "\(workspace.pages.count)쪽 문서를 새 파일로 만드는 중…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var pdfSaved = false
            do {
                try workspace.exportPDF(to: output, progress: { completed, total in
                    DispatchQueue.main.async { [weak self] in
                        self?.progressIndicator.doubleValue = Double(completed) / Double(total) * 90
                        self?.progressLabel.stringValue = "PDF \(completed)/\(total)쪽 처리 중…"
                    }
                }, isCancelled: { cancellation.isCancelled })
                pdfSaved = true
                let imageFolder = try workspace.exportImageFiles(near: output,
                    isCancelled: { cancellation.isCancelled })
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.finishWorkspaceExport()
                    let alert = NSAlert()
                    alert.messageText = "저장 완료"
                    alert.informativeText = imageFolder.map {
                        "PDF: \(output.lastPathComponent)\n이미지별 PNG: \($0.lastPathComponent) 폴더"
                    } ?? "PDF: \(output.lastPathComponent)"
                    alert.addButton(withTitle: "Finder에서 보기")
                    alert.addButton(withTitle: "확인")
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.activateFileViewerSelecting([output])
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.finishWorkspaceExport()
                    let prefix = pdfSaved ? "PDF는 저장됐지만 이미지별 저장이 완료되지 않았습니다. " : ""
                    self.showError(prefix + error.localizedDescription)
                }
            }
        }
    }

    private func finishWorkspaceExport() {
        pageExportCancellation = nil
        progressIndicator.isHidden = true
        cancelButton.isHidden = true
        progressLabel.stringValue = ""
        setExporting(false)
    }

    private func exportFinished() {
        setExporting(false)
        progressIndicator.isHidden = true
        cancelButton.isHidden = true
        if exporter.wasCancelled { progressLabel.stringValue = "내보내기를 취소했습니다."; return }
        if let out = exporter.lastOutputURL {
            let alert = NSAlert()
            alert.messageText = "저장 완료"
            alert.informativeText = "\(out.lastPathComponent)"
            alert.addButton(withTitle: "Finder에서 보기")
            alert.addButton(withTitle: "확인")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([out])
            }
        } else if !exporter.statusText.isEmpty {
            let alert = NSAlert()
            alert.messageText = "내보내기 실패"
            alert.informativeText = exporter.statusText
            alert.addButton(withTitle: "확인")
            alert.runModal()
        }
        progressLabel.stringValue = ""
    }
}
