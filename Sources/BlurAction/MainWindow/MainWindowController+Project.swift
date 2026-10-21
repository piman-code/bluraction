import AppKit
import AVKit
import AVFoundation
import UniformTypeIdentifiers
import os
import Darwin

// MainWindowController: 프로젝트 저장·열기·가져오기.

extension MainWindowController {
    // MARK: - Project save / open

    /// The session as a project, geometry normalized to a 1×1 canvas. Internal for tests.
    func projectData(projectURL: URL? = nil, producerVersion: String? = nil) throws -> Data {
        guard let media = doc.url, canvas.bounds.width > 0, canvas.bounds.height > 0 else {
            throw ProjectFile.ProjectError.invalidContent
        }
        let regions = ProjectConversion.normalizedRegions(pairs, from: canvas.bounds.size)
        let drawings = ProjectConversion.normalizedDrawings(annotations, from: canvas.bounds.size)
        try doc.validateSourceUnchanged()
        if let binding = doc.videoProjectBinding {
            let version = try Self.projectProducerVersion(producerVersion)
            let reference = ProjectFile.mediaReference(for: media, projectURL: projectURL)
            if let baseline = videoProjectBaseline, let nativeBaseline = videoProjectNativeBaseline {
                let current = ProjectFile(mediaPath: reference,
                    regions: ProjectConversion.regions(pairs), drawings: annotations)
                let normalized = ProjectFile(mediaPath: reference, regions: regions, drawings: drawings)
                return try baseline.updated(mediaPath: reference, binding: binding, producerVersion: version,
                    baseline: nativeBaseline, current: current, normalized: normalized).encoded()
            }
            return try VideoProjectFile.make(mediaPath: reference, binding: binding, producerVersion: version,
                regions: regions, drawings: drawings).encoded()
        }
        return try ProjectFile(mediaPath: ProjectFile.mediaReference(for: media, projectURL: projectURL),
                               regions: regions, drawings: drawings, sourceSHA256: doc.sourceSHA256).encoded()
    }

    private static func projectProducerVersion(_ supplied: String?) throws -> String {
        guard let version = supplied ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              VideoProjectFile.validProducerVersion(version) else {
            throw ProjectFile.ProjectError.invalidContent
        }
        return version
    }

    @objc func saveProjectTapped() {
        guard !isExporting, doc.mediaKind != .none, let media = doc.url else { NSSound.beep(); return }
        endGesture()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ProjectFile.contentType]
        panel.nameFieldStringValue = ImageSavePanel.boundedName(
            stem: pageWorkspace?.title ?? media.deletingPathExtension().lastPathComponent,
            ending: "." + ProjectFile.fileExtension)
        panel.directoryURL = media.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.standardizedFileURL != media.standardizedFileURL else {
            showError("원본 파일 이름으로는 프로젝트를 저장할 수 없습니다.")
            return
        }
        do {
            if pageWorkspace != nil {
                try saveWorkspaceProject(to: url)
            } else if doc.videoProjectBinding != nil {
                try saveVideoProject(to: url)
                return
            } else {
                try writeNewProject(projectData(projectURL: url), to: url)
            }
            workflowHint.stringValue = "프로젝트를 저장했습니다: \(url.lastPathComponent)"
        } catch { showError(error.localizedDescription) }
    }

    /// Native source reinspection, SHA and publication run on owned workers.
    /// The supplied version is a test-only direct API; production uses Bundle Info.
    func saveVideoProject(to url: URL, producerVersion: String? = nil) throws {
        guard !isExporting, let binding = doc.videoProjectBinding,
              let media = doc.url, canvas.bounds.width > 0, canvas.bounds.height > 0 else {
            throw ProjectFile.ProjectError.invalidContent
        }
        let version = try Self.projectProducerVersion(producerVersion)
        let size = canvas.bounds.size
        let reference = ProjectFile.mediaReference(for: media, projectURL: url)
        let current = ProjectFile(mediaPath: reference,
            regions: ProjectConversion.regions(pairs), drawings: annotations)
        let normalized = ProjectFile(mediaPath: reference,
            regions: ProjectConversion.normalizedRegions(pairs, from: size),
            drawings: ProjectConversion.normalizedDrawings(annotations, from: size))
        let project: VideoProjectFile
        if let baseline = videoProjectBaseline, let native = videoProjectNativeBaseline {
            project = try baseline.updated(mediaPath: reference, binding: binding, producerVersion: version,
                baseline: native, current: current, normalized: normalized)
        } else {
            project = try VideoProjectFile.make(mediaPath: reference, binding: binding, producerVersion: version,
                regions: normalized.regions, drawings: normalized.drawings)
        }
        let data = try project.encoded()
        let operating = doc
        setExporting(true); cancelButton.isHidden = false
        progressIndicator.isIndeterminate = true; progressIndicator.isHidden = false
        progressLabel.stringValue = "프로젝트 원본과 시간축을 확인하는 중…"
        projectSaveTask = Task { [weak self] in
            do {
                let verified = try await binding.revalidated()
                try Task.checkCancellation()
                let publication = Task.detached {
                    try VideoProjectPublication.write(data, to: url, source: verified.source) { try Task.checkCancellation() }
                }
                try await withTaskCancellationHandler { try await publication.value } onCancel: { publication.cancel() }
                guard let self, self.doc === operating else { return }
                self.window?.isDocumentEdited = false
                self.workflowHint.stringValue = "프로젝트를 저장했습니다: \(url.lastPathComponent)"
            } catch {
                guard let self, self.doc === operating else { return }
                if !(error is CancellationError) { self.showError(error.localizedDescription) }
                else { self.workflowHint.stringValue = "프로젝트 저장을 취소했습니다. 기존 작업은 유지됩니다." }
            }
            guard let self else { return }
            self.projectSaveTask = nil; self.progressIndicator.isHidden = true
            self.progressIndicator.isIndeterminate = false; self.cancelButton.isHidden = true
            self.progressLabel.stringValue = ""; self.setExporting(false)
        }
    }

    /// Persists the visible page before encoding a multi-page session.
    func saveWorkspaceProject(to url: URL) throws {
        saveCurrentWorkspacePage()
        guard let workspace = pageWorkspace else { throw ProjectFile.ProjectError.invalidContent }
        try workspace.validateSourcesUnchanged()
        let data = try MultiPageProjectFile.from(workspace, projectURL: url).encoded()
        try writeNewProject(data, to: url)
    }

    private func writeNewProject(_ data: Data, to destination: URL) throws {
        var status = stat()
        guard lstat(destination.path, &status) != 0, errno == ENOENT else {
            throw PageWorkspace.WorkspaceError.destinationExists
        }
        var template = Array(destination.deletingLastPathComponent()
            .appendingPathComponent(".blur-action-project-XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw PageWorkspace.WorkspaceError.exportFailed }
        Darwin.close(descriptor)
        let temporary = URL(fileURLWithPath: String(cString: template))
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        guard renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw PageWorkspace.WorkspaceError.destinationExists }
            throw PageWorkspace.WorkspaceError.exportFailed
        }
    }

    /// Asks for a `.bluraction` file and decodes it (validated). Returns the project and its URL.
    private func chooseProject(message: String? = nil) -> (ProjectFile, VideoProjectFile?, URL)? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [ProjectFile.contentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let message { panel.message = message }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let data = try VideoProjectFile.read(at: url, maximumBytes: ProjectFile.maximumBytes)
            if [3, 4, 7].contains(try VideoProjectFile.version(of: data)) {
                let project = try VideoProjectFile.decode(data)
                return (project.edits, project, url)
            }
            return (try VideoProjectFile.decodeLegacy(data), nil, url)
        } catch {
            showError(error.localizedDescription)
            return nil
        }
    }

    private func chooseMedia(message: String, allowsPDF: Bool = false) -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        var types: [UTType] = [.movie, .quickTimeMovie, .mpeg4Movie, .video, .image]
        if allowsPDF { types.append(.pdf) }
        for identifier in ["public.heic", "public.heif", "org.webmproject.webp", "com.compuserve.gif"] {
            if let type = UTType(identifier) { types.append(type) }
        }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    /// An old project without a SHA cannot prove that a selected replacement is its original.
    /// Cancel is the default; applying saved edits requires a separate acknowledgement.
    static func confirmUnverifiedRelink(sourceName: String,
        present: @MainActor (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }) -> Bool {
        let alert = NSAlert()
        alert.messageText = "원본 확인이 필요한 프로젝트입니다"
        alert.informativeText = "이 프로젝트에는 \(sourceName)의 원본 지문이 저장되어 있지 않아, 선택한 파일이 동일한 원본인지 자동으로 확인할 수 없습니다. 원본을 직접 확인했으며 편집을 적용한 뒤 모든 페이지의 가림 위치와 범위를 다시 검토해야 합니다."
        alert.addButton(withTitle: "취소")
        alert.addButton(withTitle: "원본을 확인했으며 다시 검토하겠습니다")
        return present(alert) == .alertSecondButtonReturn
    }

    @objc func openProjectTapped() {
        guard !isExporting else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [ProjectFile.contentType]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try VideoProjectFile.read(at: url)
            switch try VideoProjectFile.version(of: data) {
            case 2, 6: try openWorkspaceProject(MultiPageProjectFile.decode(data), relativeTo: url)
            case 1, 5: openSingleProject(try VideoProjectFile.decodeLegacy(data), projectURL: url)
            case 3, 4, 7: openVideoProjectFile(try VideoProjectFile.decode(data), projectURL: url)
            default: throw ProjectFile.ProjectError.unsupportedVersion
            }
        } catch { showError(error.localizedDescription) }
    }

    func openWorkspaceProject(_ project: MultiPageProjectFile, relativeTo url: URL) throws {
        guard canLoadFiles else { return }
        var relinkedSources: [String: URL] = [:]
        for page in project.pages where relinkedSources[page.mediaPath] == nil {
            let reference = ProjectFile(mediaPath: page.mediaPath, regions: [], drawings: [])
            let resolved = reference.mediaURL(relativeTo: url)
            if reference.needsPlatformRelink || !VideoCanvasView.isSupportedDropFile(resolved) {
                let name = ProjectFile.portableFileName(page.mediaPath)
                let requiresReview = project.pages.contains { $0.mediaPath == page.mediaPath && $0.sourceSHA256 == nil }
                let policy = requiresReview
                    ? "원본 지문이 없는 페이지가 있어 동일 원본인지 자동 확인할 수 없습니다. 연결 전에 직접 확인하고 적용 뒤 가림 위치를 다시 검토하세요."
                    : "저장된 원본 지문과 같아야 기존 편집을 적용합니다."
                guard let found = chooseMedia(message: "프로젝트 원본(\(name))을 다시 연결하세요. \(policy)", allowsPDF: page.pdfPageIndex != nil) else { return }
                if requiresReview, !Self.confirmUnverifiedRelink(sourceName: name) { return }
                relinkedSources[page.mediaPath] = found
            }
        }
        let workspace = try project.workspace(relativeTo: url, relinkedSources: relinkedSources)
        let image = try workspace.image(at: project.currentIndex)
        load(url: workspace.pages[project.currentIndex].source.url, project: nil,
             pageImage: image, workspace: workspace)
    }

    private func openSingleProject(_ project: ProjectFile, projectURL url: URL) {
        var media = project.mediaURL(relativeTo: url)
        if project.needsPlatformRelink || !VideoCanvasView.isSupportedDropFile(media) {
            // The media moved or was renamed: let the person point to it.
            let name = ProjectFile.portableFileName(project.mediaPath)
            let policy = project.sourceSHA256 == nil
                ? "저장된 원본 지문이 없어 동일 원본인지 자동 확인할 수 없습니다. 직접 확인한 원본을 선택하고 적용 뒤 가림 위치를 다시 검토하세요."
                : "저장된 지문과 일치하는 원본 파일을 선택하세요."
            guard let found = chooseMedia(message: "프로젝트 원본(\(name))을 다시 연결하세요. \(policy)") else { return }
            if project.sourceSHA256 == nil, !Self.confirmUnverifiedRelink(sourceName: name) { return }
            media = found
        }
        openProject(project, media: media)
    }

    private func openVideoProjectFile(_ project: VideoProjectFile, projectURL url: URL) {
        let reference = project.edits
        var media = reference.mediaURL(relativeTo: url)
        if reference.needsPlatformRelink || !FileManager.default.fileExists(atPath: media.path) {
            guard let replacement = chooseMedia(message: "프로젝트 원본(\(ProjectFile.portableFileName(project.mediaPath)))을 다시 연결하세요. 저장된 지문과 정확한 시간축이 모두 같아야 편집을 적용합니다.") else { return }
            media = replacement
        }
        openVideoProject(project, media: media)
    }

    /// Content role comes from the v3 contract, never from the replacement suffix.
    func openVideoProject(_ project: VideoProjectFile, media: URL, asTemplate: Bool = false) {
        guard canLoadFiles else { return }
        do { try VideoProjectFile.requireAvailableFonts(project.payload.drawings) }
        catch { showError(error.localizedDescription); return }
        var edits = project.edits
        if asTemplate { edits.sourceSHA256 = nil }
        load(url: media, project: edits, videoProject: project, template: asTemplate)
    }

    /// Template use: the project's items (normalized positions, times, styles) on another video or image.
    @objc func applyProjectToOtherMediaTapped() {
        guard !isExporting, var (project, videoProject, _) = chooseProject(message: "적용할 프로젝트(템플릿)를 고르세요."),
              let media = chooseMedia(message: "프로젝트 항목을 적용할 영상이나 이미지를 고르세요.") else { return }
        project.sourceSHA256 = nil // Explicit template action intentionally targets different media.
        if let videoProject { openVideoProject(videoProject, media: media, asTemplate: true) }
        else { load(url: media, project: project, template: true) }
    }

    @objc func importProjectItemsTapped() {
        guard !isExporting, doc.mediaKind != .none,
              let (project, videoProject, _) = chooseProject(message: "현재 파일에 항목을 더할 프로젝트를 고르세요.") else { return }
        if let videoProject {
            do { try importVideoProjectItems(videoProject) } catch { showError(error.localizedDescription) }
            return
        }
        importProjectItems(project)
    }

    func importVideoProjectItems(_ project: VideoProjectFile,
                                 completion: ((Result<Void, Error>) -> Void)? = nil) throws {
        guard !isExporting, let source = doc.url, let expected = doc.sourceSHA256,
              canvas.bounds.width > 0, canvas.bounds.height > 0 else { throw ProjectFile.ProjectError.invalidContent }
        try VideoProjectFile.requireAvailableFonts(project.payload.drawings)
        let binding = doc.videoProjectBinding
        if doc.hasVideo && binding == nil { throw ProjectFile.ProjectError.invalidContent }
        let operating = doc, id = UUID(); projectImportID = id
        setExporting(true); cancelButton.isHidden = false
        progressIndicator.isIndeterminate = true; progressIndicator.isHidden = false
        progressLabel.stringValue = "항목을 가져오기 전에 현재 원본을 확인하는 중…"
        projectSaveTask = Task { [weak self] in
            let result: Result<Void, Error>
            do {
                let validated: VideoProjectSourceBinding.Source
                if let binding { validated = try await binding.revalidated().source }
                else {
                    validated = try await VideoProjectSourceBinding.capture(source)
                    guard validated.sha256 == expected else { throw PageWorkspace.WorkspaceError.sourceChanged }
                }
                try Task.checkCancellation()
                guard let self, self.projectImportID == id else { return }
                guard self.doc === operating else { throw CancellationError() }
                try validated.validateIdentity()
                // No await between the final source/generation gate and the
                // single existing import checkpoint/commit on the GUI actor.
                self.setExporting(false)
                self.importProjectItems(project.edits)
                result = .success(())
            } catch { result = .failure(error) }
            guard let self, self.projectImportID == id else { return }
            self.projectImportID = nil; self.projectSaveTask = nil
            self.progressIndicator.isHidden = true; self.progressIndicator.isIndeterminate = false
            self.cancelButton.isHidden = true; self.progressLabel.stringValue = ""; self.setExporting(false)
            guard self.doc === operating else { return }
            if let completion { completion(result); return }
            if case .failure(let error) = result {
                if error is CancellationError { self.workflowHint.stringValue = "항목 가져오기를 취소했습니다. 기존 작업은 유지됩니다." }
                else { self.showError(error.localizedDescription) }
            }
        }
    }

    /// Adds a project's items to the current session as new items (new IDs and group IDs, fitted to
    /// the current canvas; times past the end are clipped). One undo step. Internal for tests.
    func importProjectItems(_ project: ProjectFile) {
        guard !isExporting, canvas.bounds.width > 0, canvas.bounds.height > 0 else { return }
        endGesture()
        let (imported, drawings) = ProjectConversion.importedItems(project, canvasSize: canvas.bounds.size,
                                                                   clipDuration: doc.hasVideo ? doc.duration : nil)
        guard !imported.isEmpty || !drawings.isEmpty else { NSSound.beep(); return }
        checkpoint()
        pairs.append(contentsOf: imported)
        annotations.append(contentsOf: drawings)
        window?.isDocumentEdited = true
        workflowHint.stringValue = "프로젝트에서 영역 \(imported.count)개 · 그림 \(drawings.count)개를 가져왔습니다."
        refreshAfterEdit()
    }

    /// Loads `media`, then applies the project's items once the media is laid out. Internal for tests.
    func openProject(_ project: ProjectFile, media: URL) {
        do { try project.validateSource(media) }
        catch { showError(error.localizedDescription); return }
        load(url: media, project: project)
    }

    func applyProject(_ project: ProjectFile, clipToTarget: Bool = true) {
        let size = canvas.bounds.size
        guard size.width > 0, size.height > 0 else {
            showError("화면을 준비하지 못해 프로젝트 내용을 적용하지 못했습니다. 창을 키운 뒤 다시 열어 주세요.")
            return
        }
        // A template applied to a shorter video: clip ranges that run past the end.
        (pairs, annotations) = ProjectConversion.appliedItems(project, canvasSize: size,
                                                              clipDuration: clipToTarget && doc.hasVideo ? doc.duration : nil)
        history.clearSteps()
        canvas.setRegionsFromExternal(pairs.map(\.shape))
        workflowHint.stringValue = "프로젝트를 열었습니다: 영역 \(pairs.count)개 · 그림 \(annotations.count)개"
        refreshAfterEdit()
    }
}
