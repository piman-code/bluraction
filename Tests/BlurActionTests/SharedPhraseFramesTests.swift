import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import BlurAction

@Suite(.serialized)
struct SharedPhraseFramesTests {
    private func fixture(rate: Int = 30, rotated: Bool = false) throws -> URL {
        let helper = VideoExportTests(), directory = try helper.directory()
        let base = directory.appendingPathComponent("shared-frames.mp4")
        try helper.ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=\(rate):duration=3",
            "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", base.path])
        guard rotated else { return base }
        let rotated = directory.appendingPathComponent("rotated.mov")
        try helper.ffmpeg(["-display_rotation", "90", "-i", base.path, "-c", "copy", rotated.path])
        return rotated
    }

    private func assertEqual(_ a: [ObjectTracker.Outcome], _ b: [ObjectTracker.Outcome]) {
        #expect(a.count == b.count)
        for (first, second) in zip(a, b) {
            #expect(first.cancelled == second.cancelled)
            #expect(first.lostTarget == second.lostTarget)
            #expect(first.samples.map(\.time) == second.samples.map(\.time))
            #expect(first.samples.count == second.samples.count)
            for (x, y) in zip(first.samples, second.samples) {
                #expect(abs(x.box.minX - y.box.minX) < 1e-8)
                #expect(abs(x.box.minY - y.box.minY) < 1e-8)
                #expect(abs(x.box.width - y.box.width) < 1e-8)
                #expect(abs(x.box.height - y.box.height) < 1e-8)
            }
        }
    }

    /// Decode the legacy reader's exact range independently: a tracker can lose a
    /// target early, so output-sample equality alone cannot prove endpoint coverage.
    private func independentTimes(asset: AVAsset, track: AVAssetTrack, start: Double, end: Double) throws -> [Double] {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = ObjectTracker.forwardReadRange(from: start, until: end)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        #expect(reader.startReading())
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if time > start + 1.0 / 240 { times.append(time) }
        }
        #expect(reader.status == .completed)
        return times
    }

    @Test func continuousFractionalSparseAndRotatedFramesMatchIndependentTracking() async throws {
        for rotated in [false, true] {
            let url = try fixture(rotated: rotated)
            let original = try VideoProjectSourceBinding.Source.capture(url)
            let asset = VideoAssetPolicy.asset(url: url)
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let (transform, rate) = try await track.load(.preferredTransform, .nominalFrameRate)
            if rotated { #expect(transform != .identity) }
            let scanner = try PhraseTracker.SceneCutScanner(asset: asset, track: track, cancellation: .init())
            let boxes = [CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.3)]
            var options = ObjectTracker.Options(); options.smoothing = false
            for (start, end) in [(0.0, 0.25), (0.25, 0.517), (0.517, 0.783), (2.1, 2.4), (2.4, 2.7)] {
                let buffer = PhraseTracker.SharedFrameBuffer()
                let upper = CMTimeRangeGetEnd(ObjectTracker.forwardReadRange(from: start, until: end)).seconds
                let cuts = try scanner.cuts(from: start, until: end, frameUpperBound: upper) { time, image, bytes in
                    if time > start + 1.0 / 240 { buffer.append(time: time, image: image, byteCount: bytes) }
                }
                let frames = try #require(buffer.frames)
                #expect(frames.map(\.time) == (try independentTimes(asset: asset, track: track, start: start, end: end)))
                let legacyCuts = try await PhraseTracker.sceneCuts(url: url, from: start, until: end, cancellation: .init())
                #expect(cuts == legacyCuts)
                let until = cuts.first.map { max(start, $0 - 1.0 / 240) } ?? end
                let shared = ObjectTracker.ForwardFrames(frames: frames, transform: transform, frameRate: rate)
                let expected = try await ObjectTracker.trackMany(url: url, from: start, until: until, boxes: boxes,
                    options: options, cancellation: .init(), progress: { _ in })
                let actual = try await ObjectTracker.trackMany(url: url, from: start, until: until, boxes: boxes,
                    options: options, cancellation: .init(), forwardFrames: shared, progress: { _ in })
                assertEqual(actual, expected)
                #expect(!actual[0].samples.isEmpty)
            }
            #expect(try VideoProjectSourceBinding.Source.capture(url) == original)
        }
    }

    @Test func highRateIncludesEveryRoundedBoundaryFrameAndNextIntervalKeepsThem() async throws {
        let url = try fixture(rate: 240)
        let asset = VideoAssetPolicy.asset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let scanner = try PhraseTracker.SceneCutScanner(asset: asset, track: track, cancellation: .init())
        var largestBoundaryCount = 0
        for (start, end) in [(0.0, 0.25), (0.25, 0.5), (0.5, 0.75)] {
            let buffer = PhraseTracker.SharedFrameBuffer(maximumBytes: 300 * 1024 * 1024, maximumFrames: 128)
            let legacyUpper = CMTimeRangeGetEnd(ObjectTracker.forwardReadRange(from: start, until: end)).seconds
            // Explicitly request several boundary frames: the current 600-timescale
            // conversion can round the ordinary epsilon down to less than one frame.
            let upper = end + 0.01
            _ = try scanner.cuts(from: start, until: end, frameUpperBound: upper) { time, image, bytes in
                if time > start + 1.0 / 240 { buffer.append(time: time, image: image, byteCount: bytes) }
            }
            let frames = try #require(buffer.frames)
            let expected = try independentTimes(asset: asset, track: track, start: start, end: end)
            #expect(scanner.captureComplete)
            #expect(frames.map(\.time).filter { $0 < legacyUpper } == expected)
            let allExpected = try independentTimes(asset: asset, track: track, start: start, end: upper)
                .filter { $0 < upper }
            #expect(frames.map(\.time) == allExpected)
            let boundaryTimes = frames.map(\.time).filter { $0 >= end }
            #expect(boundaryTimes == allExpected.filter { $0 >= end })
            #expect(!boundaryTimes.isEmpty, "These exact frame-aligned ends must actually exercise boundary capture")
            largestBoundaryCount = max(largestBoundaryCount, boundaryTimes.count)
        }
        #expect(largestBoundaryCount >= 2, "At least one interval must retain multiple tracking boundary frames")
    }

    @Test func capturedEndBoundaryDoesNotChangeSceneCutIntervals() async throws {
        let helper = VideoExportTests(), directory = try helper.directory()
        let url = directory.appendingPathComponent("boundary-cut.mp4")
        try helper.ffmpeg(["-f", "lavfi", "-i", "color=black:s=320x180:d=0.5:r=30",
            "-f", "lavfi", "-i", "color=white:s=320x180:d=0.5:r=30",
            "-filter_complex", "[0][1]concat=n=2:v=1:a=0", "-c:v", "libx264", "-pix_fmt", "yuv420p", url.path])
        let asset = VideoAssetPolicy.asset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let scanner = try PhraseTracker.SceneCutScanner(asset: asset, track: track, cancellation: .init())
        var capturedCutBoundary = false
        for (start, end) in [(0.0, 0.5), (0.5, 0.75), (0.75, 1.0)] {
            var times: [Double] = []
            let upper = CMTimeRangeGetEnd(ObjectTracker.forwardReadRange(from: start, until: end)).seconds
            let actual = try scanner.cuts(from: start, until: end, frameUpperBound: upper) { time, _, _ in times.append(time) }
            let expected = try await PhraseTracker.sceneCuts(url: url, from: start, until: end, cancellation: .init())
            #expect(actual == expected)
            #expect(actual.isEmpty, "A boundary frame supplies tracking only, never a cross-interval cut comparison")
            let expectedFrames = try independentTimes(asset: asset, track: track, start: start, end: end)
            #expect(times.filter { $0 >= end } == expectedFrames.filter { $0 >= end })
            if end == 0.5 { capturedCutBoundary = times.contains(0.5) }
        }
        #expect(capturedCutBoundary, "The hard-cut frame itself must have been captured outside the cut-comparison interval")
    }

    @Test func capOverflowReleasesFramesAndFallsBackToIndependentReader() async throws {
        let image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        let frameCap = PhraseTracker.SharedFrameBuffer(maximumFrames: 1)
        frameCap.append(time: 0.1, image: image); #expect(frameCap.frames?.count == 1)
        frameCap.append(time: 0.2, image: image); #expect(frameCap.frames == nil)
        frameCap.append(time: 0.3, image: image); #expect(frameCap.frames == nil)
        let byteCap = PhraseTracker.SharedFrameBuffer(maximumBytes: 1024)
        byteCap.append(time: 0.1, image: image, byteCount: 2048)
        #expect(byteCap.frames == nil, "Actual decoder allocation, including row padding, governs the cap")
        let url = try fixture()
        var options = ObjectTracker.Options(); options.smoothing = false
        let boxes = [CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.3)]
        let cache: ObjectTracker.ForwardFrames? = frameCap.frames.map { .init(frames: $0, transform: .identity, frameRate: 30) }
        let expected = try await ObjectTracker.trackMany(url: url, from: 0.137, until: 0.5, boxes: boxes,
            options: options, cancellation: .init(), progress: { _ in })
        let actual = try await ObjectTracker.trackMany(url: url, from: 0.137, until: 0.5, boxes: boxes,
            options: options, cancellation: .init(), forwardFrames: cache, progress: { _ in })
        assertEqual(actual, expected)
    }

    @Test func pendingCountAndAllocationCapsFallbackAndRecoverSubsequentIntervals() async throws {
        let url = try fixture(rate: 240)
        let asset = VideoAssetPolicy.asset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let (transform, rate) = try await track.load(.preferredTransform, .nominalFrameRate)
        for (frameCap, byteCap) in [(1, 32 * 1024 * 1024), (4, 1)] {
            let scanner = try PhraseTracker.SceneCutScanner(asset: asset, track: track, cancellation: .init(),
                maximumPendingFrames: frameCap, maximumPendingBytes: byteCap)
            for (start, end) in [(0.0, 0.025), (0.025, 0.05), (2.1, 2.125)] {
                let buffer = PhraseTracker.SharedFrameBuffer()
                // Request several real boundary samples explicitly. The legacy
                // tracking epsilon can contain just one sample after CMTime rounding,
                // which would not exercise a one-frame pending cap in bounded reads.
                let upper = end + 0.02
                let available = try independentTimes(asset: asset, track: track, start: start, end: upper)
                #expect(available.filter { $0 >= end && $0 < upper }.count >= 3,
                    "Fixture must force count overflow before the requested capture boundary")
                let cuts = try scanner.cuts(from: start, until: end, frameUpperBound: upper) { time, image, bytes in
                    if time > start + 1.0 / 240 { buffer.append(time: time, image: image, byteCount: bytes) }
                }
                #expect(!scanner.captureComplete, "Overflow in bounded child reads must propagate to the parent")
                let expectedCuts = try await PhraseTracker.sceneCuts(url: url, from: start, until: end, cancellation: .init())
                #expect(cuts == expectedCuts, "Current cuts and future seek recovery must keep every interval")
                if !scanner.captureComplete { buffer.discard() }
                #expect(buffer.frames == nil)
                let cache = buffer.frames.map { ObjectTracker.ForwardFrames(frames: $0, transform: transform, frameRate: rate) }
                var options = ObjectTracker.Options(); options.smoothing = false
                let boxes = [CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.3)]
                let expected = try await ObjectTracker.trackMany(url: url, from: start, until: end, boxes: boxes,
                    options: options, cancellation: .init(), progress: { _ in })
                let actual = try await ObjectTracker.trackMany(url: url, from: start, until: end, boxes: boxes,
                    options: options, cancellation: .init(), forwardFrames: cache, progress: { _ in })
                assertEqual(actual, expected)
            }
        }
    }

    @Test func callbackCancellationStopsScannerAndSharedTrackingPublishesNoFrames() async throws {
        let url = try fixture(), flag = ObjectTracker.Cancellation()
        let asset = VideoAssetPolicy.asset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let scanner = try PhraseTracker.SceneCutScanner(asset: asset, track: track, cancellation: flag)
        #expect(throws: CancellationError.self) {
            try scanner.cuts(from: 0, until: 0.25, frameUpperBound: 0.26) { _, _, _ in flag.cancel() }
        }
        let frames = ObjectTracker.ForwardFrames(frames: [.init(time: 0.1,
            image: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 40)))],
            transform: .identity, frameRate: 30)
        let result = try await ObjectTracker.trackMany(url: url, from: 0, until: 0.25,
            boxes: [CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.3)], cancellation: flag,
            forwardFrames: frames, progress: { _ in })
        #expect(result[0].cancelled)
        #expect(result[0].samples.isEmpty)
    }
}
