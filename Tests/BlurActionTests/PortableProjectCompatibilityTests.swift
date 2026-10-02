import AppKit
import AVFoundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BlurAction

@Suite(.serialized)
struct PortableProjectCompatibilityTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("portable-project-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func image(_ url: URL, white: Bool = true) throws {
        let context = try #require(CGContext(data: nil, width: 16, height: 12, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: white ? 1 : 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        let writer = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(writer))
    }

    @Test func foreignWindowsReferencesRequireExplicitRelink() throws {
        for path in ["C:\\자료\\원본.png", "C:/자료/원본.png", "\\\\server\\share\\원본.png", "\\자료\\원본.png", "C:원본.png"] {
            let project = ProjectFile(mediaPath: path, regions: [], drawings: [])
            #expect(project.needsPlatformRelink)
            #expect(ProjectFile.portableFileName(path).hasSuffix("원본.png"))
        }
        #expect(!ProjectFile(mediaPath: "원본.png", regions: [], drawings: []).needsPlatformRelink)
    }

    @Test func relativeBothSeparatorsCannotTraverseOutOfProjectFolder() {
        let folder = URL(fileURLWithPath: "/tmp/project-contract")
        let location = folder.appendingPathComponent("session.bluraction")
        for path in ["../../원본.png", "..\\..\\원본.png"] {
            let project = ProjectFile(mediaPath: path, regions: [], drawings: [])
            #expect(project.mediaURL(relativeTo: location) == folder.appendingPathComponent("원본.png"))
        }
    }

    @Test func oldV1WithoutFingerprintStillDecodesAndNewDigestRoundTrips() throws {
        let old = Data("{\"version\":1,\"mediaPath\":\"synthetic.png\",\"regions\":[],\"drawings\":[]}".utf8)
        #expect(try ProjectFile.decode(old).sourceSHA256 == nil)
        let project = ProjectFile(mediaPath: "synthetic.png", regions: [], drawings: [], sourceSHA256: String(repeating: "a", count: 64))
        #expect(try ProjectFile.decode(project.encoded()) == project)
        var invalid = project
        invalid.sourceSHA256 = String(repeating: "A", count: 64)
        #expect(throws: ProjectFile.ProjectError.self) { try ProjectFile.decode(invalid.encoded()) }
    }

    @Test func explicitRelinkRetainsDigestAndRejectsDifferentOriginal() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("원본.png")
        try image(source)
        let digest = try PageWorkspace.digest(of: source)
        let foreign = "C:\\teacher\\원본.png"
        let project = MultiPageProjectFile(title: "shared", currentIndex: 0,
            pages: [.init(mediaPath: foreign, sourceSHA256: digest, regions: [], drawings: [])])
        let location = folder.appendingPathComponent("session.bluraction")
        #expect(throws: ProjectFile.ProjectError.self) { try project.workspace(relativeTo: location) }
        let opened = try project.workspace(relativeTo: location, relinkedSources: [foreign: source])
        #expect(opened.pages.count == 1)
        #expect(opened.sourceDigests[source.standardizedFileURL] == digest)
        try image(source, white: false)
        #expect(throws: PageWorkspace.WorkspaceError.self) {
            try project.workspace(relativeTo: location, relinkedSources: [foreign: source])
        }
    }

    @Test @MainActor func singleImageFingerprintDetectsEditsBeforeSaving() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("original.png")
        try image(source)
        let document = DocumentModel()
        document.load(url: source)
        #expect(document.hasImage)
        #expect(document.sourceSHA256?.count == 64)
        try document.validateSourceUnchanged()
        try image(source, white: false)
        #expect(throws: PageWorkspace.WorkspaceError.self) { try document.validateSourceUnchanged() }
    }

    @Test func v1ExplicitRelinkMustMatchExpectedSource() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("original.png")
        try image(source)
        let project = ProjectFile(mediaPath: "C:\\original.png", regions: [], drawings: [], sourceSHA256: try PageWorkspace.digest(of: source))
        try project.validateSource(source)
        try image(source, white: false)
        #expect(throws: PageWorkspace.WorkspaceError.self) { try project.validateSource(source) }
    }

    @Test func staleSingleImageCannotPublishExport() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("original.png")
        try image(source)
        let digest = try PageWorkspace.digest(of: source)
        let pixels = try DocumentModel.decodeImage(url: source)
        try image(source, white: false)
        let output = folder.appendingPathComponent("must-not-exist.png")
        #expect(throws: PageWorkspace.WorkspaceError.self) {
            try BlurredImageExporter.export(source: pixels, pairs: [], canvasSize: CGSize(width: 16, height: 12),
                inputURL: source, outputURL: output, type: .png, quality: 1, expectedSourceSHA256: digest)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test @MainActor func staleVideoDigestFailsBeforeEncoderAndKeepsSource() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("synthetic.mp4")
        try Data("synthetic invalid video bytes".utf8).write(to: source)
        let before = try Data(contentsOf: source)
        let exporter = BlurredVideoExporter()
        await exporter.export(input: source, pairs: [], quality: .high, canvasBounds: CGSize(width: 16, height: 12),
            expectedSourceSHA256: String(repeating: "0", count: 64))
        #expect(exporter.lastOutputURL == nil)
        #expect(exporter.statusText.contains("원본"))
        #expect(try Data(contentsOf: source) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["synthetic.mp4"])
    }

    @Test @MainActor func imageChangedAfterProjectPreflightCannotLoadPendingEdits() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("original.png")
        try image(source)
        let expected = try PageWorkspace.digest(of: source)
        let project = ProjectFile(mediaPath: "original.png", regions: [], drawings: [], sourceSHA256: expected)
        try project.validateSource(source)
        // Simulate replacement between controller preflight and the document's actual read.
        try image(source, white: false)
        let document = DocumentModel()
        var completions = 0
        document.onLoad = { completions += 1 }
        document.load(url: source, expectedSourceSHA256: expected)
        #expect(completions == 1)
        #expect(document.mediaKind == .none)
        #expect(document.currentCGImage == nil)
        #expect(document.sourceSHA256 == nil)
        #expect(document.errorMessage?.contains("원본") == true)
    }

    @Test @MainActor func loadedBaselineMustMatchProjectBeforeApplyingEdits() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("original.png")
        try image(source)
        let expected = try PageWorkspace.digest(of: source)
        try image(source, white: false)
        let document = DocumentModel()
        document.load(url: source)
        try #require(document.hasImage)
        try document.validateSourceUnchanged()
        #expect(throws: PageWorkspace.WorkspaceError.sourceChanged) {
            try document.validateSourceUnchanged(expectedSourceSHA256: expected)
        }
    }

    @Test @MainActor func videoFingerprintFailureIsNotAnUnverifiedProductionSuccess() async throws {
        let missing = URL(fileURLWithPath: "/synthetic/\(UUID()).mov")
        let production = DocumentModel()
        var completed = false
        production.onLoad = { completed = true }
        production.load(url: missing)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !completed, ContinuousClock.now < deadline { await Task.yield() }
        try #require(completed)
        #expect(production.mediaKind == .none)
        #expect(production.sourceSHA256 == nil)
        #expect(production.errorMessage != nil)
        // Hash failure precedes AVFoundation metadata loading.
        #expect(production.errorMessage != DocumentModel.LoadError.noVideo.errorDescription)

        var loaderCalled = false
        let injected = DocumentModel(videoLoader: { _ in
            loaderCalled = true
            return .init(size: CGSize(width: 16, height: 12), transform: .identity, duration: 1)
        })
        completed = false
        injected.onLoad = { completed = true }
        injected.load(url: missing)
        let syntheticDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !completed, ContinuousClock.now < syntheticDeadline { await Task.yield() }
        try #require(completed)
        #expect(injected.hasVideo && loaderCalled)
        #expect(injected.sourceSHA256 == nil)

        // Supplying a project fingerprint disables the synthetic URL exception.
        loaderCalled = false
        completed = false
        injected.load(url: missing, expectedSourceSHA256: String(repeating: "a", count: 64))
        let projectDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !completed, ContinuousClock.now < projectDeadline { await Task.yield() }
        try #require(completed)
        #expect(!loaderCalled)
        #expect(injected.mediaKind == .none)
        #expect(injected.errorMessage != nil)
    }

    @Test @MainActor func videoChangedDuringDecodeCannotAdoptANewProjectBaseline() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mov")
        try Data("original synthetic video bytes".utf8).write(to: source)
        let expected = try PageWorkspace.digest(of: source)
        var loaderCalled = false
        let document = DocumentModel(videoLoader: { url in
            loaderCalled = true
            try Data("replacement synthetic video bytes".utf8).write(to: url)
            return .init(size: CGSize(width: 16, height: 12), transform: .identity, duration: 1)
        })
        var completions = 0
        document.onLoad = { completions += 1 }
        document.load(url: source, expectedSourceSHA256: expected)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while completions == 0, ContinuousClock.now < deadline { await Task.yield() }
        try #require(completions == 1)
        #expect(loaderCalled)
        #expect(document.mediaKind == .none)
        #expect(document.sourceSHA256 == nil)
        #expect(document.errorMessage?.contains("원본") == true)

        loaderCalled = false
        completions = 0
        document.load(url: source, expectedSourceSHA256: expected)
        let retryDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while completions == 0, ContinuousClock.now < retryDeadline { await Task.yield() }
        try #require(completions == 1)
        #expect(!loaderCalled, "A changed initial fingerprint must fail before metadata decoding")
        #expect(!document.hasVideo)
    }

    @Test @MainActor func legacyUnverifiedRelinkRequiresSeparateReviewAcknowledgement() {
        _ = NSApplication.shared
        var presented = 0
        let cancelled = MainWindowController.confirmUnverifiedRelink(sourceName: "legacy.png") { alert in
            presented += 1
            #expect(alert.informativeText.contains("원본 지문이 저장되어 있지 않아"))
            #expect(alert.informativeText.contains("모든 페이지의 가림 위치와 범위"))
            #expect(alert.buttons.first?.title == "취소")
            return .alertFirstButtonReturn
        }
        #expect(!cancelled && presented == 1)
        #expect(!MainWindowController.confirmUnverifiedRelink(sourceName: "legacy.png") { _ in .abort })
        #expect(MainWindowController.confirmUnverifiedRelink(sourceName: "legacy.png") { _ in .alertSecondButtonReturn })
    }

    @Test @MainActor func cancelDuringFinalFingerprintDoesNotPublishEncodedVideo() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("silent.mov")
        try VideoExportTests().ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=64x64:rate=4:duration=1",
            "-c:v", "libx264", source.path])
        let before = try Data(contentsOf: source)
        let expected = try PageWorkspace.digest(of: source)
        let existing = folder.appendingPathComponent("silent_blurred.mov")
        let sentinel = Data("keep existing output".utf8)
        try sentinel.write(to: existing)
        var checks = 0
        weak var activeExporter: BlurredVideoExporter?
        let exporter = BlurredVideoExporter(sourceFingerprinter: { url in
            checks += 1
            if checks == 2 {
                // This is reached only after actual AVFoundation encoding has finished.
                await Task.yield()
                activeExporter?.cancel()
            }
            return try PageWorkspace.digest(of: url)
        })
        activeExporter = exporter
        await exporter.export(input: source, pairs: [], quality: .original,
            canvasBounds: CGSize(width: 64, height: 64), expectedSourceSHA256: expected)
        #expect(checks == 2, Comment(rawValue: exporter.statusText))
        #expect(exporter.wasCancelled)
        #expect(exporter.lastOutputURL == nil)
        #expect(try Data(contentsOf: source) == before)
        #expect(try Data(contentsOf: existing) == sentinel)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) == ["silent.mov", "silent_blurred.mov"])
    }

    @MainActor private func prepareDirtySession(_ controller: MainWindowController, sources: [URL]) throws -> ProjectFile {
        controller.window?.isReleasedWhenClosed = false
        controller.showWindow(nil)
        controller.load(urls: sources)
        let container = try #require(controller.window?.contentViewController as? MainContainerViewController)
        if sources.count > 1 { controller.perform(NSSelectorFromString("nextPageTapped")) }
        container.canvas.addRegionHandler?()
        container.canvas.addRegionHandler?()
        controller.perform(NSSelectorFromString("undoTapped"))
        let drawing = DrawingAnnotation(kind: .line, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.8, y: 0.8)],
                                        color: .red, lineWidth: 0.01)
        controller.importProjectItems(ProjectFile(mediaPath: sources[0].path, regions: [], drawings: [drawing]))
        controller.perform(NSSelectorFromString("undoTapped"))
        let session = try ProjectFile.decode(controller.projectData())
        container.canvas.selectRegion(id: try #require(session.regions.first?.shape.id))
        controller.window?.isDocumentEdited = true
        return session
    }

    @Test @MainActor func controllerInvalidImageRetainsDirtyPageLayersSelectionAndBothHistories() throws {
        _ = NSApplication.shared
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appendingPathComponent("a.png"), b = folder.appendingPathComponent("b.png")
        try image(a); try image(b, white: false)
        var errors: [String] = []
        let controller = MainWindowController(loadErrorPresenter: { errors.append($0) })
        defer { controller.close() }
        let session = try prepareDirtySession(controller, sources: [a, b])
        let before = controller.mediaLoadSessionDiagnostics
        let container = try #require(controller.window?.contentViewController as? MainContainerViewController)
        let pixels = container.liveBlur.sourceCGImage
        let frame = controller.window?.frame
        let bad = folder.appendingPathComponent("invalid.png")
        try Data("invalid image".utf8).write(to: bad)
        controller.load(url: bad)
        #expect(errors.count == 1)
        #expect(controller.mediaLoadSessionDiagnostics == before)
        #expect(try ProjectFile.decode(controller.projectData()) == session)
        #expect(container.liveBlur.sourceCGImage === pixels)
        #expect(controller.window?.frame == frame)
        #expect(container.canvas.isEditable)
        let destination = folder.appendingPathComponent("preserved.bluraction")
        try controller.saveWorkspaceProject(to: destination)
        let saved = try MultiPageProjectFile.decode(Data(contentsOf: destination))
        #expect(saved.currentIndex == 1 && saved.pages.count == 2)
        #expect(saved.pages[0].regions.isEmpty && saved.pages[0].drawings.isEmpty)
        #expect(saved.pages[1].regions == session.regions)
        controller.perform(NSSelectorFromString("redoTapped"))
        #expect(try ProjectFile.decode(controller.projectData()).drawings.count == 1)
        controller.perform(NSSelectorFromString("undoTapped"))
        #expect(try ProjectFile.decode(controller.projectData()) == session)
        controller.perform(NSSelectorFromString("undoTapped"))
        #expect(try ProjectFile.decode(controller.projectData()).regions.isEmpty)
    }

    @Test @MainActor func controllerProjectPreflightReplacementKeepsOperatingSession() throws {
        _ = NSApplication.shared
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appendingPathComponent("a.png"), b = folder.appendingPathComponent("b.png")
        try image(a); try image(b)
        let digest = try PageWorkspace.digest(of: b)
        var errors: [String] = []
        var replacementError: Error?
        let controller = MainWindowController(loadErrorPresenter: { errors.append($0) }, beforeMediaLoad: { url in
            if url == b {
                do { try image(b, white: false) } catch { replacementError = error }
            }
        })
        defer { controller.close() }
        let session = try prepareDirtySession(controller, sources: [a])
        let before = controller.mediaLoadSessionDiagnostics
        controller.openProject(ProjectFile(mediaPath: b.path, regions: session.regions,
                                           drawings: [], sourceSHA256: digest), media: b)
        #expect(replacementError == nil)
        #expect(errors.count == 1 && errors.first?.contains("원본") == true)
        #expect(controller.mediaLoadSessionDiagnostics == before)
        #expect(try ProjectFile.decode(controller.projectData()) == session)
    }

    @Test @MainActor func controllerProductionVideoDecodeFailureRetainsDirtyImageSession() async throws {
        _ = NSApplication.shared
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appendingPathComponent("a.png")
        try image(a)
        let bad = folder.appendingPathComponent("invalid.mov")
        try Data("not a playable video".utf8).write(to: bad)
        var errors: [String] = []
        let controller = MainWindowController(loadErrorPresenter: { errors.append($0) })
        defer { controller.close() }
        let session = try prepareDirtySession(controller, sources: [a])
        let before = controller.mediaLoadSessionDiagnostics
        controller.load(url: bad)
        #expect(controller.mediaLoadSessionDiagnostics.pending)
        #expect(controller.mediaLoadSessionDiagnostics.sourceURL == a)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while errors.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        try #require(errors.count == 1)
        #expect(controller.mediaLoadSessionDiagnostics == before)
        #expect(try ProjectFile.decode(controller.projectData()) == session)
    }

    /// Mutate only a controlled H.264 fixture's encoded samples, preserving moov,
    /// track dimensions, duration, offsets and the complete file length.
    private func zeroMovieSamplePayload(in folder: URL) throws -> (good: URL, bad: URL) {
        let good = folder.appendingPathComponent("valid.mp4")
        let bad = folder.appendingPathComponent("zero-mdat.mp4")
        try VideoExportTests().ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=96x64:rate=12:duration=1",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-movflags", "+faststart", good.path])
        let original = try Data(contentsOf: good)
        try #require(original.count <= 32 * 1024 * 1024)
        var mutated = original, offset = 0, payloadBytes = 0, hasMoov = false
        func number(_ index: Int, _ count: Int) -> UInt64 {
            (index..<(index + count)).reduce(UInt64(0)) { ($0 << 8) | UInt64(original[$1]) }
        }
        while offset < original.count {
            try #require(original.count - offset >= 8)
            let length32 = number(offset, 4)
            let header = length32 == 1 ? 16 : 8
            try #require(original.count - offset >= header)
            let length = length32 == 0 ? UInt64(original.count - offset)
                : length32 == 1 ? number(offset + 8, 8) : length32
            try #require(length >= UInt64(header) && length <= UInt64(original.count - offset))
            let end = offset + Int(length)
            let kind = String(bytes: original[(offset + 4)..<(offset + 8)], encoding: .ascii)
            if kind == "moov" { hasMoov = true }
            if kind == "mdat" {
                let payload = (offset + header)..<end
                mutated.resetBytes(in: payload)
                payloadBytes += payload.count
                #expect(mutated[offset..<(offset + header)] == original[offset..<(offset + header)])
            } else {
                #expect(mutated[offset..<end] == original[offset..<end])
            }
            offset = end
        }
        try #require(hasMoov && payloadBytes > 0 && mutated != original)
        #expect(mutated.count == original.count)
        try mutated.write(to: bad, options: .withoutOverwriting)
        return (good, bad)
    }

    @Test @MainActor func metadataReadableButFirstFrameCorruptMovieCannotReplaceDirtyPageSession() async throws {
        _ = NSApplication.shared
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try zeroMovieSamplePayload(in: folder)
        let originalGood = try Data(contentsOf: movie.good), originalBad = try Data(contentsOf: movie.bad)
        let badAsset = VideoAssetPolicy.asset(url: movie.bad)
        let track = try #require(try await badAsset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 96, height: 64))
        #expect(try await badAsset.load(.duration).seconds > 0)
        // Positive control: the same production decoder must accept the intact samples.
        let goodDocument = DocumentModel()
        var goodCompleted = false
        goodDocument.onLoad = { goodCompleted = true }
        goodDocument.load(url: movie.good)
        let goodDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !goodCompleted, ContinuousClock.now < goodDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try #require(goodCompleted && goodDocument.hasVideo)
        #expect(goodDocument.errorMessage == nil)

        let a = folder.appendingPathComponent("a.png"), b = folder.appendingPathComponent("b.png")
        try image(a); try image(b, white: false)
        var errors: [String] = []
        let controller = MainWindowController(loadErrorPresenter: { errors.append($0) })
        defer { controller.close() }
        let session = try prepareDirtySession(controller, sources: [a, b])
        let before = controller.mediaLoadSessionDiagnostics
        let container = try #require(controller.window?.contentViewController as? MainContainerViewController)
        let pixels = container.liveBlur.sourceCGImage
        let windowFrame = controller.window?.frame
        controller.load(url: movie.bad)
        #expect(controller.mediaLoadSessionDiagnostics.pending)
        #expect(controller.mediaLoadSessionDiagnostics.sourceURL == b)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while errors.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try #require(errors.count == 1)
        #expect(errors[0] == DocumentModel.LoadError.videoFirstFrameDecode.errorDescription)
        #expect(controller.mediaLoadSessionDiagnostics == before)
        #expect(try ProjectFile.decode(controller.projectData()) == session)
        #expect(container.liveBlur.sourceCGImage === pixels)
        #expect(container.liveBlur.contents != nil && container.canvas.isEditable)
        #expect(controller.window?.frame == windowFrame)
        #expect(try Data(contentsOf: movie.good) == originalGood)
        #expect(try Data(contentsOf: movie.bad) == originalBad)
        let saved = folder.appendingPathComponent("preserved.bluraction")
        try controller.saveWorkspaceProject(to: saved)
        let savedProject = try MultiPageProjectFile.decode(Data(contentsOf: saved))
        #expect(savedProject.currentIndex == 1 && savedProject.pages.count == 2)
        #expect(savedProject.pages[1].regions.count == session.regions.count)
        controller.perform(NSSelectorFromString("redoTapped"))
        #expect(try ProjectFile.decode(controller.projectData()).drawings.count == 1)
    }

    @Test @MainActor func firstFrameGenerationCancellationRejectsLateDecodedSuccess() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try zeroMovieSamplePayload(in: folder)
        var decodeStarted = false
        var task: Task<Void, Error>?
        task = Task { @MainActor in
            _ = try await DocumentModel.validateFirstVideoFrame(asset: VideoAssetPolicy.asset(url: movie.good), onDecodeStarted: {
                decodeStarted = true
                task?.cancel()
            })
        }
        let active = try #require(task)
        do {
            try await active.value
            Issue.record("A cancelled first-frame decoder must not report success")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(decodeStarted)
    }

    @Test(arguments: [100, 500])
    @MainActor
    func nativeLeadingEmptySegmentOpensAtActualMediaTimeWithoutRebasingTimeline(gapMilliseconds: Int) async throws {
        _ = NSApplication.shared
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try zeroMovieSamplePayload(in: folder)
        let output = folder.appendingPathComponent("native-leading-gap.mov")
        let requestedGap = Double(gapMilliseconds) / 1000
        let source = VideoAssetPolicy.asset(url: movie.good)
        let sourceTrack = try #require(try await source.loadTracks(withMediaType: .video).first)
        let composition = AVMutableComposition()
        let target = try #require(composition.addMutableTrack(withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid))
        target.preferredTransform = try await sourceTrack.load(.preferredTransform)
        try target.insertTimeRange(try await sourceTrack.load(.timeRange), of: sourceTrack,
            at: CMTime(value: Int64(gapMilliseconds), timescale: 1000))
        let exporter = try #require(AVAssetExportSession(asset: composition,
            presetName: AVAssetExportPresetPassthrough))
        try #require(exporter.supportedFileTypes.contains(.mov))
        exporter.outputURL = output
        exporter.outputFileType = .mov
        exporter.shouldOptimizeForNetworkUse = false
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            exporter.exportAsynchronously { continuation.resume() }
        }
        try #require(exporter.status == .completed)
        let bytes = try Data(contentsOf: output)
        let asset = VideoAssetPolicy.asset(url: output)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let segments = try await track.load(.segments)
        // Passthrough can quantize the edit-list boundary to the container's timescale.
        // Use raw exported geometry for decode/clock checks, rather than assuming .1 is exact.
        #expect(segments.contains { $0.isEmpty && $0.timeMapping.target.start.seconds == 0
            && abs($0.timeMapping.target.duration.seconds - requestedGap) < 0.001 })
        #expect(segments.contains { !$0.isEmpty && abs($0.timeMapping.target.start.seconds - requestedGap) < 0.001 })
        let duration = try await asset.load(.duration).seconds
        let first = try await DocumentModel.firstVideoFrameTime(track: track, duration: duration)
        #expect(abs(first - requestedGap) < 0.001)
        // Positive control uses the actual policy asset/decoder, without an injected loader.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        let decoded = try await generator.image(at: CMTime(seconds: first + 1.0 / 30.0,
            preferredTimescale: 600))
        #expect(decoded.image.width == 96 && decoded.image.height == 64)
        #expect(decoded.actualTime.seconds >= first - 0.000000001)
        let actualFrameTime = decoded.actualTime.seconds

        var documentFinished = false
        let document = DocumentModel()
        document.onLoad = { documentFinished = true }
        document.load(url: output)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !documentFinished, ContinuousClock.now < deadline { await Task.yield() }
        try #require(documentFinished && document.hasVideo && document.errorMessage == nil)
        #expect(abs(document.firstVideoFrameTime - actualFrameTime) < 0.000001)
        #expect(abs(document.duration - duration) < 0.000001)
        let expectedSourceDigest = try PageWorkspace.digest(of: output)
        #expect(document.sourceSHA256 == expectedSourceDigest)

        var errors: [String] = []
        let controller = MainWindowController(loadErrorPresenter: { errors.append($0) })
        controller.window?.isReleasedWhenClosed = false
        controller.showWindow(nil)
        defer { controller.close() }
        let container = try #require(controller.window?.contentViewController as? MainContainerViewController)
        controller.load(url: output)
        let previewDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while (controller.mediaLoadSessionDiagnostics.pending || container.liveBlur.contents == nil
               || container.canvas.currentVideoTime < actualFrameTime - 0.001), ContinuousClock.now < previewDeadline {
            await Task.yield()
        }
        #expect(errors.isEmpty)
        #expect(controller.mediaLoadSessionDiagnostics.sourceURL == output)
        #expect(!controller.mediaLoadSessionDiagnostics.pending)
        #expect(container.liveBlur.contents != nil)
        #expect(abs(container.canvas.currentVideoTime - actualFrameTime) < 0.001)
        #expect(abs(container.slider.doubleValue - actualFrameTime) < 0.001)
        #expect(container.slider.minValue == 0)
        #expect(abs(container.slider.maxValue - duration) < 0.000001)
        func rgbaBytes(_ image: CGImage) throws -> [UInt8] {
            let color = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(CGContext(data: nil, width: 96, height: 64,
                bitsPerComponent: 8, bytesPerRow: 96 * 4, space: color,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 96, height: 64))
            let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            return Array(UnsafeBufferPointer(start: pixels, count: 96 * 64 * 4))
        }
        func meanRGB(_ image: CGImage) throws -> Double {
            let pixels = try rgbaBytes(image)
            var total = 0
            for index in 0..<(96 * 64) {
                total += Int(pixels[index * 4]) + Int(pixels[index * 4 + 1]) + Int(pixels[index * 4 + 2])
            }
            return Double(total) / Double(96 * 64 * 3)
        }
        let contents = try #require(container.liveBlur.contents)
        try #require(CFGetTypeID(contents as CFTypeRef) == CGImage.typeID,
            "Opening preview contents must be actual CGImage pixels")
        let preview = contents as! CGImage
        let controlMean = try meanRGB(decoded.image)
        let previewMean = try meanRGB(preview)
        let diagnostics = "gapMs=\(gapMilliseconds) firstSegment=\(first) decodedActual=\(actualFrameTime) "
            + "canvasTime=\(container.canvas.currentVideoTime) sliderTime=\(container.slider.doubleValue) "
            + "controlMeanRGB=\(controlMean) previewMeanRGB=\(previewMean)"
        print("[native-leading-gap-preview] \(diagnostics)")
        // The generated testsrc2 fixture is bright. A decoded first-media image and
        // meaningful controller preview must both differ from a synthetic black gap.
        // This deliberately makes no exact cross-renderer pixel-parity assertion.
        #expect(controlMean > 20, Comment(rawValue: diagnostics))
        #expect(previewMean > 20, Comment(rawValue: diagnostics))

        let displayed = try #require(container.liveBlur.presentedFrameTime).seconds
        #expect(container.canvas.currentVideoTime == displayed)
        #expect(container.canvas.currentTimeProvider?() == displayed)
        let createdShape = RegionShape.rectangle(id: UUID(), origin: .zero, size: container.canvas.bounds.size)
        // Use the product's registered callbacks, with no synthetic mouse events.
        container.canvas.regionsUpdate?([createdShape])
        let createdRegion = try #require(try ProjectFile.decode(controller.projectData()).regions.first)
        #expect(createdRegion.effect.timeRange.lowerBound == displayed)
        #expect(createdRegion.effect.isActive(at: displayed))
        #expect(createdRegion.effect.style == .blur && createdRegion.effect.blurRadius == 25)
        let coveredContents = try #require(container.liveBlur.contents)
        try #require(CFGetTypeID(coveredContents as CFTypeRef) == CGImage.typeID)
        let beforeRGB = try rgbaBytes(preview), coveredRGB = try rgbaBytes(coveredContents as! CGImage)
        let maxDelta = beforeRGB.indices.filter { $0 % 4 != 3 }
            .map { abs(Int(beforeRGB[$0]) - Int(coveredRGB[$0])) }.max() ?? 0
        #expect(maxDelta > 5, "New default blur is immediately visible on its actual first frame")
        let addedDrawing = DrawingAnnotation(kind: .rectangle,
            points: [.zero, CGPoint(x: container.canvas.bounds.width, y: container.canvas.bounds.height)],
            color: .white, lineWidth: 2, fillOpacity: 1)
        container.canvas.annotationAdded?(addedDrawing)
        let createdSession = try ProjectFile.decode(controller.projectData())
        let createdDrawing = try #require(createdSession.drawings.first)
        #expect(createdDrawing.timeRange.lowerBound == displayed)
        #expect(createdDrawing.isVisible(at: displayed))
        let drawingContents = try #require(container.liveBlur.contents)
        try #require(CFGetTypeID(drawingContents as CFTypeRef) == CGImage.typeID)
        #expect(try meanRGB(drawingContents as! CGImage) > 200, "New white drawing is immediately visible")
        controller.perform(NSSelectorFromString("undoTapped"))
        #expect(try ProjectFile.decode(controller.projectData()).drawings.isEmpty)
        controller.perform(NSSelectorFromString("redoTapped"))
        #expect(try ProjectFile.decode(controller.projectData()) == createdSession)
        let createdURL = folder.appendingPathComponent("created-on-presented-frame.bluraction")
        let createdData = try controller.projectData(projectURL: createdURL)
        try createdData.write(to: createdURL, options: .withoutOverwriting)
        let savedCreation = try ProjectFile.decode(Data(contentsOf: createdURL))
        #expect(savedCreation.regions[0].effect.timeRange.lowerBound == displayed)
        #expect(savedCreation.drawings[0].timeRange.lowerBound == displayed)
        let reopenedCreation = MainWindowController(loadErrorPresenter: { errors.append($0) })
        reopenedCreation.window?.isReleasedWhenClosed = false
        reopenedCreation.showWindow(nil)
        defer { reopenedCreation.close() }
        let reopenedContainer = try #require(reopenedCreation.window?.contentViewController as? MainContainerViewController)
        reopenedCreation.openProject(savedCreation, media: output)
        let creationDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while (reopenedCreation.mediaLoadSessionDiagnostics.pending || reopenedContainer.liveBlur.contents == nil
               || reopenedContainer.liveBlur.presentedFrameTime == nil), ContinuousClock.now < creationDeadline {
            await Task.yield()
        }
        let reopenedSession = try ProjectFile.decode(reopenedCreation.projectData())
        #expect(reopenedSession.regions[0].effect.timeRange.lowerBound == displayed)
        #expect(reopenedSession.drawings[0].timeRange.lowerBound == displayed)
        let reopenedContents = try #require(reopenedContainer.liveBlur.contents)
        try #require(CFGetTypeID(reopenedContents as CFTypeRef) == CGImage.typeID)
        #expect(try meanRGB(reopenedContents as! CGImage) > 200)
        #expect(errors.isEmpty)
        #expect(try Data(contentsOf: createdURL) == createdData)

        // A paused request between 12fps samples retains the first displayed frame.
        // Motion, eraser geometry and explicit recording must use that frame's PTS.
        let movingShape = RegionShape.rectangle(id: UUID(), origin: CGPoint(x: 0.1, y: 0.1),
            size: CGSize(width: 0.2, height: 0.2))
        var movingEffect = RegionEffect(blurRadius: 0, featherRadius: 0, timeRange: displayed...duration)
        movingEffect.style = .solid
        movingEffect.keyframes = [
            RegionKeyframe(time: displayed, rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)),
            RegionKeyframe(time: displayed + 0.08, rect: CGRect(x: 0.7, y: 0.1, width: 0.2, height: 0.2))]
        controller.importProjectItems(ProjectFile(mediaPath: output.path,
            regions: [.init(shape: movingShape, effect: movingEffect)], drawings: []))
        let movingID = try #require(try ProjectFile.decode(controller.projectData()).regions.last?.shape.id)
        let seekTarget = displayed + 0.02
        container.slider.doubleValue = seekTarget
        controller.perform(NSSelectorFromString("sliderMoved:"), with: container.slider)
        let heldDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while (container.liveBlur.contents == nil || container.liveBlur.presentedFrameTime == nil
               || (container.playerLayer.player?.currentTime().seconds ?? -1) < seekTarget - 0.000001),
              ContinuousClock.now < heldDeadline { await Task.yield() }
        let heldPTS = try #require(container.liveBlur.presentedFrameTime).seconds
        #expect(abs(heldPTS - displayed) < 0.000001)
        #expect(container.canvas.currentVideoTime == heldPTS)
        #expect(container.canvas.currentTimeProvider?() == heldPTS)
        #expect(container.canvas.creationTimeProvider?() == heldPTS)
        #expect(container.slider.doubleValue > heldPTS + 0.019, "Transport retains its in-between-frame time")
        let shownMoving = try #require(container.canvas.regionsBinding?().first { $0.id == movingID })
        #expect(abs(shownMoving.boundingRect.minX / container.canvas.bounds.width - 0.1) < 0.000001)
        #expect(shownMoving.contains(point: CGPoint(x: container.canvas.bounds.width * 0.2,
            y: container.canvas.bounds.height * 0.2), threshold: 0))
        container.canvas.selectRegion(id: movingID)
        controller.perform(NSSelectorFromString("recordCurrentPosition"))
        let recorded = try #require(try ProjectFile.decode(controller.projectData()).regions.last)
        #expect(recorded.effect.keyframes.count == 2)
        #expect(recorded.effect.keyframes.first?.time == heldPTS)
        let center = CGPoint(x: container.canvas.bounds.width * 0.2, y: container.canvas.bounds.height * 0.2)
        container.canvas.eraserStroke?([CGPoint(x: center.x - 1, y: center.y), CGPoint(x: center.x + 1, y: center.y)], 10)
        let erased = try #require(try ProjectFile.decode(controller.projectData()).regions.last)
        #expect(erased.effect.erasures.first?.from == heldPTS)
        #expect(erased.effect.erasures.first?.isActive(at: heldPTS) == true)

        // A saved interval starts between the old600-timescale clock and the actual
        // first-media PTS. Drive the real controller with this project, without bindings
        // or metadata injection: both missing preview and an uncovered bright frame fail.
        var cover = RegionEffect(blurRadius: 0, featherRadius: 0,
            timeRange: (actualFrameTime - 0.000001)...duration)
        cover.style = .solid
        cover.color = .black
        let shape = RegionShape.rectangle(id: UUID(), origin: .zero, size: CGSize(width: 1, height: 1))
        let boundary = ProjectFile(mediaPath: output.path,
            regions: [.init(shape: shape, effect: cover)], drawings: [],
            sourceSHA256: try PageWorkspace.digest(of: output))
        var boundaryErrors: [String] = []
        let boundaryController = MainWindowController(loadErrorPresenter: { boundaryErrors.append($0) })
        boundaryController.window?.isReleasedWhenClosed = false
        boundaryController.showWindow(nil)
        defer { boundaryController.close() }
        let boundaryContainer = try #require(boundaryController.window?.contentViewController as? MainContainerViewController)
        boundaryController.openProject(boundary, media: output)
        let boundaryDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while (boundaryController.mediaLoadSessionDiagnostics.pending || boundaryContainer.liveBlur.contents == nil
               || boundaryContainer.liveBlur.presentedFrameTime == nil
               || boundaryContainer.playerLayer.player?.currentItem?.status != .readyToPlay
               || (boundaryContainer.playerLayer.player?.currentTime().seconds ?? -1) < actualFrameTime - 0.000001),
              ContinuousClock.now < boundaryDeadline {
            await Task.yield()
        }
        #expect(boundaryErrors.isEmpty)
        #expect(!boundaryController.mediaLoadSessionDiagnostics.pending)
        func boundaryPixels() throws -> CGImage {
            let value = try #require(boundaryContainer.liveBlur.contents)
            try #require(CFGetTypeID(value as CFTypeRef) == CGImage.typeID)
            return value as! CGImage
        }
        let boundaryTime = try #require(boundaryContainer.liveBlur.presentedFrameTime).seconds
        let boundaryMean = try meanRGB(boundaryPixels())
        let boundaryDiagnostics = "gapMs=\(gapMilliseconds) actual=\(actualFrameTime) displayedPTS=\(boundaryTime) "
            + "clock=\(boundaryContainer.liveBlur.currentTime) sourceMean=\(controlMean) coveredMean=\(boundaryMean)"
        print("[native-leading-gap-covered-preview] \(boundaryDiagnostics)")
        #expect(abs(boundaryTime - actualFrameTime) < 0.000001, Comment(rawValue: boundaryDiagnostics))
        #expect(boundaryMean < 0.5, Comment(rawValue: boundaryDiagnostics))
        // Holding a decoded frame must hold its PTS as well, even when the transport
        // clock differs. This is a cache rerender check, not native playback evidence.
        boundaryContainer.liveBlur.currentTime = 0
        boundaryContainer.liveBlur.refresh()
        #expect(try meanRGB(boundaryPixels()) < 0.5)
        #expect(abs(try #require(boundaryContainer.liveBlur.presentedFrameTime).seconds - actualFrameTime) < 0.000001)
        boundaryContainer.liveBlur.invalidateFrame()
        #expect(boundaryContainer.liveBlur.contents == nil && boundaryContainer.liveBlur.presentedFrameTime == nil)
        boundaryContainer.liveBlur.requestStillFrame(at: actualFrameTime)
        boundaryContainer.liveBlur.detach()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(boundaryContainer.liveBlur.contents == nil && boundaryContainer.liveBlur.presentedFrameTime == nil,
            "A cancelled/detached still callback cannot resurrect the old frame or PTS")
        container.slider.doubleValue = 0
        controller.perform(NSSelectorFromString("sliderMoved:"), with: container.slider)
        #expect(container.canvas.currentVideoTime == 0, "Seeking into the original gap remains possible")
        #expect(try Data(contentsOf: output) == bytes)
    }

    @Test @MainActor func precisePreviewTimesRoundUpAndRejectOverflowWithoutIntegerTraps() throws {
        for seconds in [0.0, 0.10001627604166667, 0.5, 1_000_000.123456789] {
            let time = try #require(LiveBlurCompositor.preciseTime(seconds: seconds))
            #expect(time.isNumeric && time.seconds >= seconds)
            #expect(time.seconds - seconds < 0.000000002)
        }
        for invalid in [-1.0, Double.nan, .infinity, .greatestFiniteMagnitude,
                        Double(Int64.max) / 1_000_000_000] {
            #expect(LiveBlurCompositor.preciseTime(seconds: invalid) == nil)
        }
    }

    @Test @MainActor func controllerCancelledVideoCandidateCannotReplaceDirtySessionLater() async throws {
        _ = NSApplication.shared
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appendingPathComponent("a.png"), b = folder.appendingPathComponent("candidate.mov")
        try image(a)
        try Data("synthetic metadata loader fixture".utf8).write(to: b)
        var pending: CheckedContinuation<DocumentModel.VideoMetadata, Error>?
        var errors: [String] = []
        let controller = MainWindowController(videoLoader: { _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        }, loadErrorPresenter: { errors.append($0) })
        defer { controller.close() }
        let session = try prepareDirtySession(controller, sources: [a])
        let before = controller.mediaLoadSessionDiagnostics
        let container = try #require(controller.window?.contentViewController as? MainContainerViewController)
        let previousPixels = try #require(container.liveBlur.sourceCGImage)
        controller.load(url: b)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while pending == nil, ContinuousClock.now < deadline { await Task.yield() }
        try #require(pending != nil)
        #expect(controller.mediaLoadSessionDiagnostics.sourceURL == a)
        container.liveBlur.setNeedsDisplay()
        container.liveBlur.displayIfNeeded()
        #expect(container.liveBlur.sourceCGImage === previousPixels)
        #expect(container.liveBlur.contents != nil, "An existing edited preview remains visible while its replacement loads")
        controller.cancelPendingMediaLoad()
        #expect(controller.mediaLoadSessionDiagnostics == before)
        pending?.resume(returning: .init(size: CGSize(width: 160, height: 100), transform: .identity, duration: 1))
        for _ in 0..<30 { await Task.yield() }
        #expect(errors.isEmpty)
        #expect(controller.mediaLoadSessionDiagnostics == before)
        #expect(try ProjectFile.decode(controller.projectData()) == session)
    }

    @Test @MainActor func emptyWindowPendingVideoCannotPublishABackingImageAsAReadyFrame() async throws {
        _ = NSApplication.shared
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let still = folder.appendingPathComponent("still.png")
        try image(still)
        var pending: CheckedContinuation<DocumentModel.VideoMetadata, Error>?
        let controller = MainWindowController(videoLoader: { _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        }, loadErrorPresenter: { _ in })
        let window = try #require(controller.window)
        window.isReleasedWhenClosed = false
        controller.showWindow(nil)
        defer { controller.close() }
        defer {
            controller.cancelPendingMediaLoad()
            pending?.resume(throwing: CancellationError())
            pending = nil
        }
        let container = try #require(window.contentViewController as? MainContainerViewController)
        container.view.layoutSubtreeIfNeeded()
        container.liveBlur.setNeedsDisplay()
        container.liveBlur.displayIfNeeded()
        #expect(container.liveBlur.contents == nil, "An empty layer backing is not a decoded media frame")

        controller.load(url: URL(fileURLWithPath: "/synthetic/\(UUID()).mov"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while pending == nil, ContinuousClock.now < deadline { await Task.yield() }
        try #require(pending != nil)
        #expect(controller.mediaLoadSessionDiagnostics.pending)
        #expect(controller.mediaLoadSessionDiagnostics.sourceURL == nil)
        window.setContentSize(CGSize(width: 1300, height: 560))
        container.view.layoutSubtreeIfNeeded()
        container.liveBlur.setNeedsDisplay()
        container.liveBlur.displayIfNeeded()
        #expect(container.liveBlur.contents == nil, "A resize during metadata loading must not signal frame readiness")

        controller.cancelPendingMediaLoad()
        pending?.resume(returning: .init(size: CGSize(width: 640, height: 360), transform: .identity, duration: 1))
        pending = nil
        for _ in 0..<30 { await Task.yield() }
        #expect(!controller.mediaLoadSessionDiagnostics.pending)
        #expect(container.liveBlur.contents == nil)
        controller.load(url: still)
        #expect(controller.mediaLoadSessionDiagnostics.sourceURL == still)
        #expect(!controller.mediaLoadSessionDiagnostics.pending)
        #expect(container.canvas.isEditable && container.playerLayer.isHidden)
        #expect(container.liveBlur.contents != nil)
        let fit = container.aspectFitVideo.frame
        #expect(abs(fit.width / fit.height - 16.0 / 12.0) < 0.01)
    }

    @Test @MainActor func controllerVerifiedNewImageCommitsAsFreshSession() throws {
        _ = NSApplication.shared
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appendingPathComponent("a.png"), b = folder.appendingPathComponent("b.png")
        try image(a); try image(b, white: false)
        var errors: [String] = []
        let controller = MainWindowController(loadErrorPresenter: { errors.append($0) })
        defer { controller.close() }
        _ = try prepareDirtySession(controller, sources: [a])
        controller.load(url: b)
        let state = controller.mediaLoadSessionDiagnostics
        #expect(errors.isEmpty && !state.pending)
        let expectedDigest = try PageWorkspace.digest(of: b)
        #expect(state.sourceURL == b && state.sourceSHA256 == expectedDigest)
        #expect(state.undoDepth == 0 && state.redoDepth == 0)
        #expect(state.selectedRegion == nil && state.selectedDrawing == nil && state.multiSelection.isEmpty)
        #expect(state.workspaceIndex == nil && !state.dirty)
        let project = try ProjectFile.decode(controller.projectData())
        #expect(project.regions.isEmpty && project.drawings.isEmpty)
    }

    @Test @MainActor func changedLaterWorkspaceImageCannotReplaceCurrentPageAndEdits() throws {
        _ = NSApplication.shared
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appendingPathComponent("a.png"), b = folder.appendingPathComponent("b.png")
        try image(a); try image(b)
        var errors: [String] = []
        let controller = MainWindowController(loadErrorPresenter: { errors.append($0) })
        controller.window?.isReleasedWhenClosed = false
        controller.showWindow(nil)
        defer { controller.close() }
        controller.load(urls: [a, b])
        let container = try #require(controller.window?.contentViewController as? MainContainerViewController)
        container.canvas.addRegionHandler?()
        controller.window?.isDocumentEdited = true
        let session = try ProjectFile.decode(controller.projectData())
        let before = controller.mediaLoadSessionDiagnostics
        let pixels = container.liveBlur.sourceCGImage
        try image(b, white: false)
        controller.perform(NSSelectorFromString("nextPageTapped"))
        #expect(errors.count == 1 && errors.first?.contains("원본") == true)
        #expect(controller.mediaLoadSessionDiagnostics == before)
        #expect(try ProjectFile.decode(controller.projectData()) == session)
        #expect(container.liveBlur.sourceCGImage === pixels)
        #expect(container.pageLabel.stringValue == "1 / 2")
        controller.perform(NSSelectorFromString("undoTapped"))
        #expect(try ProjectFile.decode(controller.projectData()).regions.isEmpty)
    }

    @Test func workspacePageDecodeRejectsChangedFingerprintAndSameBytesSymlink() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.png")
        try image(source)
        let workspace = try PageWorkspace.open([source])
        _ = try workspace.image(at: 0)
        try image(source, white: false)
        #expect(throws: PageWorkspace.WorkspaceError.sourceChanged) { try workspace.image(at: 0) }
        let current = try PageWorkspace.open([source])
        let moved = folder.appendingPathComponent("moved.png")
        try FileManager.default.moveItem(at: source, to: moved)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: moved)
        #expect(throws: PageWorkspace.WorkspaceError.sourceChanged) { try current.image(at: 0) }
    }

    @Test func cachedPDFCannotRenderNextPageAfterOriginalChanges() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.pdf")
        var box = CGRect(x: 0, y: 0, width: 60, height: 40)
        let pdf = try #require(CGContext(source as CFURL, mediaBox: &box, nil))
        for _ in 0..<2 {
            pdf.beginPDFPage(nil)
            pdf.setFillColor(CGColor(gray: 1, alpha: 1)); pdf.fill(box)
            pdf.endPDFPage()
        }
        pdf.closePDF()
        let workspace = try PageWorkspace.open([source])
        let output = folder.appendingPathComponent("must-not-publish.pdf")
        var rendered: [Int] = []
        var replacementError: Error?
        #expect(throws: PageWorkspace.WorkspaceError.sourceChanged) {
            try workspace.exportPDF(to: output, progress: { count, _ in
                rendered.append(count)
                if count == 1 {
                    do { try Data("changed source PDF".utf8).write(to: source) }
                    catch { replacementError = error }
                }
            })
        }
        #expect(replacementError == nil)
        #expect(rendered == [1], "Cached PDF page two must be refused before it is drawn")
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}
