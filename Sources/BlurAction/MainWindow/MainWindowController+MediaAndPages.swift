import AppKit
import AVKit
import AVFoundation
import UniformTypeIdentifiers
import os
import Darwin

// MainWindowController: 미디어 열기와 여러 페이지 작업.

extension MainWindowController {
    func load(url: URL) { load(urls: [url]) }

    /// Read-only transaction diagnostics; tests still drive the actual controller commands.
    struct MediaLoadSessionDiagnostics: Equatable {
        let sourceURL: URL?
        let sourceSHA256: String?
        let undoDepth: Int
        let redoDepth: Int
        let selectedRegion: UUID?
        let selectedDrawing: UUID?
        let multiSelection: [UUID]
        let workspaceIndex: Int?
        let dirty: Bool
        let pending: Bool
    }
    var mediaLoadSessionDiagnostics: MediaLoadSessionDiagnostics {
        MediaLoadSessionDiagnostics(sourceURL: doc.url, sourceSHA256: doc.sourceSHA256,
            undoDepth: undoStack.count, redoDepth: redoStack.count,
            selectedRegion: selectedID, selectedDrawing: selectedDrawingID,
            multiSelection: multiSelection, workspaceIndex: pageWorkspace?.currentIndex,
            dirty: window?.isDocumentEdited ?? false, pending: pendingDocument != nil)
    }

    var canLoadFiles: Bool { !isExporting }

    func load(urls: [URL]) {
        guard canLoadFiles, !urls.isEmpty else { return }
        if urls.count == 1, urls[0].pathExtension.lowercased() != "pdf" {
            load(url: urls[0], project: nil)
            return
        }
        do {
            let workspace = try PageWorkspace.open(urls)
            let image = try workspace.image(at: 0)
            load(url: workspace.pages[0].source.url, project: nil, pageImage: image, workspace: workspace)
        } catch { showError(error.localizedDescription) }
    }

    /// Prepare a separate document; the operating session is untouched until completion.
    func load(url: URL, project: ProjectFile?, pageImage: CGImage? = nil,
                      workspace: PageWorkspace? = nil, workspaceNavigation: Bool = false,
                      videoProject: VideoProjectFile? = nil, template: Bool = false) {
        Self.dropLoadLog.notice("load-requested")
        guard canLoadFiles else {
            Self.dropLoadLog.notice("load-blocked-by-export")
            return
        }
        guard url.isFileURL else {
            Self.dropLoadLog.notice("load-rejected-nonfile")
            showError("이 Mac에 저장된 파일을 선택하세요.")
            return
        }
        let candidate = DocumentModel(videoLoader: videoLoader)
        pendingDocument = candidate
        pendingProject = project
        pendingVideoProject = videoProject
        pendingTemplate = template
        pendingWorkspace = workspace
        pendingWorkspaceNavigation = workspaceNavigation
        pendingProgressText = progressLabel.stringValue
        setExporting(true)
        cancelButton.isHidden = false
        progressLabel.stringValue = "원본을 확인하는 중… 기존 작업은 유지됩니다."
        candidate.onLoad = { [weak self, weak candidate] in
            guard let self, let candidate, self.pendingDocument === candidate else { return }
            self.completeMediaLoad(candidate)
        }
        beforeMediaLoad?(url)
        guard pendingDocument === candidate else { return }
        if let workspace, let pageImage {
            candidate.load(pageImage: pageImage, sourceURL: url,
                           name: "\(workspace.title) · \(workspace.currentIndex + 1)/\(workspace.pages.count)")
        } else {
            candidate.load(url: url, expectedSourceSHA256: project?.sourceSHA256,
                           videoProject: template ? nil : videoProject)
        }
    }

    /// Cancellation only discards the candidate, including late video metadata callbacks.
    func cancelPendingMediaLoad() {
        guard let pendingDocument else { return }
        pendingDocument.cancelLoading()
        finishPendingMediaLoad()
    }

    private func finishPendingMediaLoad() {
        pendingDocument?.onLoad = nil
        pendingDocument = nil
        pendingProject = nil
        pendingVideoProject = nil
        pendingTemplate = false
        pendingWorkspace = nil
        pendingWorkspaceNavigation = false
        progressLabel.stringValue = pendingProgressText
        cancelButton.isHidden = true
        setExporting(false)
    }

    private func completeMediaLoad(_ candidate: DocumentModel) {
        do {
            if let error = candidate.errorMessage { throw NSError(domain: "BlurAction.Load", code: 1,
                userInfo: [NSLocalizedDescriptionKey: error]) }
            guard candidate.mediaKind != .none else { throw DocumentModel.LoadError.noVideo }
            if let expected = pendingProject?.sourceSHA256, pendingVideoProject == nil || pendingTemplate {
                try candidate.validateSourceUnchanged(expectedSourceSHA256: expected)
            }
            if let project = pendingVideoProject, !pendingTemplate {
                guard let binding = candidate.videoProjectBinding else { throw ProjectFile.ProjectError.invalidContent }
                try project.verify(binding: binding)
                try binding.source.validateIdentity()
            }
            if let binding = candidate.videoProjectBinding { try binding.source.validateIdentity() }
            if let workspace = pendingWorkspace { try workspace.validateSourcesUnchanged() }
        } catch {
            finishPendingMediaLoad()
            showError(error.localizedDescription)
            return
        }
        let project = pendingProject
        let videoProject = pendingVideoProject
        let template = pendingTemplate
        let workspace = pendingWorkspace
        let replacingWorkspace = !pendingWorkspaceNavigation
        candidate.onLoad = nil
        pendingDocument = nil
        pendingWorkspace = nil
        pendingWorkspaceNavigation = false
        pendingProject = project
        pendingVideoProject = videoProject
        pendingTemplate = template
        doc = candidate
        videoProjectBaseline = nil
        videoProjectNativeBaseline = nil
        pageWorkspace = workspace
        if replacingWorkspace { workspaceWindowFitted = false }
        // Only a verified candidate can reach these destructive session resets.
        stopPlayback()
        resetPlaybackTime(duration: 0)
        mainContainer.slider.isEnabled = false
        mainContainer.playPauseButton.isEnabled = false
        playerItemStatusObserver?.invalidate()
        playerItemStatusObserver = nil
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        player.currentItem?.cancelPendingSeeks()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        pairs.removeAll(); annotations.removeAll(); undoStack.removeAll(); redoStack.removeAll(); gestureSnapshot = nil
        gestureAnnotations = nil
        selectedID = nil
        selectedDrawingID = nil
        multiSelection.removeAll()
        canvas.resetInteraction()
        canvas.isEditable = false
        canvas.currentVideoTime = 0
        player.replaceCurrentItem(with: nil)
        mainContainer.playerLayer.isHidden = true
        liveBlur.detach()
        liveBlur.sourceCGImage = nil
        liveBlur.contents = nil
        progressLabel.stringValue = pendingProgressText
        cancelButton.isHidden = true
        exportButton.isEnabled = false
        refreshRegionList(); refreshSelectedEditor()
        if replacingWorkspace { window?.isDocumentEdited = false }
        documentLoaded()
    }


    private func normalizedEdit(_ snapshot: EditorSnapshot) -> PageWorkspace.Edit {
        let size = canvas.bounds.size
        let regions = RegionEditing.scaled(snapshot.pairs, from: size, to: unitPageSize)
            .map { ProjectFile.Region(shape: $0.shape, effect: $0.effect) }
        let drawings = snapshot.annotations.map { $0.scaled(from: size, to: unitPageSize) }
        return PageWorkspace.Edit(regions: regions, drawings: drawings)
    }

    private func canvasEdit(_ edit: PageWorkspace.Edit) -> EditorSnapshot {
        let size = canvas.bounds.size
        let pairs = RegionEditing.scaled(edit.regions.map { ($0.shape, $0.effect) },
                                         from: unitPageSize, to: size)
        return EditorSnapshot(pairs: pairs,
                              annotations: edit.drawings.map { $0.scaled(from: unitPageSize, to: size) })
    }

    func saveCurrentWorkspacePage() {
        guard var workspace = pageWorkspace, workspace.pages.indices.contains(workspace.currentIndex),
              canvas.bounds.width > 0, canvas.bounds.height > 0 else { return }
        let edit = normalizedEdit(EditorSnapshot(pairs: pairs, annotations: annotations))
        workspace.pages[workspace.currentIndex].regions = edit.regions
        workspace.pages[workspace.currentIndex].drawings = edit.drawings
        workspace.pages[workspace.currentIndex].undo = undoStack.map(normalizedEdit)
        workspace.pages[workspace.currentIndex].redo = redoStack.map(normalizedEdit)
        pageWorkspace = workspace
    }

    private func restoreWorkspacePage(_ page: PageWorkspace.Page) {
        let snapshot = canvasEdit(PageWorkspace.Edit(regions: page.regions, drawings: page.drawings))
        pairs = snapshot.pairs
        annotations = snapshot.annotations
        undoStack = page.undo.map(canvasEdit)
        redoStack = page.redo.map(canvasEdit)
        selectedID = nil
        selectedDrawingID = nil
        multiSelection.removeAll()
        canvas.setRegionsFromExternal(pairs.map(\.shape))
        refreshAfterEdit()
    }

    private func loadWorkspacePage(at index: Int, savingCurrent: Bool = true) throws {
        guard !isExporting, var workspace = pageWorkspace,
              workspace.pages.indices.contains(index) else { return }
        let image = try workspace.image(at: index)
        if savingCurrent, canvas.bounds.width > 0, canvas.bounds.height > 0 {
            let edit = normalizedEdit(EditorSnapshot(pairs: pairs, annotations: annotations))
            workspace.pages[workspace.currentIndex].regions = edit.regions
            workspace.pages[workspace.currentIndex].drawings = edit.drawings
            workspace.pages[workspace.currentIndex].undo = undoStack.map(normalizedEdit)
            workspace.pages[workspace.currentIndex].redo = redoStack.map(normalizedEdit)
        }
        workspace.currentIndex = index
        load(url: workspace.pages[index].source.url, project: nil, pageImage: image,
             workspace: workspace, workspaceNavigation: true)
    }

    @objc func previousPageTapped() {
        guard let workspace = pageWorkspace else { return }
        do { try loadWorkspacePage(at: workspace.currentIndex - 1) }
        catch { showError(error.localizedDescription) }
    }

    @objc func nextPageTapped() {
        guard let workspace = pageWorkspace else { return }
        do { try loadWorkspacePage(at: workspace.currentIndex + 1) }
        catch { showError(error.localizedDescription) }
    }

    @objc func copyCurrentPageToAll() {
        guard !isExporting, let workspace = pageWorkspace, workspace.pages.count > 1 else { return }
        endGesture()
        let alert = NSAlert()
        alert.messageText = "현재 페이지 작업을 모든 페이지에 적용할까요?"
        alert.informativeText = "다른 페이지에 이미 만든 영역과 그림은 현재 페이지 작업으로 대체됩니다. 이후에는 각 페이지를 따로 고칠 수 있습니다."
        alert.addButton(withTitle: "모든 페이지에 적용")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        applyCurrentPageToAll()
    }

    /// Copies normalized layers once; later edits to each page remain independent.
    func applyCurrentPageToAll() {
        guard !isExporting, let workspace = pageWorkspace, workspace.pages.count > 1 else { return }
        saveCurrentWorkspacePage()
        guard var updated = pageWorkspace else { return }
        let source = updated.pages[updated.currentIndex]
        for index in updated.pages.indices where index != updated.currentIndex {
            updated.pages[index].regions = source.regions
            updated.pages[index].drawings = source.drawings
            updated.pages[index].undo = []
            updated.pages[index].redo = []
        }
        pageWorkspace = updated
        workflowHint.stringValue = "현재 페이지 작업을 \(updated.pages.count)쪽에 적용했습니다. 각 페이지를 따로 수정할 수 있습니다."
    }

    private func documentLoaded() {
        Self.dropLoadLog.notice("load-succeeded")
        fileLabel.stringValue = doc.displayName
        window?.title = "BlurAction — \(doc.displayName)"
        resetPlaybackTime(duration: doc.duration)
        mainContainer.mediaSize = doc.appliedVideoSize
        if pageWorkspace == nil {
            fitWindowToMedia(doc.appliedVideoSize)
        } else if !workspaceWindowFitted {
            fitWindowToMedia(doc.appliedVideoSize, forWorkspace: true)
            workspaceWindowFitted = true
        }
        frameRow.isHidden = !doc.hasVideo
        recordPositionButton.isHidden = !doc.hasVideo
        previousKeyButton.isHidden = !doc.hasVideo
        nextKeyButton.isHidden = !doc.hasVideo
        workflowHint.stringValue = doc.hasVideo
            ? "① 영역 그리기  ② 블러·시간 조정  ③ 필요하면 위치 기록  ④ 내보내기"
            : "① 영역 그리기  ② 블러·경계 조정  ③ 화질 선택  ④ 내보내기"
        refreshMediaInformation()
        liveBlur.videoSize = doc.appliedVideoSize
        liveBlur.videoTransform = doc.preferredTransform
        liveBlur.currentTime = doc.hasVideo ? doc.firstVideoFrameTime : 0
        canvas.currentVideoTime = liveBlur.currentTime
        mainContainer.playPauseButton.isHidden = doc.hasImage
        mainContainer.slider.isHidden = doc.hasImage
        mainContainer.timeLabel.stringValue = doc.hasImage ? (doc.url?.pathExtension.lowercased() == "gif" ? "GIF · 첫 프레임만 편집" : "이미지 · 정적 편집") : "00:00.00 / \(format(doc.duration))"
        imageFormatPopup.isHidden = !doc.hasImage || pageWorkspace != nil
        if doc.hasImage {
            mainContainer.playerLayer.isHidden = true
            liveBlur.sourceCGImage = doc.currentCGImage
        } else if let url = doc.url {
            mainContainer.playerLayer.isHidden = false
            mainContainer.playerLayer.player = player
            let item = AVPlayerItem(asset: VideoAssetPolicy.asset(url: url))
            player.replaceCurrentItem(with: item)
            liveBlur.sourceCGImage = nil
            liveBlur.attach(item: item, player: player)
            observePlaybackTime(for: item)
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self, weak item] _ in
                MainActor.assumeIsolated {
                    guard let self, let item, self.player.currentItem === item,
                          !self.seekCoordinator.suppressesTimeObserver else { return }
                    self.stopPlayback()
                }
            }
        }
        mainContainer.refreshMediaLayout()
        setExporting(false)
        // A leading empty segment is part of the original timeline. Open at its
        // first media frame after busy clears, while the slider still permits seeking to zero.
        if doc.hasVideo { seek(to: doc.firstVideoFrameTime) }
        refreshEraserControls()
        if let project = pendingProject {
            pendingProject = nil
            let original = pendingVideoProject
            let template = pendingTemplate
            pendingVideoProject = nil; pendingTemplate = false
            applyProject(project, clipToTarget: template)
            if let original, !template {
                videoProjectBaseline = original
                videoProjectNativeBaseline = ProjectFile(mediaPath: original.mediaPath,
                    regions: pairs.map { ProjectFile.Region(shape: $0.shape, effect: $0.effect) }, drawings: annotations)
            }
        }
        if let review = doc.videoProjectReview { workflowHint.stringValue = review }
        if let workspace = pageWorkspace {
            restoreWorkspacePage(workspace.pages[workspace.currentIndex])
            mainContainer.pageControls.isHidden = false
            mainContainer.pageLabel.stringValue = "\(workspace.currentIndex + 1) / \(workspace.pages.count)"
            mainContainer.previousPageButton.isEnabled = workspace.currentIndex > 0
            mainContainer.nextPageButton.isEnabled = workspace.currentIndex + 1 < workspace.pages.count
            copyToAllPagesButton.isHidden = workspace.pages.count < 2
            mainContainer.timeLabel.isHidden = true
            sourceInfoLabel.stringValue += " · \(workspace.currentIndex + 1)/\(workspace.pages.count)쪽"
            qualityTitle.stringValue = "문서 출력"
            qualityPopup.isHidden = true
            qualityInfoLabel.stringValue = workspace.hasImageSources
                ? "새 PDF와 이미지별 PNG를 함께 만듭니다. 민감 정보는 단색·경계 0으로 가리세요."
                : "새 PDF를 만듭니다. 민감 정보는 단색·경계 0으로 가리세요."
        } else {
            mainContainer.pageControls.isHidden = true
            copyToAllPagesButton.isHidden = true
            mainContainer.timeLabel.isHidden = false
            qualityTitle.stringValue = "내보내기 화질"
            qualityPopup.isHidden = false
        }
        refreshRegionList(); refreshSelectedEditor()
        canvas.refreshOverlay(); liveBlur.refresh()
    }

    /// Start near the media's pixel size while keeping the whole image on screen.
    /// Subsequent user window resizing still uses the canvas's aspect-fit layout.
    private func fitWindowToMedia(_ size: CGSize, forWorkspace: Bool = false) {
        guard let window, let screen = window.screen ?? NSScreen.main,
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return }
        let visible = screen.visibleFrame
        let chrome = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 0, height: 0)).height
        let maxWidth = max(640, visible.width - 48)
        let maxHeight = max(420, visible.height - chrome - 48)
        let sidebarWidth = MainContainerViewController.sidebarWidth + 1
        let mediaWidth = maxWidth - sidebarWidth
        let mediaHeight = maxHeight - 104
        let scale = min(1, mediaWidth / size.width, mediaHeight / size.height)
        let minimumWidth: CGFloat = forWorkspace ? min(maxWidth, 1180) : 640
        let minimumHeight: CGFloat = min(maxHeight, forWorkspace ? 760 : 700)
        let target = CGSize(width: max(minimumWidth, ceil(size.width * scale) + sidebarWidth),
                            height: max(minimumHeight, ceil(size.height * scale) + 104))
        guard let content = window.contentView,
              abs(content.bounds.width - target.width) > 1 ||
              abs(content.bounds.height - target.height) > 1 else { return }
        window.setContentSize(target)
        window.center()
    }

    func format(_ t: Double) -> String {
        guard t.isFinite else { return "00:00.00" }
        let m = Int(t) / 60, s = Int(t) % 60, cs = Int((t - floor(t)) * 100)
        return String(format: "%02d:%02d.%02d", m, s, cs)
    }

    private func refreshMediaInformation() {
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(doc.sourceBytes), countStyle: .file)
        let size = doc.appliedVideoSize
        if doc.hasImage {
            sourceInfoLabel.stringValue = "원본: \(Int(size.width)) × \(Int(size.height))px · \(doc.url?.pathExtension.uppercased() ?? "이미지") · \(bytes)"
        } else if doc.hasVideo {
            let fps = doc.videoFPS > 0 ? String(format: "%.2f fps", doc.videoFPS) : "fps 정보 없음"
            let bitRate = doc.videoBitRate > 0 ? String(format: "%.2f Mb/s", doc.videoBitRate / 1_000_000) : "비트레이트 정보 없음"
            sourceInfoLabel.stringValue = "원본: \(Int(size.width)) × \(Int(size.height))px · \(fps) · \(doc.videoCodec)\n\(bitRate) · \(format(doc.duration)) · \(bytes)"
        } else {
            sourceInfoLabel.stringValue = "파일을 열면 원본 정보가 표시됩니다."
        }
        refreshQualityInfo()
    }

    func refreshQualityInfo() {
        if doc.hasImage {
            let format = imageFormatPopup.titleOfSelectedItem ?? "PNG"
            let detail = ["PNG", "TIFF"].contains(format) ? "무손실" :
                String(format: "압축 품질 %.0f%%", (quality == .original ? 1.0 :
                    quality == .high ? 0.92 : quality == .medium ? 0.75 : 0.5) * 100)
            qualityInfoLabel.stringValue = "출력: \(Int(doc.imageSize.width)) × \(Int(doc.imageSize.height))px · \(format) · \(detail)"
        } else if doc.hasVideo {
            let size = doc.appliedVideoSize
            let fps = max(1, doc.videoFPS)
            let rate = quality == .original ? max(500_000, doc.videoBitRate) :
                max(500_000, size.width * size.height * fps * quality.bitsPerPixelPerSecond)
            let fpsLabel = doc.videoFPS > 0 ? String(format: "%.2f fps", doc.videoFPS) : "원본 프레임 유지"
            qualityInfoLabel.stringValue = "출력: \(Int(size.width)) × \(Int(size.height))px · \(fpsLabel)\nH.264 · 목표 \(String(format: "%.2f", rate / 1_000_000)) Mb/s · MP4/MOV\n원본 화질도 재인코딩\(doc.hasAudio ? " · 오디오 AAC 128 kb/s" : "")"
        } else {
            qualityInfoLabel.stringValue = "파일을 열면 출력 사양이 표시됩니다."
        }
    }
}
