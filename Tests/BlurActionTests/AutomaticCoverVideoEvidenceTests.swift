import AppKit
import AVFoundation
import CoreImage
import CoreText
import Foundation
import Testing
@testable import BlurAction

@Suite(.serialized)
@MainActor
struct AutomaticCoverVideoEvidenceTests {
    @Test func rotatingPartialPhraseUsesRealOCRNativeControlsAndDecodedOutput() async throws {
        let directory = try VideoExportTests().directory()
        let patch = directory.appendingPathComponent("phrase.png")
        let ctx = try #require(CGContext(data: nil, width: 540, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 540, height: 80))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "CLASS BLUR1234 END", attributes: [
            .font: NSFont.systemFont(ofSize: 40, weight: .bold), .foregroundColor: NSColor.black]))
        ctx.textPosition = CGPoint(x: 12, y: 20); CTLineDraw(line, ctx)
        let image = try #require(ctx.makeImage())
        try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: patch)
        let input = directory.appendingPathComponent("partial-phrase.mp4")
        try VideoExportTests().ffmpeg(["-f", "lavfi", "-i", "color=c=0x303030:s=720x300:d=2:r=12", "-loop", "1", "-i", patch.path,
            "-filter_complex", "[1]rotate=0.12:ow=rotw(0.12):oh=roth(0.12):c=0x303030[p];[0][p]overlay=x='25+t*30':y=65:shortest=1",
            "-t", "2", "-c:v", "libx264", "-pix_fmt", "yuv420p", input.path])
        let before = try PageWorkspace.digest(of: input)
        let result = try await PhraseTracker.track(url: input, duration: 2, phrases: ["blur1234"], cancellation: .init(), progress: { _ in })
        #expect(!result.cancelled)
        let tracked = try #require(result.tracks.first)
        #expect(tracked.coverEvidence.count > 10, "Real per-frame character geometry must be available")
        let first = try #require(tracked.coverEvidence.first)
        let xs = first.points.map(\.x)
        #expect(xs.max()! - xs.min()! < first.generousBox.width * 0.8, "Cover the selected word, rather than CLASS and END")
        let s = VideoSession(directory: directory)
        defer { s.container.playerLayer.player?.pause(); s.controller.close() }
        s.controller.showWindow(nil); s.controller.load(url: input)
        try await waitUntil { s.canvas.isEditable }
        try s.controller.applyPhraseTracking(result)
        let project = try VideoProjectFile.decode(s.controller.projectData(producerVersion: "partial-phrase-test"))
        let size = s.canvas.bounds.size
        let pairs = RegionEditing.scaled(project.payload.regions.map { ($0.shape, $0.effect) }, from: CGSize(width: 1, height: 1), to: size)
        let pair = try #require(pairs.first)
        #expect(pair.effect.automaticCover?.phrases == ["blur1234"])
        let shape = pair.effect.shape(pair.shape, at: first.time)
        guard case .polygon(_, let vertices) = shape else { Issue.record("A stable rotated word should have a polygon cover"); return }
        #expect(zip(vertices, vertices.dropFirst()).contains { abs($0.x - $1.x) > 1 && abs($0.y - $1.y) > 1 },
                "Actual observed lettering tilt must survive to the native mask")
        var solid = pairs
        for i in solid.indices { solid[i].effect.style = .solid; solid[i].effect.color = .black; solid[i].effect.featherRadius = 0 }
        let exporter = BlurredVideoExporter()
        await exporter.export(input: input, pairs: solid, quality: .original, canvasBounds: size, expectedSourceSHA256: before)
        let output = try #require(exporter.lastOutputURL, Comment(rawValue: exporter.statusText))
        let generator = AVAssetImageGenerator(asset: VideoAssetPolicy.asset(url: output))
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let context = CIContext()
        var checked = 0
        for anchor in tracked.coverEvidence {
            let frame = try await generator.image(at: CMTime(seconds: anchor.time, preferredTimescale: 60_000)).image
            let center = anchor.points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            let point = CGPoint(x: center.x / CGFloat(anchor.points.count) * 720, y: center.y / CGFloat(anchor.points.count) * 300)
            var rgba = [UInt8](repeating: 255, count: 4)
            context.render(CIImage(cgImage: frame), toBitmap: &rgba, rowBytes: 4,
                bounds: CGRect(x: point.x.rounded(), y: point.y.rounded(), width: 1, height: 1),
                format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            #expect(rgba[0] < 25 && rgba[1] < 25 && rgba[2] < 25)
            for p in anchor.points {
                let displayed = pair.effect.shape(pair.shape, at: anchor.time)
                #expect(displayed.contains(point: CGPoint(x: p.x * size.width, y: p.y * size.height), threshold: 0.0001))
            }
            checked += 1
        }
        #expect(checked > 10)
        #expect(try PageWorkspace.digest(of: input) == before)
        let qa = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BLURACTION_MASK_FIT_QA"] ?? directory.path)
        let report: [String: Any] = ["input": input.path, "output": output.path, "inputSHA256": before,
            "realOCRAnchors": tracked.coverEvidence.count, "decodedPixelChecks": checked,
            "partialWordWidthRatio": (xs.max()! - xs.min()!) / first.generousBox.width,
            "orientedPolygon": true, "originalUnchanged": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: qa.appendingPathComponent("partial-phrase-video.json"))
    }
}
