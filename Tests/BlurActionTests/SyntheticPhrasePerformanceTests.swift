import AppKit
import AVFoundation
import CoreImage
import CoreText
import Foundation
import Testing
@testable import BlurAction

/// Synthetic Korean on-screen phrases rendered with CoreText and composited by ffmpeg.
/// Only generated text on a flat background is used: no faces, user or student media.
enum SyntheticPhraseVideo {
    struct Caption {
        var text: String
        var start: Double
        var end: Double
        /// ffmpeg overlay expressions in output pixels (top-left origin), so captions can move.
        var x: String
        var y: String
    }

    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Opt-in QA folder from `variable`, otherwise a fresh temporary folder.
    static func qaDirectory(_ variable: String) throws -> URL {
        if let path = ProcessInfo.processInfo.environment[variable] {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        return try VideoExportTests().directory()
    }

    static func patch(_ text: String, to url: URL) throws {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 44, weight: .bold), .foregroundColor: NSColor.black]))
        let width = Int(CTLineGetTypographicBounds(line, nil, nil, nil).rounded(.up)) + 32
        let context = try #require(CGContext(data: nil, width: width, height: 72, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: width, height: 72))
        context.textPosition = CGPoint(x: 16, y: 20); CTLineDraw(line, context)
        let image = try #require(context.makeImage())
        try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: url)
    }

    static func make(in directory: URL, name: String, duration: Double, width: Int = 1280, height: Int = 720,
                     captions: [Caption]) throws -> URL {
        var inputs = ["-f", "lavfi", "-i", "color=c=0x30343a:s=\(width)x\(height):d=\(duration):r=30"]
        var graph: [String] = []
        var previous = "0:v"
        for (index, caption) in captions.enumerated() {
            let png = directory.appendingPathComponent("\(name)-caption-\(index).png")
            try patch(caption.text, to: png)
            inputs += ["-loop", "1", "-i", png.path]
            let label = "v\(index + 1)"
            graph.append("[\(previous)][\(index + 1):v]overlay=x='\(caption.x)':y='\(caption.y)':enable='between(t,\(caption.start),\(caption.end))'[\(label)]")
            previous = label
        }
        let video = directory.appendingPathComponent(name + ".mp4")
        try VideoExportTests().ffmpeg(inputs + ["-filter_complex", graph.joined(separator: ";"), "-map", "[\(previous)]",
            "-t", "\(duration)", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-movflags", "+faststart", video.path])
        try #require(FileManager.default.fileExists(atPath: video.path))
        return video
    }

    /// 24 s of three phrases that appear, move, vanish and return at different times.
    static func performanceVideo(in directory: URL) throws -> URL {
        try make(in: directory, name: "synthetic-phrases-24s", duration: 24, captions: [
            Caption(text: "학부모 안내문", start: 0, end: 9, x: "120+t*12", y: "140"),
            Caption(text: "학부모 안내문", start: 13, end: 24, x: "640-(t-13)*10", y: "420"),
            Caption(text: "얼굴 가림 확인", start: 2, end: 20, x: "700", y: "220+(t-2)*6"),
            Caption(text: "가정통신 안내문", start: 6, end: 17, x: "180", y: "560"),
        ])
    }
}

/// Production tracking, apply, save, reopen and export profile on a generated 24 s phrase video.
/// BLURACTION_SYNTHETIC_PERF_QA keeps the report in a chosen folder; BLURACTION_SYNTHETIC_PERF_INPUT
/// optionally profiles another video instead of the generated one.
@Suite(.serialized)
struct SyntheticPhrasePerformanceTests {
    @Test
    @MainActor
    func productionTrackingProfileApplySaveReopenExport() async throws {
        let env = ProcessInfo.processInfo.environment
        let qa = try SyntheticPhraseVideo.qaDirectory("BLURACTION_SYNTHETIC_PERF_QA")
        let label = env["BLURACTION_SYNTHETIC_PERF_LABEL"] ?? "baseline"
        try #require(!label.isEmpty && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        let input = try env["BLURACTION_SYNTHETIC_PERF_INPUT"].map(URL.init(fileURLWithPath:))
            ?? SyntheticPhraseVideo.performanceVideo(in: VideoExportTests().directory())
        let phrases = ["얼굴", "학부모", "안내문"]
        let before = try PageWorkspace.digest(of: input)
        let duration = try await VideoAssetPolicy.asset(url: input).load(.duration).seconds
        let root = SyntheticPhraseVideo.repositoryRoot
        var hashes: [String: String] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Sources/BlurAction"), includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
            hashes[file.lastPathComponent] = try PageWorkspace.digest(of: file)
        }
        let started = ProcessInfo.processInfo.systemUptime
        var ocrSeconds = 0.0, reads = 0
        var firstProgressOne: Double?
        var progressRows: [[String: Double]] = []
        let result = try await PhraseTracker.track(url: input, duration: duration, phrases: phrases, cancellation: .init(), recognizeLines: { image in
            let clock = ProcessInfo.processInfo.systemUptime
            let lines = try AutoDetector.recognizedLines(in: image)
            ocrSeconds += ProcessInfo.processInfo.systemUptime - clock
            reads += 1
            return lines
        }, progress: { value in
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            progressRows.append(["elapsedSeconds": elapsed, "progress": value])
            if value >= 1 && firstProgressOne == nil { firstProgressOne = elapsed }
        })
        let trackSeconds = ProcessInfo.processInfo.systemUptime - started
        let reportURL = qa.appendingPathComponent(label + "-profile.json")
        let projectURL = qa.appendingPathComponent(label + "-phrases.bluraction")
        var report: [String: Any] = [
            "stage": "tracking-complete", "input": input.path, "sourceSHA256": before,
            "generatedInput": env["BLURACTION_SYNTHETIC_PERF_INPUT"] == nil,
            "implementationSHA256s": hashes, "duration": duration, "phrases": phrases,
            "trackSeconds": trackSeconds, "mainAndBirthOCRCalls": reads,
            "mainAndBirthOCRSeconds": ocrSeconds,
            "coreProgressOneSeconds": firstProgressOne as Any? ?? NSNull(),
            "postCoreSeconds": firstProgressOne.map { max(0, trackSeconds - $0) } as Any? ?? NSNull(),
            "progress": progressRows, "cancelled": result.cancelled,
            "recognitionStep": result.recognitionStep, "trackCount": result.tracks.count,
            "reviewCount": result.reviews.count,
            "tracks": result.tracks.map { track -> [String: Any] in
                ["phrase": track.phrase, "start": track.start, "end": track.end,
                 "sampleTimes": track.samples.map(\.time),
                 "boxes": track.samples.map { [$0.box.minX, $0.box.minY, $0.box.width, $0.box.height] },
                 "evidenceTimes": track.coverEvidence.map(\.time)]
            },
            "measurementScope": "OCR wrapper measures main and birth reads only. Optional refinement OCR uses its own production reader; postCoreSeconds includes refinement and final source validation."
        ]
        func persist() throws {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
        }
        try persist()
        #expect(!result.cancelled)
        #expect(!result.tracks.isEmpty)
        #expect(reads >= 90)
        if env["BLURACTION_SYNTHETIC_PERF_INPUT"] == nil {
            // A line holding several phrases is one track labelled e.g. "안내문, 학부모".
            for phrase in phrases { #expect(result.tracks.contains { $0.phrase.contains(phrase) }, "\(phrase) is tracked") }
        }
        #expect(try PageWorkspace.digest(of: input) == before)

        let directory = try VideoExportTests().directory()
        let session = VideoSession(directory: directory)
        defer { session.container.playerLayer.player?.pause(); session.controller.close() }
        session.controller.showWindow(nil)
        session.controller.load(url: input)
        try await waitUntil { session.canvas.isEditable }
        try session.controller.applyPhraseTracking(result)
        try session.controller.projectData(projectURL: projectURL, producerVersion: "synthetic-performance-verification").write(to: projectURL)
        let saved = try VideoProjectFile.decode(Data(contentsOf: projectURL))
        session.controller.openVideoProject(saved, media: input)
        try await waitUntil { session.canvas.isEditable }
        let reopened = try VideoProjectFile.decode(session.controller.projectData(projectURL: projectURL, producerVersion: "synthetic-performance-verification"))
        #expect(reopened.payload.regions.count == saved.payload.regions.count)
        #expect(reopened.payload.regions.map(\.effect) == saved.payload.regions.map(\.effect))
        #expect(reopened.payload.regions.map(\.shape) == saved.payload.regions.map(\.shape))
        report["project"] = projectURL.path
        report["projectSHA256"] = try PageWorkspace.digest(of: projectURL)
        report["saveReopen"] = "pass"
        report["stage"] = "save-reopen-complete"
        try persist()
        // Export needs only the saved regions; closing the editor first keeps its player and
        // window from running alongside the long export.
        let canvasSize = session.canvas.bounds.size
        session.container.playerLayer.player?.pause(); session.controller.close()
        if env["BLURACTION_SYNTHETIC_PERF_SKIP_EXPORT"] != "1" {
            let originalPairs = RegionEditing.scaled(saved.payload.regions.map { ($0.shape, $0.effect) }, from: CGSize(width: 1, height: 1), to: canvasSize)
            var outputs: [[String: Any]] = []
            for mode in ["default", "solid"] {
                var pairs = originalPairs
                if mode == "solid" {
                    for index in pairs.indices { pairs[index].effect.style = .solid; pairs[index].effect.color = .black; pairs[index].effect.featherRadius = 0 }
                }
                let exportStarted = ProcessInfo.processInfo.systemUptime
                let exporter = BlurredVideoExporter()
                await exporter.export(input: input, pairs: pairs, quality: .original, canvasBounds: canvasSize, expectedSourceSHA256: before)
                let published = try #require(exporter.lastOutputURL, Comment(rawValue: exporter.statusText))
                let output = qa.appendingPathComponent(label + "-" + mode + "-" + UUID().uuidString + "." + published.pathExtension)
                try FileManager.default.copyItem(at: published, to: output)
                outputs.append(["mode": mode, "output": output.path, "published": published.path,
                                "sha256": try PageWorkspace.digest(of: output),
                                "seconds": ProcessInfo.processInfo.systemUptime - exportStarted])
                report["outputs"] = outputs
                try persist()
            }
        }
        #expect(try PageWorkspace.digest(of: input) == before)
        report["sourceUnchanged"] = true
        report["stage"] = "complete"
        try persist()
    }
}
