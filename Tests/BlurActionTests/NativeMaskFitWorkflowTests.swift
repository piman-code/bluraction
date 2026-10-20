import AppKit
import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import BlurAction

@Suite(.serialized)
@MainActor
struct NativeMaskFitWorkflowTests {
    private func close(_ s: EditorSession) { s.container.playerLayer.player?.pause(); s.controller.close() }
    private func detection() -> AutoDetector.Detection {
        .init(generousBox: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.4), target: .text,
              evidencePoints: [CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.55, y: 0.4),
                               CGPoint(x: 0.52, y: 0.5), CGPoint(x: 0.27, y: 0.4)], reliable: true)
    }
    @Test func selectedControlsRestoreExactGenerousGeometryAndPersistUndoLockAndResize() async throws {
        let s = try await ImageSession.open(); defer { close(s) }
        let source = s.directory.appendingPathComponent("tools.png"), before = try Data(contentsOf: source)
        let d = detection()
        s.controller.autoDetectDetailed = { _, _ in [d] }
        var finished = false; s.controller.findAndCover(.text) { finished = true }
        try await waitUntil { finished }
        let shown = try #require(s.canvas.regionsBinding?().first)
        guard case .polygon = shown else { Issue.record("Reliable rotated text should be a polygon"); return }
        let saved = try ProjectFile.decode(s.controller.projectData())
        let base = try #require(saved.regions.first)
        #expect(base.effect.automaticCover != nil)
        let restore = try #require(s.descendants.compactMap { $0 as? NSButton }.first { $0.title == "넉넉하게 가리기" })
        #expect(!restore.isHiddenOrHasHiddenAncestor && restore.isEnabled)
        click(restore)
        let generous = try #require(s.canvas.regionsBinding?().first)
        #expect(abs(generous.boundingRect.width / s.canvas.bounds.width - d.generousBox.width) < 0.0001)
        guard case .rectangle = generous else { Issue.record("Restoration must be the original rectangle"); return }
        s.controller.perform(NSSelectorFromString("undoTapped"))
        #expect(s.canvas.regionsBinding?().first == shown)
        #expect(s.controller.setAutomaticCover(shown.id, margin: 16))
        let wide = try #require(s.canvas.regionsBinding?().first)
        #expect(wide.boundingRect.width > shown.boundingRect.width)
        s.controller.setLayerLocked(shown.id, true)
        #expect(!s.controller.setAutomaticCover(shown.id, mode: .generous))
        s.controller.setLayerLocked(shown.id, false)
        let project = try ProjectFile.decode(s.controller.projectData())
        #expect(project.regions.first?.effect.automaticCover?.safetyMargin == 16)
        let normalized = wide.boundingRect.width / s.canvas.bounds.width
        s.controller.window?.setContentSize(CGSize(width: 1180, height: 800))
        s.controller.window?.contentView?.layoutSubtreeIfNeeded()
        #expect(abs((s.canvas.regionsBinding?().first?.boundingRect.width ?? 0) / s.canvas.bounds.width - normalized) < 0.001)
        #expect(try Data(contentsOf: source) == before)
    }

    @Test func uncertainVideoKeepsWideMaskAndRecommendationDoesNotResolveReviews() async throws {
        let s = try await VideoSession.open(); defer { close(s) }
        let box = CGRect(x: 0.2, y: 0.3, width: 0.5, height: 0.3)
        let points = [CGPoint(x: 0.3, y: 0.4), CGPoint(x: 0.5, y: 0.4), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.3, y: 0.5)]
        let samples = (0...24).map { ObjectTracker.Sample(time: Double($0) / 4, box: box) }
        let anchors = samples.filter { $0.time < 2 || $0.time > 3 }.map {
            PhraseTracker.CoverEvidence(time: $0.time, points: points, generousBox: box)
        }
        let track = PhraseTracker.Track(phrase: "학생", samples: samples, start: 0, end: 6, coverEvidence: anchors)
        try s.controller.applyPhraseTracking(.init(tracks: [track], reviews: [], cancelled: false, recognitionStep: 1))
        let shape = try #require(s.canvas.regionsBinding?().first)
        let effect = try #require(s.canvas.effectForID?(shape.id))
        #expect(!effect.trackingReviews.isEmpty)
        let data = try VideoProjectFile.decode(s.controller.projectData(producerVersion: "mask-fit-test"))
        let base = try #require(data.payload.regions.first)
        let wide = base.effect.shape(base.shape, at: 2.5)
        #expect(wide.boundingRect.contains(base.shape.boundingRect))
        _ = s.controller.setAutomaticCover(shape.id, margin: 8, mode: .recommended)
        #expect(s.canvas.effectForID?(shape.id)?.trackingReviews == effect.trackingReviews)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BLURACTION_MASK_FIT_REAL_VIDEO"] != nil))
    func localRealVideoFaceRefinementNativeExportAndAllFrameCoverage() async throws {
        let original = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["BLURACTION_MASK_FIT_REAL_VIDEO"]))
        let sha = try PageWorkspace.digest(of: original)
        let directory = try VideoExportTests().directory()
        let input = directory.appendingPathComponent("mask-fit-real.mp4")
        try FileManager.default.copyItem(at: original, to: input)
        let asset = VideoAssetPolicy.asset(url: input)
        let duration = try await asset.load(.duration).seconds
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        let initial = try await AutoDetector.frame(of: input, at: 0)
        let found = try AutoDetector.detectDetailed(.faces, in: initial)
        #expect(found.count >= 3)
        #expect(found.contains { $0.reliable })
        let cancellation = ObjectTracker.Cancellation()
        let tracked = try await ObjectTracker.trackMany(url: input, from: 0, until: duration,
            boxes: found.map(\.generousBox), cancellation: cancellation, progress: { _ in })
        let samples = zip(found, tracked).map { d, t in [ObjectTracker.Sample(time: 0, box: d.generousBox)] + t.samples }
        let anchors = try await AutoDetector.refineTracks(url: input, target: .faces, tracks: samples, cancellation: cancellation)
        let session = VideoSession(directory: directory)
        defer { close(session) }
        session.controller.showWindow(nil); session.controller.load(url: input)
        try await waitUntil { session.canvas.isEditable }
        var pairs: [RegionEditing.Pair] = []
        var smaller = 0, checked = 0
        let scale = session.canvas.bounds.size
        for (index, detection) in found.enumerated() {
            let b = detection.generousBox
            let base = RegionShape.ellipse(id: UUID(), origin: CGPoint(x: b.minX * scale.width, y: b.minY * scale.height),
                size: CGSize(width: b.width * scale.width, height: b.height * scale.height))
            var effect = RegionEffect.alwaysOn(); effect.style = .solid; effect.color = .black; effect.featherRadius = 0
            effect.keyframes = samples[index].map { .init(time: $0.time, rect: CGRect(x: $0.box.minX * scale.width,
                y: $0.box.minY * scale.height, width: $0.box.width * scale.width, height: $0.box.height * scale.height)) }
            if let first = anchors[index].first {
                effect.automaticCover = AutomaticCover(kind: .face,
                    evidencePoints: first.points.map { CGPoint(x: ($0.x-b.minX)/b.width, y: ($0.y-b.minY)/b.height) },
                    sourceSize: size, baseNormalizedSize: b.size,
                    evidenceKeyframes: anchors[index].map { a in .init(time: a.time, points: a.points.map {
                        CGPoint(x: ($0.x-a.generousBox.minX)/a.generousBox.width, y: ($0.y-a.generousBox.minY)/a.generousBox.height)
                    }) })
                #expect(effect.automaticCover?.isValid == true)
                let observed = Set(anchors[index].map(\.time))
                for (a, b) in zip(samples[index], samples[index].dropFirst()) where !observed.contains(a.time) || !observed.contains(b.time) {
                    effect.trackingReviews.append(.init(start: a.time, end: b.time, reason: .recognitionGap))
                }
                for anchor in anchors[index] {
                    let shown = effect.shape(base, at: anchor.time)
                    for point in anchor.points {
                        #expect(shown.contains(point: CGPoint(x: point.x * scale.width, y: point.y * scale.height), threshold: 0.0001))
                        checked += 1
                    }
                    let generous = MotionTrack.rect(at: anchor.time, base: base.boundingRect, keyframes: effect.keyframes)
                    if shown.boundingRect.width * shown.boundingRect.height < generous.width * generous.height { smaller += 1 }
                }
            }
            pairs.append((base, effect))
        }
        #expect(checked > 100 && smaller > 0)
        let exporter = BlurredVideoExporter()
        await exporter.export(input: input, pairs: pairs, quality: .original, canvasBounds: scale, expectedSourceSHA256: sha)
        let output = try #require(exporter.lastOutputURL, Comment(rawValue: exporter.statusText))
        let generator = AVAssetImageGenerator(asset: VideoAssetPolicy.asset(url: output))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime.zero; generator.requestedTimeToleranceAfter = CMTime.zero
        let context = CIContext()
        var pixelChecks = 0
        for (index, list) in anchors.enumerated() {
            for a in list {
                let frame = try await generator.image(at: CMTime(seconds: a.time, preferredTimescale: 60_000)).image
                let image = CIImage(cgImage: frame)
                // An interior point avoids compression/feather edges while still proving the decoded output covers the face.
                let p = a.points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
                let center = CGPoint(x: p.x / CGFloat(a.points.count) * size.width,
                                     y: p.y / CGFloat(a.points.count) * size.height)
                var rgba = [UInt8](repeating: 255, count: 4)
                context.render(image, toBitmap: &rgba, rowBytes: 4, bounds: CGRect(x: center.x.rounded(), y: center.y.rounded(), width: 1, height: 1),
                               format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
                #expect(rgba[0] < 25 && rgba[1] < 25 && rgba[2] < 25, "Decoded output face \(index) at \(a.time)")
                pixelChecks += 1
            }
        }
        #expect(pixelChecks > 20)
        #expect(try PageWorkspace.digest(of: original) == sha)
        #expect(try PageWorkspace.digest(of: input) == sha)
        let report: [String: Any] = ["inputSHA256": sha, "faces": found.count, "geometryPointChecks": checked,
            "smallerObservations": smaller, "decodedOutputPixelChecks": pixelChecks, "output": output.path,
            "originalUnchanged": true, "directory": directory.path]
        let reportURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BLURACTION_MASK_FIT_QA"] ?? directory.path)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL.appendingPathComponent("real-video.json"))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BLURACTION_MASK_FIT_REAL_VIDEO"] != nil))
    func realVideoNativeFinderProjectAndGenerousRestore() async throws {
        let original = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["BLURACTION_MASK_FIT_REAL_VIDEO"]))
        let before = try PageWorkspace.digest(of: original)
        let directory = try VideoExportTests().directory()
        let input = directory.appendingPathComponent("finder-real.mp4")
        try FileManager.default.copyItem(at: original, to: input)
        let s = VideoSession(directory: directory); defer { close(s) }
        s.controller.showWindow(nil); s.controller.load(url: input)
        try await waitUntil { s.canvas.isEditable }
        var done = false
        s.controller.findAndCover(.faces) { done = true }
        for _ in 0..<60_000 where !done || s.controller.isTracking { try await Task.sleep(nanoseconds: 10_000_000) }
        try #require(done && !s.controller.isTracking, "The actual finder and framewise refinement must finish")
        let qa = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["BLURACTION_MASK_FIT_QA"]))
        let projectURL = qa.appendingPathComponent("real-video-fitted.bluraction")
        let data = try s.controller.projectData(projectURL: projectURL, producerVersion: "mask-fit-test")
        let project = try VideoProjectFile.decode(data)
        #expect(project.payload.regions.count >= 3)
        let fitted = project.payload.regions.filter { $0.effect.automaticCover?.evidenceKeyframes.isEmpty == false }
        #expect(!fitted.isEmpty)
        try data.write(to: projectURL)
        let region = try #require(fitted.first)
        s.canvas.selectRegion(id: region.shape.id)
        let button = try #require(s.descendants.compactMap { $0 as? NSButton }.first { $0.title == "넉넉하게 가리기" })
        #expect(button.isEnabled && !button.isHiddenOrHasHiddenAncestor)
        click(button)
        #expect(s.canvas.effectForID?(region.shape.id)?.automaticCover?.mode == .generous)
        let shown = try #require(s.canvas.regionsBinding?().first { $0.id == region.shape.id })
        let scale = s.canvas.bounds.size
        #expect(abs(shown.boundingRect.width / scale.width - region.shape.boundingRect.width) < 0.001)
        s.controller.perform(NSSelectorFromString("undoTapped"))
        #expect(s.canvas.effectForID?(region.shape.id)?.automaticCover?.mode == region.effect.automaticCover?.mode)
        let view = try #require(s.window.contentView)
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: qa.appendingPathComponent("native-controls.png"))
        }
        let report: [String: Any] = ["regions": project.payload.regions.count, "fittedRegions": fitted.count,
            "evidenceFrames": fitted.reduce(0) { $0 + ($1.effect.automaticCover?.evidenceKeyframes.count ?? 0) },
            "pendingReviews": s.controller.pendingTrackingReviews.count, "restoreAndUndo": true,
            "project": projectURL.path, "input": input.path, "originalSHA256": before]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: qa.appendingPathComponent("real-native-finder.json"))
        #expect(try PageWorkspace.digest(of: original) == before)
    }

    /// Sends the button's action directly. `performClick` spins a nested
    /// event loop that can end an async test run early. Toggle-style
    /// buttons (checkbox, disclosure, on/off) change state first, as a click would.
    private func click(_ button: NSButton) {
        guard button.isEnabled, let action = button.action else { return }
        if let cell = button.cell as? NSButtonCell, !cell.showsStateBy.isEmpty { button.setNextState() }
        NSApp.sendAction(action, to: button.target, from: button)
    }
}
