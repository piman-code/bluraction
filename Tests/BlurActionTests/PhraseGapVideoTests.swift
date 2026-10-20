import AppKit
import AVFoundation
import CoreImage
import CryptoKit
import Foundation
import Testing
@testable import BlurAction

/// Phrases that vanish and come back on a generated video. Set BLURACTION_PHRASE_GAP_QA to keep
/// reports in a chosen folder; BLURACTION_PHRASE_GAP_INPUT / _PHRASES optionally check another video.
@Suite(.serialized)
struct PhraseGapVideoTests {
    static let gapStart = 3.5, gapEnd = 5.5

    /// 10 s: "학부모 안내문" moves, disappears for 2 s and returns elsewhere; "얼굴 가림 확인" stays.
    static func gapVideo() throws -> URL {
        try SyntheticPhraseVideo.make(in: VideoExportTests().directory(), name: "synthetic-phrase-gap-10s", duration: 10, captions: [
            .init(text: "학부모 안내문", start: 0, end: gapStart, x: "120+t*15", y: "160"),
            .init(text: "학부모 안내문", start: gapEnd, end: 10, x: "600-(t-\(gapEnd))*20", y: "430"),
            .init(text: "얼굴 가림 확인", start: 0, end: 10, x: "760", y: "260"),
        ])
    }
    static func input() throws -> URL {
        try ProcessInfo.processInfo.environment["BLURACTION_PHRASE_GAP_INPUT"].map(URL.init(fileURLWithPath:)) ?? gapVideo()
    }
    static var phrases: [String] {
        (ProcessInfo.processInfo.environment["BLURACTION_PHRASE_GAP_PHRASES"] ?? "학부모,안내문,얼굴").split(separator: ",").map(String.init)
    }
    static var generated: Bool { ProcessInfo.processInfo.environment["BLURACTION_PHRASE_GAP_INPUT"] == nil }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BLURACTION_PHRASE_GAP_BIRTH_DIAGNOSTIC"] != nil))
    func birthSnapshotsExposeMatchedPhraseIdentityWithoutTextDump() async throws {
        let qa = try SyntheticPhraseVideo.qaDirectory("BLURACTION_PHRASE_GAP_QA")
        let input = try Self.input()
        let before = try PageWorkspace.digest(of: input)
        let generator = AVAssetImageGenerator(asset: VideoAssetPolicy.asset(url: input)); generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        var snapshots: [[String: Any]] = []
        for time in [0.0, 0.125, 0.25, Self.gapEnd, Self.gapEnd + 0.125, Self.gapEnd + 0.25, 9.0, 9.125, 9.25] {
            let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 60_000))
            let lines = try AutoDetector.recognizedLines(in: CIImage(cgImage: frame.image))
            let observations = lines.compactMap { line -> [String: Any]? in
                let matches = ["안내문", "학부모"].filter { PhraseCover.matches(line.text, phrases: [$0]) }
                guard !matches.isEmpty else { return nil }
                let hash = SHA256.hash(data: Data(PhraseCover.normalize(line.text).utf8)).map { String(format: "%02x", $0) }.joined()
                return ["matchedPhrases": matches, "normalizedLineHash": hash, "box": [line.box.minX,line.box.minY,line.box.width,line.box.height]]
            }
            snapshots.append(["requestedTime":time,"actualTime":frame.actualTime.seconds,"observations":observations])
        }
        try JSONSerialization.data(withJSONObject: ["inputSHA256":before,"snapshots":snapshots], options:[.prettyPrinted,.sortedKeys]).write(to:qa.appendingPathComponent("birth-identity-diagnostic.json"))
        #expect(try PageWorkspace.digest(of:input) == before)
    }
    @Test
    @MainActor
    func nativeApplySaveReopenAndDecodedCoverage() async throws {
        let qa = try SyntheticPhraseVideo.qaDirectory("BLURACTION_PHRASE_GAP_QA")
        let input = try Self.input()
        let phrases = Self.phrases
        let before = try PageWorkspace.digest(of: input)
        let duration = try await VideoAssetPolicy.asset(url: input).load(.duration).seconds
        let reuseOutput = ProcessInfo.processInfo.environment["BLURACTION_PHRASE_GAP_REUSE_OUTPUT"]
        let trackingStarted = ProcessInfo.processInfo.systemUptime
        let result: PhraseTracker.Outcome? = reuseOutput == nil ? try await PhraseTracker.track(url: input, duration: duration, phrases: phrases, cancellation: .init(), progress: { _ in }) : nil
        let trackingSeconds = ProcessInfo.processInfo.systemUptime - trackingStarted
        let directory = try VideoExportTests().directory()
        let s = VideoSession(directory: directory)
        defer { s.container.playerLayer.player?.pause(); s.controller.close() }
        s.controller.showWindow(nil); s.controller.load(url: input)
        try await waitUntil { s.canvas.isEditable }
        if let result { try s.controller.applyPhraseTracking(result) }
        let projectURL = qa.appendingPathComponent(ProcessInfo.processInfo.environment["BLURACTION_PHRASE_GAP_PROJECT"] ?? "face-phrase.bluraction")
        if reuseOutput == nil {
            let data = try s.controller.projectData(projectURL: projectURL, producerVersion: "phrase-gap-verification")
            try data.write(to: projectURL)
        }
        let saved = try VideoProjectFile.decode(Data(contentsOf: projectURL))
        s.controller.openVideoProject(saved, media: input)
        try await waitUntil { s.canvas.isEditable }
        let reopened = try VideoProjectFile.decode(s.controller.projectData(projectURL: projectURL, producerVersion: "phrase-gap-verification"))
        #expect(reopened.payload.regions.count == saved.payload.regions.count)
        #expect(reopened.payload.regions.map(\.effect) == saved.payload.regions.map(\.effect))
        let canvasSize = s.canvas.bounds.size
        var pairs = RegionEditing.scaled(saved.payload.regions.map { ($0.shape, $0.effect) }, from: CGSize(width: 1, height: 1), to: canvasSize)
        var defaultOutput: URL?
        if reuseOutput == nil && ProcessInfo.processInfo.environment["BLURACTION_PHRASE_GAP_DEFAULT_EXPORT"] == "1" {
            let exporter = BlurredVideoExporter()
            await exporter.export(input: input, pairs: pairs, quality: .original, canvasBounds: canvasSize, expectedSourceSHA256: before)
            let published = try #require(exporter.lastOutputURL, Comment(rawValue: exporter.statusText))
            let copy = qa.appendingPathComponent("default-export-" + UUID().uuidString + "." + published.pathExtension)
            try FileManager.default.copyItem(at: published, to: copy)
            defaultOutput = copy
        }
        for i in pairs.indices { pairs[i].effect.style = .solid; pairs[i].effect.color = .black; pairs[i].effect.featherRadius = 0 }
        let output: URL
        if let reuseOutput { output = URL(fileURLWithPath: reuseOutput) }
        else {
            let exporter = BlurredVideoExporter()
            await exporter.export(input: input, pairs: pairs, quality: .original, canvasBounds: canvasSize, expectedSourceSHA256: before)
            let temporaryOutput = try #require(exporter.lastOutputURL, Comment(rawValue: exporter.statusText))
            output = qa.appendingPathComponent("export-" + UUID().uuidString + "." + temporaryOutput.pathExtension)
            try FileManager.default.copyItem(at: temporaryOutput, to: output)
        }
        let gen = AVAssetImageGenerator(asset: VideoAssetPolicy.asset(url: output)); gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        let sourceGen = AVAssetImageGenerator(asset: VideoAssetPolicy.asset(url: input)); sourceGen.appliesPreferredTrackTransform = true
        sourceGen.requestedTimeToleranceBefore = .zero; sourceGen.requestedTimeToleranceAfter = .zero
        let context = CIContext()
        var checked = 0, geometryMisses = 0, pixelMisses = 0, unknownCharacterGeometry = 0
        var rows: [[String: Any]] = []
        let regular = stride(from: 0.0, to: duration, by: 0.5).map { $0 }
        let offGrid = stride(from: 0.125, to: duration, by: 0.5).map { $0 }
        let fastValues = ProcessInfo.processInfo.environment["BLURACTION_PHRASE_GAP_FAST_CHECK_TIMES"]
        let times: [Double]
        if let fastValues {
            times = try fastValues.split(separator: ",").map { try #require(Double($0)) }
            try #require(!times.isEmpty && times.allSatisfy { $0.isFinite && $0 >= 0 && $0 < duration })
        } else { times = (regular + offGrid).sorted() }
        for time in times {
            let sourceFrame = try await sourceGen.image(at: CMTime(seconds: time, preferredTimescale: 60_000))
            let source = CIImage(cgImage: sourceFrame.image)
            var targets: [CGPoint] = []
            for line in try AutoDetector.recognizedLines(in: source) {
                for phrase in phrases where PhraseCover.matches(line.text, phrases: [phrase]) {
                    var oracle = line
                    // The oracle uses real character quads even when confidence is too weak
                    // to enable fitting. A whole-line center is not the typed word center.
                    oracle.confidence = 1
                    if oracle.quad == nil && !oracle.fragments.isEmpty { oracle.quad = [CGPoint(x: line.box.minX, y: line.box.minY), CGPoint(x: line.box.maxX, y: line.box.minY), CGPoint(x: line.box.maxX, y: line.box.maxY), CGPoint(x: line.box.minX, y: line.box.maxY)] }
                    let points = AutoDetector.phraseEvidence(line: oracle, phrases: [phrase])
                    if let points, !points.isEmpty {
                        for offset in stride(from: 0, to: points.count - 3, by: 4) {
                            let quad = Array(points[offset..<offset+4])
                            let center = CGPoint(x: quad.map(\.x).reduce(0,+) / 4, y: quad.map(\.y).reduce(0,+) / 4)
                            targets.append(center)
                            targets += quad.map { CGPoint(x: center.x + ($0.x - center.x) * 0.75, y: center.y + ($0.y - center.y) * 0.75) }
                        }
                    } else { unknownCharacterGeometry += 1 }
                }
            }
            guard !targets.isEmpty else { continue }
            let frame = try await gen.image(at: CMTime(seconds: time, preferredTimescale: 60_000))
            let rendered = CIImage(cgImage: frame.image)
            if time == 6 {
                try context.writePNGRepresentation(of: rendered, to: qa.appendingPathComponent("export-frame-" + UUID().uuidString + ".png"), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            }
            let displayed = pairs.filter { $0.effect.isActive(at: frame.actualTime.seconds) }.map { $0.effect.shape($0.shape, at: frame.actualTime.seconds) }
            for p in targets {
                let canvasPoint = CGPoint(x: p.x * canvasSize.width, y: p.y * canvasSize.height)
                let covering = displayed.filter { $0.contains(point: canvasPoint, threshold: 0.001) }
                if covering.isEmpty { geometryMisses += 1 }
                var rgba = [UInt8](repeating: 255, count: 4)
                context.render(rendered, toBitmap: &rgba, rowBytes: 4, bounds: CGRect(x: (p.x * rendered.extent.width).rounded(), y: (p.y * rendered.extent.height).rounded(), width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
                let black = rgba[0] < 30 && rgba[1] < 30 && rgba[2] < 30
                if !black { pixelMisses += 1 }
                checked += 1
                rows.append(["requestedTime": time, "actualSourceTime": sourceFrame.actualTime.seconds, "actualOutputTime": frame.actualTime.seconds, "target": [p.x,p.y], "covered": !covering.isEmpty, "pixelBlack": black])
            }
        }
        #expect(checked > 20)
        #expect(try PageWorkspace.digest(of: input) == before)
        let root = SyntheticPhraseVideo.repositoryRoot
        let sourceFolder = root.appendingPathComponent("Sources/BlurAction")
        var implementationHashes: [String: String] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: sourceFolder, includingPropertiesForKeys: nil) where file.pathExtension == "swift" { implementationHashes[file.lastPathComponent] = try PageWorkspace.digest(of: file) }
        let testSHA = try PageWorkspace.digest(of: root.appendingPathComponent("Tests/BlurActionTests/PhraseGapVideoTests.swift"))
        var report: [String: Any] = ["implementationSHA256s": implementationHashes, "testSourceSHA256": testSHA, "sourceSHA256": before, "outputSHA256": try PageWorkspace.digest(of: output), "projectSHA256": try PageWorkspace.digest(of: projectURL), "input": input.path, "generatedInput": Self.generated, "output": output.path, "project": projectURL.path, "phrases": phrases, "tracks": result?.tracks.count ?? saved.payload.regions.count, "requestedCheckTimes": times, "fastCheck": fastValues != nil, "checks": checked, "unknownCharacterGeometry": unknownCharacterGeometry, "geometryMisses": geometryMisses, "pixelMisses": pixelMisses, "reviews": result?.reviews.count ?? saved.payload.regions.reduce(0) { $0 + $1.effect.trackingReviews.count }, "rows": rows, "oracle": "actual matching character quad centers and four inset corners at .5sec and independent .125+.5sec off-grid samples; unreadable or missing character-geometry observations excluded"]
        report["trackSeconds"] = reuseOutput == nil ? trackingSeconds : NSNull()
        if let defaultOutput { report["defaultOutput"] = defaultOutput.path; report["defaultOutputSHA256"] = try PageWorkspace.digest(of: defaultOutput) }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: qa.appendingPathComponent(ProcessInfo.processInfo.environment["BLURACTION_PHRASE_GAP_EXPORT_REPORT"] ?? "face-export.json"))
        #expect(geometryMisses == 0)
        #expect(pixelMisses == 0)
    }
    @Test
    func koreanPhraseContinuityAcrossGap() async throws {
        let qa = try SyntheticPhraseVideo.qaDirectory("BLURACTION_PHRASE_GAP_QA")
        let input = try Self.input()
        let phrases = Self.phrases
        let before = try PageWorkspace.digest(of: input)
        let asset = VideoAssetPolicy.asset(url: input)
        let duration = try await asset.load(.duration).seconds
        var reads: [[String: Any]] = []
        let result = try await PhraseTracker.track(url: input, duration: duration, phrases: phrases, cancellation: .init(), recognizeLines: { image in
            let lines = try AutoDetector.recognizedLines(in: image)
            // Only target-matching text is recorded; unrelated screen content stays local.
            reads.append(["requestIndex": reads.count, "matching": lines.filter { PhraseCover.matches($0.text, phrases: phrases) }.map { line in ["matchedPhrases": phrases.filter { PhraseCover.matches(line.text, phrases: [$0]) }, "box": [line.box.minX, line.box.minY, line.box.width, line.box.height]] }])
            return lines
        }, progress: { _ in })
        let tracks = result.tracks.map { t -> [String: Any] in
            ["phrase": t.phrase, "start": t.start, "end": t.end, "sampleTimes": t.samples.map(\.time), "boxes": t.samples.map { [$0.box.minX, $0.box.minY, $0.box.width, $0.box.height] }, "evidenceTimes": t.coverEvidence.map(\.time)]
        }
        let cuts = try await PhraseTracker.sceneCuts(url: input, from: 0, until: duration, cancellation: .init())
        let report: [String: Any] = ["duration": duration, "sourceSHA256": before, "reads": reads, "tracks": tracks, "cuts": cuts, "reviews": result.reviews.map { ["start": $0.start, "end": $0.end, "reason": $0.reason.rawValue] }, "cancelled": result.cancelled]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: qa.appendingPathComponent(ProcessInfo.processInfo.environment["BLURACTION_PHRASE_GAP_REPORT"] ?? "diagnostic.json"))
        #expect(!result.cancelled)
        #expect(try PageWorkspace.digest(of: input) == before)
        let context = CIContext()
        for time in [0.0, min(3, duration - 0.1), min(5, duration - 0.1), min(7, duration - 0.1), min(9, duration - 0.1)] {
            let frame = try await AutoDetector.frame(of: input, at: time)
            try context.writePNGRepresentation(of: frame, to: qa.appendingPathComponent("original-\(Int(time)).png"), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        guard Self.generated else { return }
        let middle = (Self.gapStart + Self.gapEnd) / 2
        for phrase in ["학부모", "안내문"] {
            // A line holding several phrases is one track labelled e.g. "안내문, 학부모".
            let found = result.tracks.filter { $0.phrase.contains(phrase) }
            #expect(found.contains { $0.start < 0.5 }, "\(phrase) is tracked before the gap")
            #expect(found.contains { $0.start > Self.gapStart && $0.start < Self.gapEnd + 0.5 }, "\(phrase) is tracked again after the gap")
            #expect(!found.contains { $0.start < middle && $0.end > middle }, "\(phrase) is not bridged across the gap")
        }
        #expect(result.tracks.contains { $0.phrase == "얼굴" && $0.start < middle && $0.end > middle }, "Steady 얼굴 stays tracked")
    }
}
