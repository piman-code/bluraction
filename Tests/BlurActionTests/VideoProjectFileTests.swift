import AppKit
import Darwin
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BlurAction

/// Authored data/public MOVs only. Native object/worker tests, no OS input.
@Suite(.serialized)
struct VideoProjectFileTests {
    private typealias R = VideoTimeline.Rational
    private func timeline() throws -> VideoTimeline {
        try .init(assetDuration: R(3), tracks: [.init(id: 1, kind: "video", mediaTimescale: 12,
            segments: [.init(assetStart: R(0), assetDuration: R(3), mediaStart: R(0), rate: R(1))])])
    }
    private func folder() throws -> URL {
        let result = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("bluraction-v3-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false)
        return result
    }
    private func binding(_ folder: URL) throws -> VideoProjectSourceBinding {
        let source = folder.appendingPathComponent("authored.bin")
        try Data("original fixture bytes".utf8).write(to: source)
        return try .init(source: VideoProjectSourceBinding.Source.capture(source), timeline: timeline())
    }
    private func edits() -> ProjectFile {
        let group = UUID()
        var effect = RegionEffect.alwaysOn()
        effect.style = .solid; effect.blurRadius = 12.3; effect.featherRadius = 0
        effect.timeRange = 4...6; effect.enabled = false; effect.locked = true
        effect.groupID = group; effect.name = "원래 영역"
        effect.erasures = [.init(points: [.init(x: 0.1, y: 0.2)], width: 0.03, from: nil),
                           .init(points: [.init(x: 0.2, y: 0.3)], width: 0.04, from: 5.125)]
        effect.keyframes = [.init(time: 2, rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)),
                            .init(time: 1, rect: CGRect(x: 0.2, y: 0.1, width: 0.4, height: 0.3)),
                            .init(time: 1, rect: CGRect(x: 0.3, y: 0.1, width: 0.3, height: 0.3))]
        let region = ProjectFile.Region(shape: .rectangle(id: UUID(), origin: .init(x: 0.1, y: 0.2),
            size: .init(width: 0.6, height: 0.5)), effect: effect)
        let drawings = [DrawingAnnotation.Kind.rectangle, .ellipse, .line, .freehand, .arrow, .text].map { kind in
            var d = DrawingAnnotation(kind: kind, points: [.init(x: 0.12, y: 0.15), .init(x: 0.68, y: 0.55)],
                color: NSColor(srgbRed: 0.3, green: 0.5, blue: 0.7, alpha: 0.5), lineWidth: 0.02, fillOpacity: 0.375)
            d.timeRange = 4...6; d.groupID = group; d.hidden = true; d.locked = true
            d.text = "원래 첫 줄\n둘째 줄"; d.bold = false; d.erasures = effect.erasures; d.keyframes = effect.keyframes
            return d
        }
        return ProjectFile(mediaPath: "original.mov", regions: [region], drawings: drawings)
    }
    private func project(_ binding: VideoProjectSourceBinding) throws -> VideoProjectFile {
        let e = edits()
        return try .make(mediaPath: "original.mov", binding: binding, producerVersion: "test.1",
                         regions: e.regions, drawings: e.drawings)
    }
    private func replaced(_ bytes: Data, _ before: String, _ after: String) throws -> Data {
        let text = try #require(String(data: bytes, encoding: .utf8))
        #expect(text.contains(before))
        return Data(text.replacingOccurrences(of: before, with: after).utf8)
    }

    @Test @MainActor
    func richKnownEditsAndUnsortedDuplicateMotionSurviveStrictDecode() throws {
        let f = try folder(); defer { try? FileManager.default.removeItem(at: f) }
        let b = try binding(f), p = try project(b), data = try p.encoded(), reopened = try VideoProjectFile.decode(data)
        #expect(reopened.edits == p.edits)
        #expect(reopened.timeline == b.timeline)
        #expect(reopened.payload.drawings.count == 6)
        #expect(reopened.payload.regions[0].effect.timeRange == 4...6)
        #expect(reopened.payload.regions[0].effect.keyframes.map(\.time) == [2, 1, 1])
        #expect(reopened.payload.regions[0].effect.erasures[0].from == nil)
        let unknown = try replaced(data, "\"mediaKind\":\"video\"", "\"mediaKind\":\"video\",\"future\":900719925474099312345")
        do { _ = try VideoProjectFile.decode(unknown); Issue.record("unknown semantic field was accepted") }
        catch let review as VideoProjectFile.Review { #expect(review.originalData == unknown) }
        try b.source.validate()
    }

    @Test @MainActor
    func rawNumbersNullOmissionAndUnchangedFieldsSurviveAnActualFieldPatch() throws {
        let f = try folder(); defer { try? FileManager.default.removeItem(at: f) }
        let b = try binding(f), p = try project(b)
        var data = try replaced(p.encoded(), "\"blurRadius\":12.3", "\"blurRadius\":1.2300e+1")
        data = try replaced(data, "\"name\":\"원래 영역\"", "\"name\":\"원래 영역\",\"color\":null")
        // Remove the separately encoded default color so explicit-null remains unique.
        let rawText = try #require(String(data: data, encoding: .utf8))
        let original = try #require(String(data: p.encoded(), encoding: .utf8))
        let colorStart = try #require(original.range(of: "\"color\":{"))
        let colorEnd = try #require(original[colorStart.upperBound...].firstIndex(of: "}"))
        let defaultColor = String(original[colorStart.lowerBound...colorEnd]) + ","
        data = Data(rawText.replacingOccurrences(of: defaultColor, with: "").utf8)
        let loaded = try VideoProjectFile.decode(data)
        var current = loaded.edits; current.drawings[0].name = "변경한 이름"
        let updated = try loaded.updated(mediaPath: "original.mov", binding: b, producerVersion: "test.2",
            baseline: loaded.edits, current: current, normalized: current)
        let result = try #require(String(data: updated.encoded(), encoding: .utf8))
        #expect(result.contains("\"blurRadius\":1.2300e+1"))
        #expect(result.contains("\"color\":null"))
        #expect(updated.payload.regions == loaded.payload.regions)
        #expect(updated.payload.drawings[0].name == "변경한 이름")
        #expect(updated.payload.drawings.dropFirst() == loaded.payload.drawings.dropFirst())
    }

    @Test @MainActor
    func strictVersionMandatoryClockFieldsDuplicatesAndInexactIntegerAreRejected() throws {
        let f = try folder(); defer { try? FileManager.default.removeItem(at: f) }
        let data = try project(binding(f)).encoded()
        for (before, after) in [("\"version\":3", "\"version\":3.0"),
            ("\"version\":3", "\"version\":true"),
            ("\"mediaKind\":\"video\"", "\"mediaKind\":\"image\""),
            ("\"basis\":\"asset-presentation\"", "\"basis\":\"asset-presentation\",\"origin\":0"),
            ("\"timeRange\":[4,6]", "\"timeRange\":[9007199254740993,9007199254740993]"),
            ("\"version\":3", "\"version\":3,\"vers\\u0069on\":3")] {
            let changed = try replaced(data, before, after)
            #expect(throws: Error.self) { _ = try VideoProjectFile.decode(changed) }
        }
        let old = Data("{\"version\":1,\"mediaPath\":\"image.png\",\"regions\":[],\"drawings\":[]}".utf8)
        let v1 = try ProjectFile.decode(old)
        #expect(v1.version == 1)
    }

    @Test
    func dispatchRejectsDuplicateAndCoercedVersionsWithoutReducingV2ByteLimit() throws {
        for text in ["{\"version\":3,\"version\":1}", "{\"version\":1,\"vers\\u0069on\":3}",
                     "{\"version\":3.0}", "{\"version\":3e0}", "{\"version\":true}",
                     "{\"version\":\"3\"}", "{\"version\":2,\"extra\":{\"a\":1,\"a\":2}}",
                     "{\"version\":2,\"extra\":[1,]}", "{\"version\":2} trailing"] {
            #expect(throws: Error.self) { _ = try VideoProjectFile.version(of: Data(text.utf8)) }
        }
        let v1 = Data("{\"version\":1,\"mediaPath\":\"one.png\",\"regions\":[],\"drawings\":[]}".utf8)
        let one = try VideoProjectFile.version(of: v1); #expect(one == 1)
        var largeV2 = Data("{\"version\":2,\"title\":\"one\",\"currentIndex\":0,\"pages\":[{\"mediaPath\":\"one.png\",\"regions\":[],\"drawings\":[]}]}".utf8)
        largeV2.append(Data(repeating: 32, count: ProjectFile.maximumBytes))
        let two = try VideoProjectFile.version(of: largeV2); #expect(two == 2)
        let decoded = try MultiPageProjectFile.decode(largeV2); #expect(decoded.pages.count == 1)
    }

    @Test @MainActor
    func unknownLegacySemanticsRequireOriginalDataReviewBeforePromotion() throws {
        let legacy = edits(), encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let original = try encoder.encode(legacy)
        let known = try VideoProjectFile.decodeLegacy(original)
        #expect(known == legacy)
        for (before, after) in [("\"version\":1", "\"version\":1,\"futurePolicy\":\"uninterpreted\""),
            ("\"blurRadius\":12.3", "\"blurRadius\":12.3,\"futureCover\":900719925474099312345"),
            ("\"fillOpacity\":0.375", "\"fillOpacity\":0.375,\"futureText\":{\"metric\":17}"),
            ("\"width\":0.03", "\"width\":0.03,\"futureErase\":true")] {
            let unknown = try replaced(original, before, after)
            // Old Codable accepting this demonstrates why the raw check belongs
            // before projection/source commit, not after making a new v3 DTO.
            _ = try ProjectFile.decode(unknown)
            do { _ = try VideoProjectFile.decodeLegacy(unknown); Issue.record("legacy unknown fields were discarded") }
            catch let review as VideoProjectFile.Review { #expect(review.originalData == unknown) }
        }
        let after = try encoder.encode(legacy); #expect(after == original)
        #expect(known.regions[0].effect.timeRange == 4...6)
        #expect(known.regions[0].effect.keyframes.map(\.time) == [2, 1, 1])
    }

    @Test
    func rootParentTerminatesAndFilesystemAliasesRemainBoundWithoutAcceptingLeafLinks() throws {
        print("[v3-source-route] root-parent")
        let roots = try VideoProjectSourceBinding.Source.parentStates(URL(fileURLWithPath: "/authored-no-read"))
        #expect(roots.count == 1)
        let f = try folder(); defer { try? FileManager.default.removeItem(at: f) }
        let b = try binding(f)
        try b.source.validate()
        let canonical = try VideoProjectSourceBinding.Source.resolved(b.source.url)
        print("[v3-source-route] canonical capture path=\(canonical.path) foundation=\(canonical.standardizedFileURL.path)")
        let actual = try VideoProjectSourceBinding.Source.capture(canonical)
        #expect(actual.sha256 == b.source.sha256)
        #expect(b.source.canonical.path == canonical.path)
        if canonical.path.hasPrefix("/private/var/") {
            let varAlias = URL(fileURLWithPath: String(canonical.path.dropFirst("/private".count)))
            print("[v3-source-route] var-alias")
            let alias = try VideoProjectSourceBinding.Source.capture(varAlias)
            try alias.validate(); #expect(alias.sha256 == actual.sha256)
            #expect(alias.canonical.path == canonical.path)
        }
        let leaf = f.appendingPathComponent("linked.bin")
        try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: b.source.url)
        print("[v3-source-route] leaf-link rejection")
        #expect(throws: Error.self) { _ = try VideoProjectSourceBinding.Source.capture(leaf) }
        let first = f.appendingPathComponent("first", isDirectory: true)
        let second = f.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        let bytes = try Data(contentsOf: b.source.url)
        try bytes.write(to: first.appendingPathComponent("same.bin"))
        try bytes.write(to: second.appendingPathComponent("same.bin"))
        let route = f.appendingPathComponent("route")
        try FileManager.default.createSymbolicLink(at: route, withDestinationURL: first)
        print("[v3-source-route] authored parent-alias capture path=\(route.appendingPathComponent("same.bin").path) foundation=\(route.appendingPathComponent("same.bin").standardizedFileURL.path)")
        let routed = try VideoProjectSourceBinding.Source.capture(route.appendingPathComponent("same.bin"))
        try routed.validate()
        try FileManager.default.removeItem(at: route)
        try FileManager.default.createSymbolicLink(at: route, withDestinationURL: second)
        print("[v3-source-route] parent-alias retarget rejection")
        #expect(throws: Error.self) { try routed.validateIdentity() }
        #expect(throws: Error.self) { try routed.validate() }
        let preserved = try Data(contentsOf: b.source.url); #expect(preserved == bytes)
    }

    @Test @MainActor
    func descriptorAndSourceByteIdentityMustBothMatchAndRelinkOnlyChangesPath() throws {
        let f = try folder(); defer { try? FileManager.default.removeItem(at: f) }
        let b = try binding(f), p = try project(b)
        try p.verify(binding: b)
        let relinked = try p.relinked(to: "renamed.mov")
        #expect(relinked.payload.regions == p.payload.regions)
        #expect(relinked.payload.drawings == p.payload.drawings)
        #expect(relinked.sourceSHA256 == p.sourceSHA256)
        #expect(relinked.timeline == p.timeline)
        let differentTimeline = try VideoTimeline(assetDuration: R(4), tracks: b.timeline.tracks)
        let wrong = VideoProjectSourceBinding(source: b.source, timeline: differentTimeline)
        #expect(throws: Error.self) { try p.verify(binding: wrong) }
        let oldBytes = try Data(contentsOf: b.source.url)
        try Data("changed fixture bytes".utf8).write(to: b.source.url)
        #expect(throws: Error.self) { try b.source.validate() }
        let changedBytes = try Data(contentsOf: b.source.url)
        #expect(oldBytes != changedBytes)
    }

    @Test @MainActor
    func newFilePublicationRejectsCollisionSourceChangeAndCancellation() throws {
        let f = try folder(); defer { try? FileManager.default.removeItem(at: f) }
        let b = try binding(f), p = try project(b), data = try p.encoded()
        let output = f.appendingPathComponent("existing.bluraction"), nonce = Data("existing destination".utf8)
        try nonce.write(to: output)
        #expect(throws: Error.self) { try VideoProjectPublication.write(data, to: output, source: b.source) }
        let after = try Data(contentsOf: output); #expect(after == nonce)
        let cancelled = f.appendingPathComponent("cancelled.bluraction")
        #expect(throws: CancellationError.self) {
            try VideoProjectPublication.write(data, to: cancelled, source: b.source) { throw CancellationError() }
        }
        #expect(!FileManager.default.fileExists(atPath: cancelled.path))
        let success = f.appendingPathComponent("fresh.bluraction")
        try VideoProjectPublication.write(data, to: success, source: b.source)
        let saved = try VideoProjectFile.decode(VideoProjectFile.read(at: success))
        #expect(saved.edits == p.edits)
        try b.source.validate()
    }

    @Test
    func firstTemporaryStatFailureRetainsOwnedFDForSafeRetryWithoutPublishingOrRemovingOthers() throws {
        enum Fault: Error, Equatable { case initialStat, cleanupStat }
        let f = try folder(); defer { try? FileManager.default.removeItem(at: f) }
        let b = try binding(f), output = f.appendingPathComponent("unpublished.bluraction")
        let nonce = f.appendingPathComponent("unrelated.bin"), nonceBytes = Data("leave this file".utf8)
        try nonceBytes.write(to: nonce)
        let original = try Data(contentsOf: b.source.url)
        var attempts = 0, ownedFD: Int32 = -1
        var cleanupOwner: VideoProjectPublication.CleanupFailure?
        do {
            try VideoProjectPublication.write(Data("candidate".utf8), to: output, source: b.source,
                _temporaryIdentity: { fd in
                    ownedFD = fd; attempts += 1
                    if attempts == 1 { throw Fault.initialStat }
                    if attempts == 2 { throw Fault.cleanupStat }
                    var status = stat()
                    guard fstat(fd, &status) == 0 else { throw Fault.cleanupStat }
                    return [Int64(status.st_dev), Int64(status.st_ino)]
                })
            Issue.record("failed temporary identity acquisition published data")
        } catch let owner as VideoProjectPublication.CleanupFailure { cleanupOwner = owner }
        let owner = try #require(cleanupOwner)
        #expect((owner.primary as? Fault) == .initialStat)
        #expect((owner.cleanup as? Fault) == .cleanupStat)
        #expect(attempts == 2)
        #expect(fcntl(ownedFD, F_GETFD) >= 0)
        #expect(FileManager.default.fileExists(atPath: owner.temporary.path))
        #expect(!FileManager.default.fileExists(atPath: output.path))
        try owner.retryCleanup()
        #expect(attempts == 3)
        #expect(fcntl(ownedFD, F_GETFD) == -1)
        #expect(!FileManager.default.fileExists(atPath: owner.temporary.path))
        try owner.retryCleanup() // Successful cleanup is idempotent.
        let sourceAfter = try Data(contentsOf: b.source.url), otherAfter = try Data(contentsOf: nonce)
        #expect(sourceAfter == original); #expect(otherAfter == nonceBytes)
        try b.source.validate()
    }

    private var fixtureRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("shared/fixtures/video-timelines")
    }
    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(condition(), "native controller operation did not complete")
    }
    @MainActor
    private func controls(_ controller: MainWindowController) throws -> MainContainerViewController {
        try #require(controller.window?.contentViewController as? MainContainerViewController)
    }

    @Test @MainActor
    func actualNonzeroAndNegativeMOVControllerReopenResizeSaveKeepsOriginalPeriods() async throws {
        _ = NSApplication.shared
        for name in ["nonzero-origin", "video-negative-twelfth-audio-negative-quarter"] {
            let source = fixtureRoot.appendingPathComponent(name + ".mov")
            let original = try Data(contentsOf: source)
            let b = try await VideoProjectSourceBinding.observe(url: source)
            let p = try project(b)
            var errors: [String] = []
            let controller = MainWindowController(loadErrorPresenter: { errors.append($0) })
            defer { controller.cancelPendingMediaLoad(); controller.close() }
            controller.openVideoProject(p, media: source)
            try await wait { !controller.mediaLoadSessionDiagnostics.pending }
            #expect(errors.isEmpty)
            let loaded = try VideoProjectFile.decode(controller.projectData(producerVersion: "test.native"))
            #expect(loaded.payload.regions == p.payload.regions)
            #expect(loaded.payload.drawings == p.payload.drawings)
            controller.window?.setContentSize(.init(width: 923, height: 617))
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            controller.window?.setContentSize(.init(width: 1083, height: 699))
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            let resized = try VideoProjectFile.decode(controller.projectData(producerVersion: "test.native"))
            #expect(resized.edits == loaded.edits)
            let after = try Data(contentsOf: source); #expect(after == original)
            let f = try folder(); defer { try? FileManager.default.removeItem(at: f) }
            let output = f.appendingPathComponent("actual-native.bluraction")
            try controller.saveVideoProject(to: output, producerVersion: "test.native")
            try await wait { !controller.projectSaveInProgress }
            #expect(errors.isEmpty)
            let saved = try VideoProjectFile.decode(VideoProjectFile.read(at: output))
            #expect(saved.payload.regions == loaded.payload.regions)
            #expect(saved.payload.drawings == loaded.payload.drawings)
            #expect(saved.timeline == b.timeline)
        }
    }

    @Test @MainActor
    func actualDescriptorMismatchPreservesDirtyImageUndoAndProjectBytes() async throws {
        _ = NSApplication.shared
        let f = try folder(); defer { try? FileManager.default.removeItem(at: f) }
        let imageURL = f.appendingPathComponent("original.png")
        let provider = try #require(CGDataProvider(data: Data(repeating: 255, count: 64 * 48 * 4) as CFData))
        let image = try #require(CGImage(width: 64, height: 48, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 64 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = try #require(CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil); #expect(CGImageDestinationFinalize(output))
        let originalImage = try Data(contentsOf: imageURL)
        var errors: [String] = []
        let controller = MainWindowController(loadErrorPresenter: { errors.append($0) })
        defer { controller.cancelPendingMediaLoad(); controller.close() }
        controller.load(url: imageURL)
        let ui = try controls(controller)
        ui.canvas.annotationAdded?(DrawingAnnotation(kind: .line, points: [.init(x: 10, y: 10), .init(x: 40, y: 30)]))
        let previous = try controller.projectData()
        let diagnostics = controller.mediaLoadSessionDiagnostics
        let source = fixtureRoot.appendingPathComponent("nonzero-origin.mov")
        let b = try await VideoProjectSourceBinding.observe(url: source)
        let p = try project(b)
        let bytes = try p.encoded()
        let scale = b.timeline.tracks[0].mediaTimescale
        let altered = try replaced(bytes, "\"mediaTimescale\":\(scale)", "\"mediaTimescale\":\(scale + 1)")
        let mismatch = try VideoProjectFile.decode(altered)
        controller.openVideoProject(mismatch, media: source)
        try await wait { !controller.mediaLoadSessionDiagnostics.pending }
        #expect(!errors.isEmpty)
        let after = try controller.projectData(); #expect(after == previous)
        #expect(controller.mediaLoadSessionDiagnostics == diagnostics)
        let imageAfter = try Data(contentsOf: imageURL); #expect(imageAfter == originalImage)
        let preserved = try p.encoded(); #expect(preserved == bytes)
    }

    @Test @MainActor
    func actualFullDrawingCapProjectsAllItemsWithoutTruncation() async throws {
        _ = NSApplication.shared
        let source = fixtureRoot.appendingPathComponent("gap0-vfr.mov")
        let before = try Data(contentsOf: source), b = try await VideoProjectSourceBinding.observe(url: source)
        var drawings: [DrawingAnnotation] = []
        for _ in 0..<5_000 {
            var drawing = DrawingAnnotation(kind: .line, points: [.init(x: 0.1, y: 0.1), .init(x: 0.2, y: 0.2)], lineWidth: 0.01)
            drawing.hidden = true; drawings.append(drawing)
        }
        let p = try VideoProjectFile.make(mediaPath: source.lastPathComponent, binding: b,
            producerVersion: "test.cap", regions: [], drawings: drawings)
        var errors: [String] = []
        let controller = MainWindowController(loadErrorPresenter: { errors.append($0) })
        defer { controller.cancelPendingMediaLoad(); controller.close() }
        controller.openVideoProject(p, media: source)
        try await wait { !controller.mediaLoadSessionDiagnostics.pending }
        #expect(errors.isEmpty)
        let saved = try VideoProjectFile.decode(controller.projectData(producerVersion: "test.cap"))
        #expect(saved.payload.drawings == drawings)
        let after = try Data(contentsOf: source); #expect(after == before)
        #expect(saved.payload.drawings.count == 5_000)
    }

    @Test @MainActor
    func missingNamedFontIsAnExplicitHoldNotAStoredFamilyRewrite() throws {
        var d = DrawingAnnotation(kind: .text, points: [.zero, .init(x: 0.5, y: 0.5)], lineWidth: 0.01)
        d.text = "글꼴 검수"; d.fontName = "BlurActionNeverInstalledFont-" + UUID().uuidString
        let old = d
        #expect(throws: VideoProjectFile.Review.self) { try VideoProjectFile.requireAvailableFonts([d]) }
        #expect(d == old)
        d.fontName = nil
        try VideoProjectFile.requireAvailableFonts([d])
    }

    @Test @MainActor
    func hiddenMissingFontCannotBeUnhiddenOrExportedThroughSystemFallback() async throws {
        _ = NSApplication.shared
        let source = fixtureRoot.appendingPathComponent("gap0-vfr.mov")
        let b = try await VideoProjectSourceBinding.observe(url: source)
        var drawing = DrawingAnnotation(kind: .text, points: [.init(x: 0.1, y: 0.1), .init(x: 0.5, y: 0.3)], lineWidth: 0.01)
        drawing.text = "원래 글꼴"; drawing.hidden = true
        drawing.fontName = "BlurActionNeverInstalledFont-" + UUID().uuidString
        let p = try VideoProjectFile.make(mediaPath: source.lastPathComponent, binding: b,
            producerVersion: "test.font", regions: [], drawings: [drawing])
        var errors: [String] = []
        let controller = MainWindowController(loadErrorPresenter: { errors.append($0) })
        defer { controller.cancelPendingMediaLoad(); controller.close() }
        controller.openVideoProject(p, media: source)
        try await wait { !controller.mediaLoadSessionDiagnostics.pending }
        #expect(errors.isEmpty)
        let before = try controller.projectData(producerVersion: "test.font"), diagnostics = controller.mediaLoadSessionDiagnostics
        controller.setLayerHidden(drawing.id, false)
        #expect(errors.count == 1)
        let after = try controller.projectData(producerVersion: "test.font"); #expect(after == before)
        #expect(controller.mediaLoadSessionDiagnostics == diagnostics)
        try controller.validateExportFonts() // Hidden original remains safe to preserve.
        let ui = try controls(controller)
        drawing.id = UUID(); drawing.hidden = false
        ui.canvas.annotationAdded?(drawing)
        #expect(throws: VideoProjectFile.Review.self) { try controller.validateExportFonts() }
        let visible = try VideoProjectFile.decode(controller.projectData(producerVersion: "test.font"))
        #expect(visible.payload.drawings.last?.fontName == drawing.fontName)
    }

    @Test @MainActor
    func actualExplicitTemplateUsesTargetBindingAndClipsOnlyItsRange() async throws {
        _ = NSApplication.shared
        let originalSource = fixtureRoot.appendingPathComponent("nonzero-origin.mov")
        let target = fixtureRoot.appendingPathComponent("gap0-vfr.mov")
        let sourceBytes = try Data(contentsOf: originalSource), targetBytes = try Data(contentsOf: target)
        let oldBinding = try await VideoProjectSourceBinding.observe(url: originalSource)
        let targetBinding = try await VideoProjectSourceBinding.observe(url: target)
        let p = try project(oldBinding), oldProjectBytes = try p.encoded()
        var errors: [String] = []
        let controller = MainWindowController(loadErrorPresenter: { errors.append($0) })
        defer { controller.cancelPendingMediaLoad(); controller.close() }
        controller.openVideoProject(p, media: target, asTemplate: true)
        try await wait { !controller.mediaLoadSessionDiagnostics.pending }
        #expect(errors.isEmpty)
        let saved = try VideoProjectFile.decode(controller.projectData(producerVersion: "test.template"))
        #expect(saved.sourceSHA256 == targetBinding.source.sha256)
        #expect(saved.sourceSHA256 != p.sourceSHA256)
        #expect(saved.timeline == targetBinding.timeline)
        let duration = Double(targetBinding.timeline.assetDuration.numerator) / Double(targetBinding.timeline.assetDuration.denominator)
        #expect(saved.payload.regions[0].effect.timeRange == duration...duration)
        #expect(saved.payload.drawings.allSatisfy { $0.timeRange == duration...duration })
        #expect(saved.payload.regions[0].effect.keyframes.map(\.time) == p.payload.regions[0].effect.keyframes.map(\.time))
        #expect(saved.payload.regions[0].effect.erasures.map(\.from) == p.payload.regions[0].effect.erasures.map(\.from))
        let afterOriginal = try Data(contentsOf: originalSource), afterTarget = try Data(contentsOf: target)
        #expect(afterOriginal == sourceBytes); #expect(afterTarget == targetBytes)
        let afterProject = try p.encoded(); #expect(afterProject == oldProjectBytes)
    }

    @Test @MainActor
    func actualImageWorkerReturnsBusyAllowsCancelAndPreservesOriginalEdits() async throws {
        _ = NSApplication.shared
        let f = try folder(); defer { try? FileManager.default.removeItem(at: f) }
        let source = f.appendingPathComponent("worker-original.png")
        let bytes = Data(repeating: 255, count: 96 * 64 * 4)
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let image = try #require(CGImage(width: 96, height: 64, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 96 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let writer = try #require(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, nil); #expect(CGImageDestinationFinalize(writer))
        let original = try Data(contentsOf: source)
        let controller = MainWindowController(loadErrorPresenter: { _ in Issue.record("unexpected image load error") })
        defer { controller.close() }
        controller.load(url: source)
        let ui = try controls(controller)
        ui.canvas.annotationAdded?(DrawingAnnotation(kind: .line,
            points: [.init(x: 10, y: 10), .init(x: 40, y: 30)], color: .black))
        let before = try controller.projectData(), diagnostics = controller.mediaLoadSessionDiagnostics
        let cancelled = f.appendingPathComponent("cancelled.png")
        var result: Result<URL, Error>?
        try controller.exportImageSnapshot(cgImage: image, to: cancelled, type: .png, compression: 1) {
            #expect(Thread.isMainThread); result = $0
        }
        let busyCanLoad = ui.canvas.canLoadFilesBinding?()
        #expect(busyCanLoad == false)
        controller.cancelCurrentOperation()
        var heartbeat = false
        DispatchQueue.main.async { heartbeat = true }
        try await wait { result != nil && heartbeat }
        let cancelledResult = try #require(result)
        guard case .failure = cancelledResult else { Issue.record("cancelled worker published output"); return }
        #expect(!FileManager.default.fileExists(atPath: cancelled.path))
        let idleCanLoad = ui.canvas.canLoadFilesBinding?()
        #expect(idleCanLoad == true)
        let afterCancelled = try controller.projectData(); #expect(afterCancelled == before)
        #expect(controller.mediaLoadSessionDiagnostics == diagnostics)
        result = nil
        let success = f.appendingPathComponent("fresh.png")
        try controller.exportImageSnapshot(cgImage: image, to: success, type: .png, compression: 1) { result = $0 }
        try await wait { result != nil }
        let outcome = try #require(result)
        let output = try outcome.get(); #expect(output == success)
        let decoder = try #require(CGImageSourceCreateWithURL(success as CFURL, nil))
        let pixels = try #require(CGImageSourceCreateImageAtIndex(decoder, 0, nil))
        #expect(pixels.width == 96 && pixels.height == 64)
        let afterSuccess = try controller.projectData(); #expect(afterSuccess == before)
        let sourceAfter = try Data(contentsOf: source); #expect(sourceAfter == original)
        #expect(controller.mediaLoadSessionDiagnostics == diagnostics)
    }

    @Test @MainActor
    func actualImportWorkerCancelsAndRejectsChangedSourceBeforeOneAtomicCommit() async throws {
        _ = NSApplication.shared
        let f = try folder(); defer { try? FileManager.default.removeItem(at: f) }
        let authored = fixtureRoot.appendingPathComponent("gap0-vfr.mov")
        let original = try Data(contentsOf: authored), source = f.appendingPathComponent("target.mov")
        try original.write(to: source)
        let b = try await VideoProjectSourceBinding.observe(url: source), p = try project(b)
        var errors: [String] = []
        let controller = MainWindowController(loadErrorPresenter: { errors.append($0) })
        defer { controller.cancelCurrentOperation(); controller.cancelPendingMediaLoad(); controller.close() }
        controller.openVideoProject(p, media: source)
        try await wait { !controller.mediaLoadSessionDiagnostics.pending }
        #expect(errors.isEmpty)
        let ui = try controls(controller)
        ui.canvas.annotationAdded?(DrawingAnnotation(kind: .line, points: [.init(x: 10, y: 10), .init(x: 35, y: 30)]))
        // The existing controller edit hooks do not set NSWindow's dirty flag;
        // establish the same explicit dirty-session control used by the native
        // transaction regression suite, then require preservation throughout.
        controller.window?.isDocumentEdited = true
        #expect(controller.window?.isDocumentEdited == true)
        let before = try controller.projectData(producerVersion: "test.import"), diagnostics = controller.mediaLoadSessionDiagnostics
        var result: Result<Void, Error>?, heartbeat = false
        try controller.importVideoProjectItems(p) { #expect(Thread.isMainThread); result = $0 }
        let busy = ui.canvas.canLoadFilesBinding?(); #expect(busy == false)
        controller.cancelCurrentOperation()
        DispatchQueue.main.async { heartbeat = true }
        try await wait { result != nil && heartbeat }
        let cancelled = try #require(result)
        guard case .failure(let cancellation) = cancelled else { Issue.record("cancelled import committed items"); return }
        #expect(cancellation is CancellationError)
        let afterCancel = try controller.projectData(producerVersion: "test.import"); #expect(afterCancel == before)
        #expect(controller.mediaLoadSessionDiagnostics == diagnostics)
        result = nil
        try controller.importVideoProjectItems(p) { result = $0 }
        try await wait { result != nil }
        let successful = try #require(result)
        try successful.get()
        let saved = try VideoProjectFile.decode(controller.projectData(producerVersion: "test.import"))
        let previous = try VideoProjectFile.decode(before)
        #expect(saved.payload.regions.count == previous.payload.regions.count + p.payload.regions.count)
        #expect(saved.payload.drawings.count == previous.payload.drawings.count + p.payload.drawings.count)
        #expect(Set(saved.payload.drawings.map(\.id)).count == saved.payload.drawings.count)
        #expect(controller.window?.isDocumentEdited == true)
        let committedDiagnostics = controller.mediaLoadSessionDiagnostics
        let rendered = ui.canvas.annotationsBinding?() ?? []
        // Same bytes with a new inode invalidate the stored target binding.
        let replacement = f.appendingPathComponent("replacement.mov")
        try original.write(to: replacement)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.moveItem(at: replacement, to: source)
        result = nil
        try controller.importVideoProjectItems(p) { result = $0 }
        try await wait { result != nil }
        let rejected = try #require(result)
        guard case .failure = rejected else { Issue.record("replaced source import committed items"); return }
        #expect(controller.mediaLoadSessionDiagnostics == committedDiagnostics)
        let finalRendered = ui.canvas.annotationsBinding?() ?? []; #expect(finalRendered == rendered)
        let sourceAfter = try Data(contentsOf: source), authoredAfter = try Data(contentsOf: authored)
        #expect(sourceAfter == original); #expect(authoredAfter == original)
        #expect(controller.window?.isDocumentEdited == true)
    }
}
