import AppKit
import AVFoundation
import CoreImage
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import BlurAction

@Suite(.serialized)
struct CoverDecorationTests {
    private func region(label: String? = nil) -> ProjectFile.Region {
        var effect = RegionEffect(blurRadius: 0, featherRadius: 0)
        effect.style = .solid
        effect.decoration = label.map { CoverDecoration(text: $0) }
        return .init(shape: .rectangle(id: UUID(), origin: .init(x: 0.1, y: 0.1),
                                     size: .init(width: 0.4, height: 0.5)), effect: effect)
    }

    @Test @MainActor
    func koreanAndCompositeEmojiKeepTheirAspectAndCenterWhenCoverResizes() throws {
        for text in ["학생 A", "🙂", "👨‍👩‍👧‍👦", "안내\n비공개"] {
            let label = CoverDecoration(text: text)
            let natural = DrawingAnnotation.text(text, at: .zero, fontSize: 100, color: .white).bounds
            for box in [CGRect(x: 10, y: 20, width: 240, height: 40), CGRect(x: 70, y: 60, width: 35, height: 150)] {
                let drawing = try #require(label.annotation(in: box))
                #expect(abs(drawing.bounds.midX - box.midX) < 0.001)
                #expect(abs(drawing.bounds.midY - box.midY) < 0.001)
                #expect(drawing.bounds.width <= box.width * 0.8 + 0.001)
                #expect(drawing.bounds.height <= box.height * 0.8 + 0.001)
                #expect(abs(drawing.bounds.width / drawing.bounds.height - natural.width / natural.height) < 0.001)
            }
        }
    }

    /// Count rendered bright label pixels in a known area, independent of glyph rasterization.
    private func brightCount(_ image: CIImage, box: CGRect) throws -> Int {
        let cg = try #require(CIContext().createCGImage(image.cropped(to: box), from: box))
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let ctx = try #require(CGContext(data: &bytes, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] > 100 || bytes[$0 + 1] > 100 || bytes[$0 + 2] > 100 }.count
    }

    @Test @MainActor
    func renderedLabelFollowsMotionAndVisibilityAtOutputResolution() throws {
        let image = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 160))
        let shape = RegionShape.rectangle(id: UUID(), origin: .init(x: 5, y: 10), size: .init(width: 60, height: 55))
        var effect = region(label: "🙂").effect
        effect.timeRange = 1...3
        effect.keyframes = [.init(time: 1, rect: CGRect(x: 5, y: 10, width: 60, height: 55)),
                            .init(time: 3, rect: CGRect(x: 95, y: 10, width: 60, height: 55))]
        func rendered(_ time: Double, enabled: Bool = true) throws -> CIImage {
            var e = effect; e.enabled = enabled
            return try BlurRenderer.render(image: image, pairs: [(shape, e)], canvasSize: CGSize(width: 160, height: 80), time: time)
        }
        let left = CGRect(x: 0, y: 0, width: 150, height: 160), right = CGRect(x: 170, y: 0, width: 150, height: 160)
        #expect(try brightCount(rendered(1), box: left) > 30)
        #expect(try brightCount(rendered(1), box: right) == 0)
        #expect(try brightCount(rendered(3), box: right) > 30)
        #expect(try brightCount(rendered(3), box: left) == 0)
        #expect(try brightCount(rendered(0), box: image.extent) == 0)
        #expect(try brightCount(rendered(2, enabled: false), box: image.extent) == 0)
    }

    @Test
    func imageAndWorkspaceRoundTripUseNewVersionsOnlyWhenNeeded() throws {
        let plain = ProjectFile(mediaPath: "synthetic.png", regions: [region()], drawings: [])
        #expect(try ProjectFile.decode(plain.encoded()).version == 1)
        #expect(!String(decoding: try plain.encoded(), as: UTF8.self).contains("decoration"))
        var labelled = plain
        labelled.regions[0].effect.decoration = CoverDecoration(text: "학생 A 🙂")
        let issue = TrackingReview(start: 1, end: 2, reason: .recognitionGap)
        labelled.regions[0].effect.trackingReviews = [issue]
        let saved = try labelled.encoded()
        let reopened = try VideoProjectFile.decodeLegacy(saved)
        #expect(reopened.version == 5)
        #expect(reopened.regions == labelled.regions)
        // Removing the feature returns to the original portable representation.
        labelled.regions[0].effect.decoration = nil; labelled.regions[0].effect.trackingReviews = []
        #expect(try ProjectFile.decode(labelled.encoded()).version == 1)
        var workspace = MultiPageProjectFile(title: "합성 문서", currentIndex: 0,
            pages: [.init(mediaPath: "synthetic.png", regions: reopened.regions, drawings: [])])
        let restored = try MultiPageProjectFile.decode(workspace.encoded())
        #expect(restored.version == 6)
        #expect(restored.pages[0].regions == reopened.regions)
        workspace.pages[0].regions = plain.regions
        #expect(try MultiPageProjectFile.decode(workspace.encoded()).version == 2)
    }

    @Test
    func invalidLabelsReviewIntervalsAndMislabelledVersionsAreRefused() throws {
        var project = ProjectFile(mediaPath: "synthetic.png", regions: [region(label: "비공개")], drawings: [])
        // Direct Codable encoding deliberately keeps the default legacy version: refusing this
        // prevents a feature-bearing file from being opened silently by older readers.
        #expect(throws: (any Error).self) { try ProjectFile.decode(JSONEncoder().encode(project)) }
        project.regions[0].effect.decoration?.scale = 2
        #expect(throws: (any Error).self) { try ProjectFile.decode(project.encoded()) }
        project.regions[0].effect.decoration = CoverDecoration(text: "가림")
        project.regions[0].effect.inverted = true
        #expect(throws: (any Error).self) { try ProjectFile.decode(project.encoded(), allowsReverse: true) }
        project.regions[0].effect.inverted = false
        project.regions[0].effect.trackingReviews = [.init(start: 4, end: 2, reason: .lostTarget)]
        #expect(throws: (any Error).self) { try ProjectFile.decode(project.encoded()) }
        let issue = TrackingReview(start: 1, end: 2, reason: .lostTarget)
        project.regions[0].effect.trackingReviews = [issue, issue]
        #expect(throws: (any Error).self) { try ProjectFile.decode(project.encoded()) }
    }

    @Test
    func unknownNestedMacFieldsCannotBeDiscardedOnReopen() throws {
        let project = ProjectFile(mediaPath: "synthetic.png", regions: [region(label: "비공개")], drawings: [])
        let original = String(decoding: try project.encoded(), as: UTF8.self)
        let modified = original.replacingOccurrences(of: "\"scale\" : 0.8", with: "\"scale\" : 0.8, \"futureLayout\" : true")
        #expect(modified != original)
        #expect(throws: (any Error).self) { try VideoProjectFile.decodeLegacy(Data(modified.utf8)) }
    }

    @Test @MainActor
    func videoSevenPersistsCorrectionsAndSupportsTokenPreservingUpdates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("blur-decoration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        // Synthetic bytes are retained with test artifacts; no original media is read or altered.
        let source = directory.appendingPathComponent("synthetic.bin")
        let original = Data("decoration source preservation".utf8)
        try original.write(to: source)
        typealias R = VideoTimeline.Rational
        let timeline = try VideoTimeline(assetDuration: R(3), tracks: [.init(id: 1, kind: "video", mediaTimescale: 12,
            segments: [.init(assetStart: R(0), assetDuration: R(3), mediaStart: R(0), rate: R(1))])])
        let binding = try VideoProjectSourceBinding(source: .capture(source), timeline: timeline)
        var item = region(label: "학생 🙂")
        let issue = TrackingReview(start: 1, end: 2, reason: .lostTarget)
        item.effect.trackingReviews = [issue]
        let project = try VideoProjectFile.make(mediaPath: source.lastPathComponent, binding: binding,
            producerVersion: "test.decoration", regions: [item], drawings: [])
        #expect(project.payload.version == 7)
        let old = project.edits
        var now = old
        now.regions[0].effect.trackingReviews[0].status = .corrected
        let updated = try project.updated(mediaPath: source.lastPathComponent, binding: binding,
            producerVersion: "test.decoration", baseline: old, current: now, normalized: now)
        let reopened = try VideoProjectFile.decode(updated.encoded())
        #expect(reopened.payload.regions[0].effect.decoration == item.effect.decoration)
        #expect(reopened.payload.regions[0].effect.trackingReviews[0].id == issue.id)
        #expect(reopened.payload.regions[0].effect.trackingReviews[0].status == .corrected)
        #expect(try Data(contentsOf: source) == original)
        try binding.source.validate()
        let plain = try VideoProjectFile.make(mediaPath: source.lastPathComponent, binding: binding,
            producerVersion: "test.decoration", regions: [region()], drawings: [])
        #expect(plain.payload.version == 3)
        var reverse = region(); reverse.effect.inverted = true
        #expect(try VideoProjectFile.make(mediaPath: source.lastPathComponent, binding: binding,
            producerVersion: "test.decoration", regions: [reverse], drawings: []).payload.version == 4)
    }

    private func pixelSummary(_ image: CIImage, box: CGRect) throws -> (dark: Int, colored: Int, colorBounds: CGRect?, foregroundBounds: CGRect?) {
        let cg = try #require(CIContext().createCGImage(image.cropped(to: box), from: box))
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try #require(CGContext(data: &bytes, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        var dark = 0, colored = 0, minX = cg.width, minY = cg.height, maxX = -1, maxY = -1
        var foregroundMinX = cg.width, foregroundMinY = cg.height, foregroundMaxX = -1, foregroundMaxY = -1
        for y in 0..<cg.height {
            for x in 0..<cg.width {
                let offset = (y * cg.width + x) * 4
                let rgb = [Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2])]
                if rgb.max()! < 45 { dark += 1 }
                if rgb.max()! > 90 {
                    foregroundMinX = min(foregroundMinX, x); foregroundMinY = min(foregroundMinY, y)
                    foregroundMaxX = max(foregroundMaxX, x); foregroundMaxY = max(foregroundMaxY, y)
                }
                if rgb.max()! > 90 && rgb.max()! - rgb.min()! > 55 {
                    colored += 1; minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
        }
        let bounds = colored > 0 ? CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1) : nil
        let foreground = foregroundMaxX >= 0 ? CGRect(x: foregroundMinX, y: foregroundMinY,
            width: foregroundMaxX - foregroundMinX + 1, height: foregroundMaxY - foregroundMinY + 1) : nil
        return (dark, colored, bounds, foreground)
    }

    @Test @MainActor
    func complexEmojiRenderInColorWithStablePixelAspectAcrossOppositeCoverShapes() throws {
        let image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 300))
        let artifacts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/qa-decoration-pixels-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        var measurements: [String] = []
        for (emojiIndex, text) in ["👍🏽", "👨‍👩‍👧‍👦"].enumerated() {
            var aspectIntervals: [ClosedRange<CGFloat>] = []
            var aspects: [CGFloat] = []
            for (shapeIndex, rect) in [CGRect(x: 20, y: 100, width: 250, height: 90), CGRect(x: 100, y: 20, width: 90, height: 250)].enumerated() {
                let shape = RegionShape.rectangle(id: UUID(), origin: rect.origin, size: rect.size)
                let output = try BlurRenderer.render(image: image, pairs: [(shape, region(label: text).effect)],
                    canvasSize: image.extent.size, time: nil)
                let summary = try pixelSummary(output, box: rect)
                #expect(summary.colored > 100, "Composite emoji must contain actual color glyph pixels")
                #expect(summary.dark > 4_000, "A solid cover remains beneath the glyph")
                // White/gray parts belong to the glyph too. A chromatic-only bounding box
                // changes with a blue gradient's threshold and can falsely imply distortion.
                // The cover is black, so the full visible foreground is measured independently.
                let bounds = try #require(summary.foregroundBounds)
                #expect(bounds.width > 2 && bounds.height > 2)
                aspects.append(bounds.width / bounds.height)
                // One-pixel uncertainty at each rasterized dimension, rather than a broad
                // percentage tolerance: the two possible aspect intervals must overlap.
                aspectIntervals.append(((bounds.width - 1) / (bounds.height + 1))...((bounds.width + 1) / (bounds.height - 1)))
                let label = try #require(CoverDecoration(text: text).annotation(in: rect))
                measurements.append("emoji=\(text) shape=\(shapeIndex) target=\(label.bounds) font=\(label.textFontSize) colorBounds=\(String(describing: summary.colorBounds)) foregroundBounds=\(bounds) colored=\(summary.colored) aspect=\(bounds.width / bounds.height)")
                let pixels = try #require(CIContext().createCGImage(output, from: output.extent))
                let url = artifacts.appendingPathComponent("emoji-\(emojiIndex)-shape-\(shapeIndex).png")
                let file = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(file, pixels, nil)
                #expect(CGImageDestinationFinalize(file))
            }
            #expect(aspectIntervals[0].overlaps(aspectIntervals[1]), "Pixel aspect must survive changing the parent's aspect within one-pixel raster uncertainty")
            #expect(abs(aspects[0] - aspects[1]) < 0.15, "Original aspect tolerance remains unchanged")
        }
        try measurements.joined(separator: "\n").write(to: artifacts.appendingPathComponent("measurements.txt"), atomically: true, encoding: .utf8)
        print("Emoji pixel evidence: \(artifacts.path)\n" + measurements.joined(separator: "\n"))
    }

    @Test @MainActor
    func pngAndFlattenedPDFReopenWithAttachedEmojiAndUnchangedOriginalDigest() throws {
        let directory = try VideoExportTests().directory()
        let input = directory.appendingPathComponent("original.png")
        let source = try #require(CIContext().createCGImage(
            CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 240, height: 160)),
            from: CGRect(x: 0, y: 0, width: 240, height: 160)))
        let destination = try #require(CGImageDestinationCreateWithURL(input as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, source, nil)
        #expect(CGImageDestinationFinalize(destination))
        let digest = try PageWorkspace.digest(of: input)
        let area = CGRect(x: 30, y: 20, width: 180, height: 120)
        let shape = RegionShape.rectangle(id: UUID(), origin: area.origin, size: area.size)
        let effect = region(label: "👍🏽").effect
        let png = directory.appendingPathComponent("labelled.png")
        try BlurredImageExporter.export(source: source, pairs: [(shape, effect)], canvasSize: CGSize(width: 240, height: 160),
            inputURL: input, outputURL: png, type: .png, quality: 1, expectedSourceSHA256: digest)
        let pngSource = try #require(CGImageSourceCreateWithURL(png as CFURL, nil))
        let pngImage = try #require(CGImageSourceCreateImageAtIndex(pngSource, 0, nil))
        let pngPixels = try pixelSummary(CIImage(cgImage: pngImage), box: area)
        #expect(pngPixels.dark > 8_000 && pngPixels.colored > 100)

        var workspace = try PageWorkspace.open([input])
        workspace.pages[0].regions = [.init(shape: .rectangle(id: shape.id, origin: CGPoint(x: 0.125, y: 0.125),
            size: CGSize(width: 0.75, height: 0.75)), effect: effect)]
        let pdf = directory.appendingPathComponent("labelled.pdf")
        try workspace.exportPDF(to: pdf)
        let document = try #require(PDFDocument(url: pdf))
        #expect(document.pageCount == 1)
        #expect(document.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
                "Flattened output must not retain hidden source text or separate label text")
        let pdfWorkspace = try PageWorkspace.open([pdf])
        let pdfImage = try pdfWorkspace.image(at: 0)
        let pdfArea = CGRect(x: CGFloat(pdfImage.width) * 0.125, y: CGFloat(pdfImage.height) * 0.125,
            width: CGFloat(pdfImage.width) * 0.75, height: CGFloat(pdfImage.height) * 0.75)
        let pdfPixels = try pixelSummary(CIImage(cgImage: pdfImage), box: pdfArea)
        #expect(pdfPixels.dark > 1_000 && pdfPixels.colored > 100)
        #expect(try PageWorkspace.digest(of: input) == digest)
        try workspace.validateSourcesUnchanged()
    }

    @Test @MainActor
    func exportedVideoFramesKeepCoverAndColoredEmojiTogetherAndPreserveSource() async throws {
        let directory = try VideoExportTests().directory()
        let input = directory.appendingPathComponent("moving-label.mp4")
        try VideoExportTests().ffmpeg(["-f", "lavfi", "-i", "color=c=white:size=320x160:rate=10:duration=2",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", input.path])
        let digest = try PageWorkspace.digest(of: input)
        let shape = RegionShape.rectangle(id: UUID(), origin: CGPoint(x: 10, y: 30), size: CGSize(width: 110, height: 100))
        var effect = region(label: "🙂").effect
        effect.keyframes = [.init(time: 0, rect: CGRect(x: 10, y: 30, width: 110, height: 100)),
                            .init(time: 1.5, rect: CGRect(x: 200, y: 30, width: 110, height: 100))]
        let exporter = BlurredVideoExporter()
        await exporter.export(input: input, pairs: [(shape, effect)], quality: .high,
            canvasBounds: CGSize(width: 320, height: 160), expectedSourceSHA256: digest)
        let output = try #require(exporter.lastOutputURL, "Export must finish: \(exporter.statusText)")
        #expect(!exporter.wasCancelled)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let left = CGRect(x: 0, y: 0, width: 140, height: 160)
        let right = CGRect(x: 180, y: 0, width: 140, height: 160)
        for (time, covered, clear) in [(0.0, left, right), (1.5, right, left)] {
            let frame = CIImage(cgImage: try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image)
            let found = try pixelSummary(frame, box: covered), absent = try pixelSummary(frame, box: clear)
            #expect(found.dark > 3_000 && found.colored > 100, "Expected black cover and color glyph at \(time)")
            #expect(absent.dark < 50 && absent.colored < 50, "The previous/opposite position must return to white")
        }
        #expect(try PageWorkspace.digest(of: input) == digest)
    }
}
