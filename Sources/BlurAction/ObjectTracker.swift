import AVFoundation
import CoreImage
import Foundation
import Vision

/// Follows boxes through a video with Vision object tracking. Boxes are normalized to the
/// displayed (orientation-applied) frame with a bottom-left origin, like the canvas.
enum ObjectTracker {
    struct Sample: Equatable {
        var time: Double
        var box: CGRect
    }

    struct Outcome {
        /// Samples in time order (ascending), whichever direction was tracked.
        var samples: [Sample]
        /// True when the target was lost (low confidence) before reaching the end of the span.
        var lostTarget: Bool
        var cancelled: Bool
    }

    enum Direction: Equatable { case forward, backward }

    struct Options {
        var direction: Direction = .forward
        /// Centered moving average over a few frames to calm jitter.
        var smoothing = true
        /// After losing a target that is a face (a detected face sits inside its box on the starting
        /// frame), look for a face near its last place for up to `searchSeconds` and continue from
        /// there. Targets that are not faces (plates, signs) are never moved onto a face.
        var reacquireFaces = false
        var searchSeconds = 1.5
        var minimumConfidence: Float = 0.3
        /// Frames are scaled so their longer side is at most this (speed and memory); normalized
        /// boxes are unaffected.
        var maxSide: CGFloat = 960
    }

    enum TrackError: LocalizedError {
        case noVideoTrack, readFailed, boxTooSmall
        /// Keep native diagnostics available to tests without replacing the
        /// readable user message with framework internals.
        case nativeFailure(stage: FailureStage, underlying: NSError?)
        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "영상 트랙을 찾지 못했습니다."
            case .readFailed: return "영상 프레임을 읽지 못해 추적을 멈췄습니다."
            case .boxTooSmall: return "추적할 영역이 너무 작습니다. 조금 크게 잡아 주세요."
            case .nativeFailure: return "영상 처리 중 오류가 발생해 추적을 멈췄습니다."
            }
        }
    }

    enum FailureStage: String {
        case readerCreation, readerOutput, readerStart, visionRequest, readerCompletion
    }

    /// Thread-safe cancel flag shared with the UI.
    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func cancel() { lock.lock(); flag = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }

    /// Smallest normalized side a box may have (1% of the frame, less a rounding hair).
    static let minimumSide: CGFloat = 0.01 - 1e-9

    /// Live `VNTrackObjectRequest` trackers one sequence handler accepts (measured: the 33rd fails).
    static let maxTrackersPerPass = 32

    /// One box forward from `start` until `end` (compatibility entry point).
    static func track(url: URL, from start: Double, until end: Double, box: CGRect,
                      minimumConfidence: Float = 0.3, cancellation: Cancellation,
                      progress: @escaping (Double) -> Void) async throws -> Outcome {
        var options = Options()
        options.minimumConfidence = minimumConfidence
        options.smoothing = false
        return try await trackMany(url: url, from: start, until: end, boxes: [box], options: options,
                                   cancellation: cancellation, progress: progress)[0]
    }

    /// Tracks every box (normalized, as seen at `start`) in one pass toward `until`
    /// (later for `.forward`, earlier for `.backward`). Call it off the main thread.
    static func trackMany(url: URL, from start: Double, until: Double, boxes: [CGRect], options: Options = Options(),
                          cancellation: Cancellation, progress: @escaping (Double) -> Void) async throws -> [Outcome] {
        guard !boxes.isEmpty, boxes.allSatisfy({ $0.width >= minimumSide && $0.height >= minimumSide }) else { throw TrackError.boxTooSmall }
        if boxes.count > maxTrackersPerPass {
            // Vision refuses a 33rd live tracker on one handler, so larger sets go in turns.
            let groups = stride(from: 0, to: boxes.count, by: maxTrackersPerPass).map {
                Array(boxes[$0..<min($0 + maxTrackersPerPass, boxes.count)])
            }
            var outcomes: [Outcome] = []
            for (number, group) in groups.enumerated() {
                let base = Double(number) / Double(groups.count), share = 1 / Double(groups.count)
                outcomes += try await trackMany(url: url, from: start, until: until, boxes: group, options: options,
                                                cancellation: cancellation) { progress(base + $0 * share) }
            }
            return outcomes
        }
        let asset = VideoAssetPolicy.asset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw TrackError.noVideoTrack }
        let (transform, frameRate) = try await track.load(.preferredTransform, .nominalFrameRate)
        // Chunked backward reads can hand back the frame straddling a boundary twice (retimed);
        // anything closer than half a frame to the last handled frame is the same picture.
        let halfFrame = 0.5 / Double(frameRate > 0 ? frameRate : 30)
        let source = FrameSource(asset: asset, track: track, transform: transform, maxSide: options.maxSide)
        var targets = boxes.map { Target(observation: VNDetectedObjectObservation(boundingBox: $0.clamped01), size: $0.size) }
        let handler = VNSequenceRequestHandler()
        let span = abs(until - start)
        let epsilon = 1.0 / 240

        var faceTargets: Set<Int> = []
        /// Marks targets whose starting box holds a detected face; only those may be re-found.
        func classify(_ reference: CIImage) throws {
            guard options.reacquireFaces else { return }
            let faces = try detectFaces(in: reference)
            for (index, target) in targets.enumerated() {
                let box = target.observation.boundingBox
                if faces.contains(where: { box.contains(CGPoint(x: $0.midX, y: $0.midY)) && $0.width * $0.height >= box.width * box.height * 0.15 }) {
                    faceTargets.insert(index)
                }
            }
        }

        /// Advances every live target by one frame; returns false when nothing is left to follow.
        func step(_ frame: CIImage, at time: Double) throws -> Bool {
            let live = targets.indices.filter { targets[$0].state == .tracking }
            if !live.isEmpty {
                let requests = live.map { index -> VNTrackObjectRequest in
                    let request = VNTrackObjectRequest(detectedObjectObservation: targets[index].observation)
                    request.trackingLevel = .accurate
                    return request
                }
                do { try handler.perform(requests, on: frame) }
                catch { throw TrackError.nativeFailure(stage: .visionRequest, underlying: error as NSError) }
                var released: [VNTrackObjectRequest] = []
                for (request, index) in zip(requests, live) {
                    if let result = request.results?.first as? VNDetectedObjectObservation,
                       result.confidence >= options.minimumConfidence {
                        targets[index].observation = result
                        targets[index].samples.append(Sample(time: time, box: result.boundingBox))
                        continue
                    }
                    targets[index].state = options.reacquireFaces && faceTargets.contains(index) ? .searching(since: time) : .lost
                    // Free its tracker now; a face found again starts a new one, and the handler holds at most 32.
                    let release = VNTrackObjectRequest(detectedObjectObservation: targets[index].observation)
                    release.trackingLevel = .accurate
                    release.isLastFrame = true
                    released.append(release)
                }
                if !released.isEmpty { try? handler.perform(released, on: frame) }
            }
            let searching = targets.indices.filter { if case .searching = targets[$0].state { return true }; return false }
            if !searching.isEmpty {
                let faces = try detectFaces(in: frame)
                for index in searching {
                    guard case .searching(let since) = targets[index].state else { continue }
                    let last = targets[index].observation.boundingBox
                    let window = last.insetBy(dx: -last.width, dy: -last.height)
                    if let face = faces.min(by: { distance($0, last) < distance($1, last) }), window.contains(CGPoint(x: face.midX, y: face.midY)) {
                        // Keep the tracked box's size, centered on the face found again.
                        let size = targets[index].size
                        let box = CGRect(x: face.midX - size.width / 2, y: face.midY - size.height / 2,
                                         width: size.width, height: size.height).clamped01
                        targets[index].observation = VNDetectedObjectObservation(boundingBox: box)
                        targets[index].samples.append(Sample(time: time, box: box))
                        targets[index].state = .tracking
                    } else if abs(time - since) > options.searchSeconds {
                        targets[index].state = .lost
                    }
                }
            }
            progress(span > 0 ? min(1, abs(time - start) / span) : 1)
            return targets.contains { $0.state != .lost }
        }

        switch options.direction {
        case .forward:
            // The frame shown at `start` (latest frame at or before it) defines the targets.
            var reference: CIImage?
            var classified = false
            try source.read(from: max(0, start - 0.5), to: until + epsilon) { time, frame in
                if cancellation.isCancelled { return false }
                if time <= start + epsilon { // up to the reference frame
                    if options.reacquireFaces { reference = try frame(true) }
                    return true
                }
                if !classified {
                    classified = true
                    if let reference { try classify(reference) }
                }
                return try step(frame(false), at: time)
            }
        case .backward:
            // Readers only run forward: read short chunks ending at the previous chunk's start
            // and walk each one backward, so memory stays bounded.
            var upper = start + epsilon
            var referenceSeen = false
            var lastHandled: Double?
            while upper > until && !cancellation.isCancelled {
                let lower = max(until - epsilon, upper - 1.0)
                var frames: [(Double, CIImage)] = []
                try source.read(from: max(0, lower), to: upper) { time, frame in
                    if cancellation.isCancelled { return false }
                    if time >= lower - epsilon / 2 && time < upper { frames.append((time, try frame(true))) }
                    return true
                }
                var keepGoing = true
                for (time, frame) in frames.reversed() {
                    if cancellation.isCancelled { keepGoing = false; break }
                    if !referenceSeen { // the frame at `start` defines the targets
                        referenceSeen = true
                        lastHandled = time
                        try classify(frame)
                        continue
                    }
                    if let lastHandled, time > lastHandled - halfFrame { continue } // same frame again
                    if time < until - epsilon { keepGoing = false; break }
                    lastHandled = time
                    if try !step(frame, at: time) { keepGoing = false; break }
                }
                if !keepGoing || frames.isEmpty { break }
                upper = frames[0].0
            }
        }

        let cancelled = cancellation.isCancelled
        return targets.map { target in
            let ordered = target.samples.sorted { $0.time < $1.time }
            return Outcome(samples: options.smoothing ? smoothed(ordered) : ordered,
                           lostTarget: target.state != .tracking && !cancelled, cancelled: cancelled)
        }
    }

    /// Centered moving average (window 5) of box centers and sizes; times are unchanged.
    static func smoothed(_ samples: [Sample], radius: Int = 2) -> [Sample] {
        guard samples.count > 2, radius > 0 else { return samples }
        return samples.indices.map { index in
            let window = samples[max(0, index - radius)...min(samples.count - 1, index + radius)]
            let n = CGFloat(window.count)
            let midX = window.map(\.box.midX).reduce(0, +) / n, midY = window.map(\.box.midY).reduce(0, +) / n
            let width = window.map(\.box.width).reduce(0, +) / n, height = window.map(\.box.height).reduce(0, +) / n
            return Sample(time: samples[index].time,
                          box: CGRect(x: midX - width / 2, y: midY - height / 2, width: width, height: height))
        }
    }

    // MARK: - Internals

    private struct Target {
        enum State: Equatable { case tracking, searching(since: Double), lost }
        var observation: VNDetectedObjectObservation
        var size: CGSize
        var samples: [Sample] = []
        var state: State = .tracking
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(a.midX - b.midX, a.midY - b.midY)
    }

    private static func detectFaces(in frame: CIImage) throws -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        do { try VNImageRequestHandler(ciImage: frame, options: [:]).perform([request]) }
        catch { throw TrackError.nativeFailure(stage: .visionRequest, underlying: error as NSError) }
        return (request.results ?? []).map(\.boundingBox)
    }

    /// Decodes oriented, downscaled frames of one video track in presentation order.
    private struct FrameSource {
        let asset: AVAsset
        let track: AVAssetTrack
        let transform: CGAffineTransform
        let maxSide: CGFloat
        private let context = CIContext()

        init(asset: AVAsset, track: AVAssetTrack, transform: CGAffineTransform, maxSide: CGFloat) {
            self.asset = asset; self.track = track; self.transform = transform; self.maxSide = maxSide
        }

        /// Calls `body(time, frame)` for each frame in [from, to]; `frame()` builds the image
        /// lazily (`cached: true` renders it so it outlives the decoder's buffer).
        func read(from: Double, to: Double,
                  _ body: (Double, (_ cached: Bool) throws -> CIImage) throws -> Bool) throws {
            let reader: AVAssetReader
            do { reader = try AVAssetReader(asset: asset) }
            catch { throw TrackError.nativeFailure(stage: .readerCreation, underlying: error as NSError) }
            reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, from), preferredTimescale: 600),
                                           duration: CMTime(seconds: max(0.001, to - from), preferredTimescale: 600))
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw TrackError.nativeFailure(stage: .readerOutput, underlying: reader.error as NSError?) }
            reader.add(output)
            guard reader.startReading() else { throw TrackError.nativeFailure(stage: .readerStart, underlying: reader.error as NSError?) }
            defer { if reader.status == .reading { reader.cancelReading() } }
            while let buffer = output.copyNextSampleBuffer() {
                let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                guard time.isFinite, let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
                let make: (Bool) throws -> CIImage = { cached in
                    var image = BlurRenderer.oriented(CIImage(cvPixelBuffer: pixels), transform: transform)
                    let longest = max(image.extent.width, image.extent.height)
                    if longest > maxSide {
                        let scale = maxSide / longest
                        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    }
                    guard cached else { return image }
                    guard let rendered = context.createCGImage(image, from: image.extent) else {
                        throw TrackError.nativeFailure(stage: .readerOutput, underlying: nil)
                    }
                    return CIImage(cgImage: rendered)
                }
                if try !body(time, make) { break }
            }
            if reader.status == .failed { throw TrackError.nativeFailure(stage: .readerCompletion, underlying: reader.error as NSError?) }
        }
    }
}

private extension CGRect {
    var clamped01: CGRect {
        let x = min(max(0, minX), 1), y = min(max(0, minY), 1)
        return CGRect(x: x, y: y, width: min(width, 1 - x), height: min(height, 1 - y))
    }
}
