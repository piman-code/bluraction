import Testing
import AVFoundation
import CoreImage
@testable import BlurAction

@Suite(.serialized)
final class VideoExportTests {
    @MainActor
    @Test
    func testVideoFramePixelBudgetAndMetadataBounds() throws {
        try BlurredVideoExporter.validateOutputSize(CGSize(width: 32_768, height: 4_096))
        #expect(throws: BlurredVideoExporter.ExportError.videoFrameTooLarge) {
            try BlurredVideoExporter.validateOutputSize(CGSize(width: 32_768, height: 4_097))
        }
        #expect(throws: BlurredVideoExporter.ExportError.videoSizeUnknown) {
            try BlurredVideoExporter.validateOutputSize(CGSize(width: CGFloat.infinity, height: 100))
        }
        #expect(try BlurredVideoExporter.outputBitRate(quality: .original, estimatedRate: 500_000_000,
            frameRate: 240, size: CGSize(width: 1920, height: 1080)) == 500_000_000)
        #expect(try BlurredVideoExporter.outputBitRate(quality: .high, estimatedRate: 12_000_000,
            frameRate: 240, size: CGSize(width: 32_768, height: 4_096)) == 500_000_000,
            "Computed rates must be bounded before conversion to Int")
        for (rate, fps) in [(Double.nan, 30.0), (.infinity, 30), (-1, 30), (500_000_001, 30), (12_000_000, .nan), (12_000_000, .infinity), (12_000_000, -1), (12_000_000, 241)] {
            #expect(throws: BlurredVideoExporter.ExportError.invalidVideoMetadata) {
                try BlurredVideoExporter.outputBitRate(quality: .original, estimatedRate: rate,
                                                        frameRate: fps, size: CGSize(width: 1280, height: 720))
            }
        }
    }

    func ffmpeg(_ args: [String]) throws {
        guard let executable = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw NSError(domain: "Synthetic fixture generation requires ffmpeg", code: 1) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin"] + args
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
    func fixture(in directory: URL) throws -> URL {
        let base = directory.appendingPathComponent("generated.mov")
        let rotated = directory.appendingPathComponent("rotated.mov")
        try ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=128x96:rate=12:duration=1",
                    "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=1",
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", base.path])
        try ffmpeg(["-display_rotation", "90", "-i", base.path, "-c", "copy", rotated.path])
        return rotated
    }
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("blur-core-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func samples(_ asset: AVAsset, type: AVMediaType) async throws -> Int {
        let tracks = try await asset.loadTracks(withMediaType: type)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: type == .video ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] : nil)
        reader.add(out)
        XCTAssertTrue(reader.startReading())
        var count = 0
        while let sample = out.copyNextSampleBuffer() { count += CMSampleBufferGetNumSamples(sample) }
        XCTAssertEqual(reader.status, .completed)
        return count
    }
    func firstFrame(_ asset: AVAsset) async throws -> CIImage {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(out); XCTAssertTrue(reader.startReading())
        let sample = try XCTUnwrap(out.copyNextSampleBuffer())
        let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        let image = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        let copy = try XCTUnwrap(context.createCGImage(image, from: image.extent))
        reader.cancelReading()
        return CIImage(cgImage: copy)
    }

    @MainActor
    @Test
    func testLongDecomposedVideoNameReservesSuffixAndCollisionBytes() {
        let stem = (String(repeating: "한", count: 26) + "abcdefghijklmno").decomposedStringWithCanonicalMapping
        #expect((stem + ".mov").utf8.count <= 255)
        XCTAssertGreaterThan((stem + "_blurred.mov").utf8.count, 255)
        let input = URL(fileURLWithPath: "/tmp/").appendingPathComponent(stem + ".mov")

        var names = Set<String>()
        for collision in [0, 1, 12345] {
            let output = BlurredVideoExporter.outputURL(for: input, collision: collision)
            let name = output.lastPathComponent
            let suffix = "_blurred" + (collision == 0 ? "" : "(\(collision))") + ".mov"
            XCTAssertEqual(output.deletingLastPathComponent(), input.deletingLastPathComponent())
            XCTAssertTrue(name.hasPrefix("한"))
            XCTAssertTrue(name.hasSuffix(suffix))
            #expect(name.utf8.count <= 255)
            #expect(name.decomposedStringWithCanonicalMapping.utf8.count <= 255)
            XCTAssertTrue(names.insert(name).inserted)
        }

        let short = URL(fileURLWithPath: "/tmp/clip.mov")
        XCTAssertEqual(BlurredVideoExporter.outputURL(for: short, collision: 0).lastPathComponent, "clip_blurred.mov")
        XCTAssertEqual(BlurredVideoExporter.outputURL(for: short, collision: 1).lastPathComponent, "clip_blurred(1).mov")
    }

    @MainActor
    @Test
    func testRealRotatedVideoAudioFramesMaskAndCollision() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try fixture(in: dir), original = try Data(contentsOf: input)
        let collision = dir.appendingPathComponent("rotated_blurred.mov")
        try Data("existing output".utf8).write(to: collision)
        let asset = AVURLAsset(url: input)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(videos.first)
        let transform = try await video.load(.preferredTransform)
        XCTAssertNotEqual(transform, .identity)
        let natural = try await video.load(.naturalSize)
        let size = CGRect(origin: .zero, size: natural).applying(transform).size
        let document = DocumentModel()
        await withCheckedContinuation { continuation in
            document.onLoad = { continuation.resume() }
            document.load(url: input)
        }
        XCTAssertTrue(document.hasVideo, document.errorMessage ?? "")
        XCTAssertEqual(document.appliedVideoSize, size)
        let playerItem = AVPlayerItem(asset: VideoAssetPolicy.asset(url: input))
        XCTAssertTrue(try await playerItem.asset.load(.isPlayable))
        let shape = RegionShape.rectangle(id: UUID(), origin: CGPoint(x: 0, y: 0), size: CGSize(width: size.width, height: size.height / 2))
        let effect = RegionEffect(blurRadius: 20, featherRadius: 0)
        let exporter = BlurredVideoExporter()
        await exporter.export(input: input, pairs: [(shape, effect)], quality: .high, canvasBounds: size)
        XCTAssertFalse(exporter.wasCancelled, exporter.statusText)
        let output = try XCTUnwrap(exporter.lastOutputURL, exporter.statusText)
        XCTAssertEqual(output.lastPathComponent, "rotated_blurred(1).mov")
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertEqual(try String(contentsOf: collision, encoding: .utf8), "existing output")
        let result = AVURLAsset(url: output)
        let resultTracks = try await result.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(resultTracks.first)
        let outputSize = try await track.load(.naturalSize)
        XCTAssertEqual(outputSize, size)
        let frameCount = try await samples(result, type: .video)
        XCTAssertEqual(frameCount, 12)
        let audioCount = try await samples(result, type: .audio)
        XCTAssertGreaterThan(audioCount, 20)
        let audioTracks = try await result.loadTracks(withMediaType: .audio)
        let audioReader = try AVAssetReader(asset: result)
        let pcm = AVAssetReaderTrackOutput(track: try XCTUnwrap(audioTracks.first), outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false])
        audioReader.add(pcm); XCTAssertTrue(audioReader.startReading())
        var audible = false
        while let sample = pcm.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            let count = CMBlockBufferGetDataLength(block)
            var bytes = [UInt8](repeating: 0, count: count)
            XCTAssertEqual(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: &bytes), noErr)
            if bytes.contains(where: { $0 != 0 }) { audible = true }
        }
        XCTAssertTrue(audible)
        XCTAssertEqual(audioReader.status, .completed)
        let duration = try await result.load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.12)
        let source = BlurRenderer.oriented(try await firstFrame(asset), transform: transform)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let orientedReference = try await generator.image(at: .zero).image
        XCTAssertLessThan(RenderingCoreTests().difference(source, CIImage(cgImage: orientedReference), rect: source.extent), 4)
        let expected = try BlurRenderer.render(image: source, pairs: [(shape, effect)], canvasSize: size, time: 0)
        let actual = try await firstFrame(result)
        let helper = RenderingCoreTests()
        XCTAssertLessThan(helper.difference(expected, actual, rect: expected.extent), 12)
        XCTAssertGreaterThan(helper.difference(source, actual, rect: CGRect(x: 5, y: 5, width: size.width - 10, height: size.height / 2 - 10)), 8)
        XCTAssertLessThan(helper.difference(source, actual, rect: CGRect(x: 5, y: size.height / 2 + 5, width: size.width - 10, height: size.height / 2 - 10)), 12)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix(".bluraction-") })
    }

    @MainActor
    @Test
    func testRealPausedVideoPreviewCachesSourceAndAppliesRotation() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try fixture(in: dir)
        let asset = AVURLAsset(url: input)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let transform = try await track.load(.preferredTransform)
        let item = AVPlayerItem(asset: asset), player = AVPlayer()
        let preview = LiveBlurCompositor()
        preview.videoTransform = transform
        preview.videoDisplayRect = CGRect(x: 0, y: 0, width: 96, height: 128)
        var pairs: [(shape: RegionShape, effect: RegionEffect)] = []
        preview.regionsProvider = { pairs }
        preview.attach(item: item, player: player)
        player.replaceCurrentItem(with: item)
        player.play()
        for _ in 0..<150 {
            preview.refresh()
            if preview.contents != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        player.pause()
        preview.refresh()
        let original = try XCTUnwrap(preview.contents as! CGImage?)
        XCTAssertEqual(original.width, 96)
        XCTAssertEqual(original.height, 128)
        let shape = RegionShape.rectangle(id: UUID(), origin: .zero, size: CGSize(width: 96, height: 64))
        pairs = [(shape, RegionEffect(blurRadius: 20, featherRadius: 0))]
        // No seek/new frame: refresh must use the cached source, not the previous result.
        preview.refresh()
        let blurred = try XCTUnwrap(preview.contents as! CGImage?)
        let helper = RenderingCoreTests()
        XCTAssertGreaterThan(helper.difference(CIImage(cgImage: original), CIImage(cgImage: blurred), rect: CGRect(x: 0, y: 0, width: 96, height: 64)), 5)
        pairs = []
        preview.refresh()
        let restored = try XCTUnwrap(preview.contents as! CGImage?)
        XCTAssertLessThan(helper.difference(CIImage(cgImage: original), CIImage(cgImage: restored), rect: CGRect(x: 0, y: 0, width: 96, height: 128)), 1)
        preview.invalidateFrame()
        XCTAssertNil(preview.contents)
        XCTAssertEqual(preview.backgroundColor?.alpha, 1)
        preview.detach()
        XCTAssertNil(preview.contents)
    }

    @MainActor
    @Test
    func testMP4RecordedPathWaitsAndMatchesEveryExportedFrame() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("motion.mp4")
        try ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=128x96:rate=8:duration=3", "-c:v", "libx264", "-pix_fmt", "yuv420p", input.path])
        let a = RegionShape.rectangle(id: UUID(), origin: CGPoint(x: 5, y: 5), size: CGSize(width: 24, height: 24))
        let b = a.replacing(rect: CGRect(x: 52, y: 5, width: 24, height: 24))
        let c = a.replacing(rect: CGRect(x: 99, y: 60, width: 24, height: 24))
        let initial: [RegionEditing.Pair] = [(a, RegionEffect(blurRadius: 25, featherRadius: 0))]
        let first = RegionEditing.updating([b], in: initial, time: 1.25, recording: true, anchorTime: 1, anchorPairs: initial)
        let pairs = RegionEditing.updating([c], in: first, time: 2.25, recording: true, anchorTime: 2, anchorPairs: first)
        let annotation = DrawingAnnotation(kind: .line, points: [CGPoint(x: 8, y: 82), CGPoint(x: 118, y: 12)],
                                           color: .systemRed, lineWidth: 5)
        XCTAssertEqual(RegionEditing.displayed(pairs[0], at: 0.5), a)
        XCTAssertEqual(RegionEditing.displayed(pairs[0], at: 1.75), b)
        XCTAssertEqual(RegionEditing.displayed(pairs[0], at: 2.5), c)
        let exporter = BlurredVideoExporter()
        await exporter.export(input: input, pairs: pairs, quality: .original, canvasBounds: CGSize(width: 128, height: 96), annotations: [annotation])
        let output = try XCTUnwrap(exporter.lastOutputURL, exporter.statusText)
        XCTAssertEqual(output.pathExtension, "mp4")
        let sourceAsset = AVURLAsset(url: input), resultAsset = AVURLAsset(url: output)
        let sourceGenerator = AVAssetImageGenerator(asset: sourceAsset)
        let resultGenerator = AVAssetImageGenerator(asset: resultAsset)
        sourceGenerator.requestedTimeToleranceBefore = .zero; sourceGenerator.requestedTimeToleranceAfter = .zero
        resultGenerator.requestedTimeToleranceBefore = .zero; resultGenerator.requestedTimeToleranceAfter = .zero
        let helper = RenderingCoreTests()
        for frame in 0..<24 {
            let t = Double(frame) / 8
            let time = CMTime(seconds: t, preferredTimescale: 600)
            let source = CIImage(cgImage: try await sourceGenerator.image(at: time).image)
            let actual = CIImage(cgImage: try await resultGenerator.image(at: time).image)
            let expected = try BlurRenderer.render(image: source, pairs: pairs, canvasSize: CGSize(width: 128, height: 96), time: t, annotations: [annotation])
            XCTAssertLessThan(helper.difference(expected, actual, rect: expected.extent), 12)
        }
    }

    @MainActor
    @Test
    func testVideoWithoutAudioAndTaskCancellation() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("silent.mov")
        try ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=64x64:rate=4:duration=1", "-c:v", "libx264", input.path])
        let exporter = BlurredVideoExporter()
        await exporter.export(input: input, pairs: [], quality: .original, canvasBounds: CGSize(width: 64, height: 64))
        let output = try XCTUnwrap(exporter.lastOutputURL, exporter.statusText)
        let asset = AVURLAsset(url: output)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 0)
        let frames = try await samples(asset, type: .video)
        XCTAssertEqual(frames, 4)
        let task = Task { await exporter.export(input: input, pairs: [], quality: .low, canvasBounds: CGSize(width: 64, height: 64)) }
        task.cancel()
        await task.value
        XCTAssertTrue(exporter.wasCancelled)
        XCTAssertNil(exporter.lastOutputURL)
        XCTAssertEqual(exporter.statusText, "취소됨")
    }

    @MainActor
    @Test
    func testCancelThenFailureClearsSuccessAndCleansTemporaryFiles() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try fixture(in: dir)
        let exporter = BlurredVideoExporter()
        await exporter.export(input: input, pairs: [], quality: .low, canvasBounds: CGSize(width: 96, height: 128))
        XCTAssertNotNil(exporter.lastOutputURL, exporter.statusText)
        await exporter.export(input: input, pairs: [], quality: .low, canvasBounds: CGSize(width: 96, height: 128)) { _, _ in exporter.cancel() }
        XCTAssertTrue(exporter.wasCancelled)
        XCTAssertNil(exporter.lastOutputURL)
        XCTAssertEqual(exporter.statusText, "취소됨")
        XCTAssertFalse(exporter.isExporting)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix(".bluraction-") })
        await exporter.export(input: dir.appendingPathComponent("missing.mov"), pairs: [], quality: .low, canvasBounds: CGSize(width: 96, height: 128))
        XCTAssertFalse(exporter.wasCancelled)
        XCTAssertNil(exporter.lastOutputURL)
        XCTAssertTrue(exporter.statusText.hasPrefix("실패:"))
    }
}
