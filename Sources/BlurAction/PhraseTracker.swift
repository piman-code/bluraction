import AVFoundation
import CoreImage
import Foundation

/// OCR establishes identity; object tracking supplies the frame-by-frame motion between reads.
/// All boxes cover the entire recognized line, including padding, not just the matching characters.
enum PhraseTracker {
    enum ReviewReason: String { case trackingLost, textUnconfirmed, sceneChange, samplingGap }
    struct ReviewInterval: Equatable {
        var trackID: UUID
        var start: Double
        var end: Double
        var reason: ReviewReason
    }
    struct CoverEvidence {
        var time: Double
        var points: [CGPoint]
        var generousBox: CGRect
    }
    struct Track {
        var id = UUID()
        var phrase: String
        var samples: [ObjectTracker.Sample]
        var start: Double
        /// Includes an uncertain tail held at the last known position; reviews explain that tail.
        var end: Double
        /// Evidence exists only on actual decoded OCR frames. Intermediate tracking samples
        /// remain generous; sparse OCR is not proof that a fitted quadrilateral stayed valid.
        var coverEvidence: [CoverEvidence] = []
    }
    struct Outcome {
        var tracks: [Track]
        var reviews: [ReviewInterval]
        var cancelled: Bool
        var recognitionStep: Double
    }
    struct Snapshot {
        /// Actual decoded frame timestamp, never the requested seek time.
        var time: Double
        var lines: [AutoDetector.RecognizedLine]
    }
    struct Segment {
        var outcomes: [ObjectTracker.Outcome]
        var sceneCuts: [Double] = []
    }
    /// Injection boundary for deterministic identity, gap, cancellation and timestamp tests.
    struct Dependencies {
        var recognize: (Double) async throws -> Snapshot
        var follow: (Double, Double, [CGRect]) async throws -> Segment
        var detectCuts: ((Double, Double) async throws -> [Double])? = nil
    }
    enum TrackError: LocalizedError {
        case invalidInput, resourceLimit, invalidFrameTime
        var errorDescription: String? {
            switch self {
            case .invalidInput: return "추적할 문구와 영상 길이를 확인해 주세요."
            case .resourceLimit: return "문구 추적 결과가 너무 많습니다. 문구 수나 영상 길이를 줄여 주세요."
            case .invalidFrameTime: return "문구 검사 프레임의 시간을 확인하지 못했습니다."
            }
        }
    }
    /// OCR may briefly fail while the image tracker still follows the same target.
    /// Two seconds permits one missed one-second read, followed by reconfirmation.
    static let defaultRecognitionStep = 0.25
    static let maximumUnconfirmedDuration = 2.0
    static let maximumTracks = 512
    // Leaves room under the 20 MiB project-file cap for ordinary existing edits and metadata.
    // The controller still validates the complete combined project before applying the result.
    static let maximumKeyframes = 60_000
    static let maximumDuration = 6 * 60 * 60.0

    static func track(url: URL, duration: Double, phrases: [String],
                      cancellation: ObjectTracker.Cancellation,
                      recognizeLines: @escaping (CIImage) throws -> [AutoDetector.RecognizedLine] = AutoDetector.recognizedLines,
                      progress: @escaping (Double) -> Void) async throws -> Outcome {
        let source = try VideoProjectSourceBinding.Source.capture(url) { try check(cancellation) }
        let asset = VideoAssetPolicy.asset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw ObjectTracker.TrackError.noVideoTrack }
        let firstFrame = try await DocumentModel.firstVideoFrameTime(track: videoTrack, duration: duration)
        let (transform, nominalFrameRate) = try await videoTrack.load(.preferredTransform, .nominalFrameRate)
        let frameRate = Double(nominalFrameRate)
        let birthProbeStep = 1 / min(120, max(1, frameRate.isFinite && frameRate > 0 ? frameRate : 30))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // OCR stays detailed enough for small text; frame count and output memory are bounded separately.
        generator.maximumSize = CGSize(width: 1920, height: 1920)
        let cutScanner = try SceneCutScanner(asset: asset, track: videoTrack, cancellation: cancellation)
        let dependencies = Dependencies(recognize: { requested in
            try check(cancellation)
            try source.validateIdentity()
            let frame = try await generator.image(at: CMTime(seconds: max(firstFrame, requested), preferredTimescale: 60_000))
            return Snapshot(time: frame.actualTime.seconds, lines: try recognizeLines(CIImage(cgImage: frame.image)))
        }, follow: { start, end, boxes in
            try check(cancellation)
            try source.validateIdentity()
            let buffer = SharedFrameBuffer()
            let upper = CMTimeRangeGetEnd(ObjectTracker.forwardReadRange(from: start, until: end)).seconds
            let cuts = try cutScanner.cuts(from: start, until: end, frameUpperBound: upper) { time, image, byteCount in
                if time > start + 1.0 / 240 { buffer.append(time: time, image: image, byteCount: byteCount) }
            }
            if !cutScanner.captureComplete { buffer.discard() }
            let shared = buffer.frames.map { ObjectTracker.ForwardFrames(frames: $0,
                transform: transform, frameRate: nominalFrameRate) }
            var options = ObjectTracker.Options()
            options.smoothing = false
            options.reacquireFaces = false
            let outcomes = try await ObjectTracker.trackMany(url: url, from: start,
                until: cuts.first.map { max(start, $0 - 1.0 / 240) } ?? end,
                boxes: boxes, options: options, cancellation: cancellation, forwardFrames: shared, progress: { _ in })
            return Segment(outcomes: outcomes, sceneCuts: cuts)
        }, detectCuts: { start, end in
            try check(cancellation)
            try source.validateIdentity()
            return try cutScanner.cuts(from: start, until: end)
        })
        var result = try await track(duration: duration, phrases: phrases, cancellation: cancellation,
                                     dependencies: dependencies, recognitionStep: defaultRecognitionStep, birthProbeStep: birthProbeStep,
                                     terminalRecognitionTime: max(firstFrame, duration - birthProbeStep), progress: progress)
        if !result.cancelled {
            do {
                let dense = try await AutoDetector.refineTracks(url: url, target: .text,
                    tracks: result.tracks.map(\.samples), cancellation: cancellation, phrases: phrases)
                for index in result.tracks.indices { result.tracks[index].coverEvidence = dense[index] }
                try source.validate { try check(cancellation) }
            } catch is CancellationError {
                result.cancelled = true
            }
        }
        return result
    }

    static func track(duration: Double, phrases: [String], cancellation: ObjectTracker.Cancellation,
                      dependencies: Dependencies, recognitionStep: Double = 1, birthProbeStep: Double? = nil,
                      terminalRecognitionTime: Double? = nil,
                      progress: @escaping (Double) -> Void = { _ in }) async throws -> Outcome {
        let phrases = Array(Set(phrases.map(PhraseCover.normalize).filter { $0.count >= PhraseCover.minimumLength })).sorted()
        guard duration.isFinite, duration > 0, recognitionStep.isFinite, recognitionStep > 0, !phrases.isEmpty else { throw TrackError.invalidInput }
        if let birthProbeStep, !birthProbeStep.isFinite || birthProbeStep <= 0 { throw TrackError.invalidInput }
        if let terminalRecognitionTime, !terminalRecognitionTime.isFinite || terminalRecognitionTime < 0 || terminalRecognitionTime >= duration {
            throw TrackError.invalidInput
        }
        guard duration <= maximumDuration else { throw TrackError.resourceLimit }
        let schedule = PhraseCover.sampleTimes(duration: duration, step: recognitionStep)
        var readTimes = schedule.times
        // Observe the last source-frame period too. Holding the last quarter-second
        // OCR box can otherwise miss a moving label at the end of the video.
        if let terminalRecognitionTime, terminalRecognitionTime > (readTimes.last ?? 0) {
            readTimes.append(terminalRecognitionTime)
        }
        var tracks: [Track] = [], reviews: [ReviewInterval] = []
        var active: [Int] = []
        var lastConfirmed: [Int: Double] = [:]
        var lastConfirmedText: [Int: String] = [:]
        var keyframes = 0
        func result(_ cancelled: Bool) -> Outcome {
            Outcome(tracks: tracks, reviews: reviews, cancelled: cancelled, recognitionStep: schedule.step)
        }
        func review(_ index: Int, _ start: Double, _ end: Double, _ reason: ReviewReason) {
            guard end > start else { return }
            reviews.append(.init(trackID: tracks[index].id, start: start, end: end, reason: reason))
        }
        func add(_ hit: Hit, at time: Double) throws -> Int {
            guard tracks.count < maximumTracks, keyframes < maximumKeyframes else { throw TrackError.resourceLimit }
            tracks.append(Track(phrase: hit.phrase, samples: [.init(time: time, box: hit.box)], start: time, end: time,
                                coverEvidence: hit.evidence.map { [.init(time: time, points: $0, generousBox: hit.box)] } ?? []))
            keyframes += 1
            lastConfirmed[tracks.count - 1] = time
            lastConfirmedText[tracks.count - 1] = hit.recognizedText
            return tracks.count - 1
        }
        do {
            try check(cancellation)
            var current = try await dependencies.recognize(0)
            var previousRequested = 0.0
            try validate(current, duration: duration)
            for hit in hits(current.lines, phrases: phrases) { active.append(try add(hit, at: current.time)) }
            for requested in Array(readTimes.dropFirst()) + [duration] {
                try check(cancellation)
                let next: Snapshot?
                if requested < duration {
                    next = try await dependencies.recognize(requested)
                    try validate(next!, duration: duration)
                    // Low-rate media can return the same frame for adjacent requests.
                    guard next!.time >= current.time else { throw TrackError.invalidFrameTime }
                    if next!.time == current.time { continue }
                } else { next = nil }
                let end = next?.time ?? duration
                var remaining = next.map { hits($0.lines, phrases: phrases) } ?? []
                var continuing: [Int] = []
                var intervalCuts: [Double]? = nil
                let establishedTargets = active.map { (phrase: tracks[$0].phrase, box: tracks[$0].samples.last!.box) }
                if !active.isEmpty {
                    guard active.count <= ObjectTracker.maxTrackersPerPass else { throw TrackError.resourceLimit }
                    let boxes = active.map { tracks[$0].samples.last!.box }
                    let segment = try await dependencies.follow(current.time, end, boxes)
                    try check(cancellation)
                    intervalCuts = segment.sceneCuts
                    guard segment.outcomes.count == active.count else { throw TrackError.invalidInput }
                    for (index, outcome) in zip(active, segment.outcomes) {
                        if outcome.cancelled { return result(true) }
                        let cut = segment.sceneCuts.filter { $0 > current.time && $0 <= end }.min()
                        var samples = outcome.samples.filter {
                            $0.time.isFinite && $0.time > current.time && $0.time <= end && (cut == nil || $0.time < cut!)
                        }.sorted { $0.time < $1.time }
                        let anchor = tracks[index].samples.last!.box
                        let implausibleMotion = samples.contains { !plausibleTextMotion($0.box, from: anchor) }
                        let matchingReference = implausibleMotion ? anchor : (samples.last?.box ?? anchor)
                        let corroborating = remaining.filter {
                            $0.phrase == tracks[index].phrase && AutoDetector.overlap(matchingReference, $0.box) >= 0.25
                        }
                        let envelopeHit = corroborating.count == 1 && !active.contains(where: { other in
                            other != index && tracks[other].phrase == tracks[index].phrase
                                && AutoDetector.overlap(tracks[other].samples.last!.box, corroborating[0].box) >= 0.25
                        }) ? corroborating.first : nil
                        if implausibleMotion {
                            // Vision can latch onto a nearby person and turn a shallow
                            // subtitle into a tall portrait while still reporting confidence.
                            // Preserve the last OCR-established cover for this uncertain span;
                            // fresh OCR below may reanchor it, and the review stays visible.
                            let conservative = envelopeHit.map { anchor.union($0.box) } ?? anchor
                            samples = samples.map { .init(time: $0.time, box: conservative) }
                            review(index, current.time, end, .trackingLost)
                        } else if cut == nil, !outcome.lostTarget {
                            // Even a plausible tracker can drift one text row away. Preserve
                            // both OCR-established positions throughout this short segment,
                            // retaining raw motion as an additional conservative envelope.
                            let destination = envelopeHit?.box ?? anchor
                            let envelope = anchor.union(destination)
                            let needsReview = samples.contains { sample in
                                let fraction = min(1, max(0, (sample.time - current.time) / (end - current.time)))
                                let expectedX = anchor.midX + (destination.midX - anchor.midX) * fraction
                                let expectedY = anchor.midY + (destination.midY - anchor.midY) * fraction
                                let expectedHeight = anchor.height + (destination.height - anchor.height) * fraction
                                return hypot(sample.box.midX - expectedX, sample.box.midY - expectedY) > expectedHeight * 0.15
                                    || sample.box.width < min(anchor.width, destination.width) * 0.9
                                    || sample.box.height < min(anchor.height, destination.height) * 0.9
                            }
                            samples = samples.map { .init(time: $0.time, box: $0.box.union(envelope)) }
                            if needsReview { review(index, current.time, end, .trackingLost) }
                        }
                        guard keyframes + samples.count <= maximumKeyframes else { throw TrackError.resourceLimit }
                        tracks[index].samples += samples
                        keyframes += samples.count
                        tracks[index].end = end
                        if schedule.step > 1 { review(index, current.time, end, .samplingGap) }
                        if let cut {
                            review(index, cut, end, .sceneChange)
                        } else if outcome.lostTarget || samples.isEmpty {
                            review(index, tracks[index].samples.last!.time, end, .trackingLost)
                        } else if next != nil {
                            let last = matchingReference
                            let candidates = remaining.indices.filter { remaining[$0].phrase == tracks[index].phrase && AutoDetector.overlap(last, remaining[$0].box) >= 0.25 }
                            // Ambiguous duplicates remain separate instead of transferring a person's label.
                            let contested = candidates.first.map { candidate in
                                zip(active, segment.outcomes).contains { other, otherOutcome in
                                    guard other != index, tracks[other].phrase == tracks[index].phrase,
                                          !otherOutcome.lostTarget, let otherBox = otherOutcome.samples.last?.box else { return false }
                                    return AutoDetector.overlap(otherBox, remaining[candidate].box) >= 0.25
                                }
                            } ?? false
                            if candidates.count == 1 && !contested {
                                let hit = remaining.remove(at: candidates[0])
                                if tracks[index].samples.last!.time == end { tracks[index].samples.removeLast(); keyframes -= 1 }
                                guard keyframes < maximumKeyframes else { throw TrackError.resourceLimit }
                                tracks[index].samples.append(.init(time: end, box: hit.box)); keyframes += 1
                                if let evidence = hit.evidence {
                                    tracks[index].coverEvidence.append(.init(time: end, points: evidence, generousBox: hit.box))
                                }
                                lastConfirmed[index] = end
                                lastConfirmedText[index] = hit.recognizedText
                                continuing.append(index)
                            } else {
                                review(index, current.time, end, .textUnconfirmed)
                                // Absence of a read is not disappearance. Keep following only a
                                // healthy, unambiguous object for a bounded OCR recovery window.
                                // A reliable replacement line is positive evidence to stop; tiny
                                // partial/tiled reads and low-confidence OCR are only uncertainty.
                                let replacement = next!.lines.contains { line in
                                    let normalized = PhraseCover.normalize(line.text)
                                    return (line.confidence ?? 0) >= 0.9 && normalized.count >= 4
                                        && !PhraseCover.matches(line.text, phrases: phrases)
                                        && !(lastConfirmedText[index] ?? "").contains(normalized)
                                        && line.box.width >= last.width * 0.65
                                        && AutoDetector.overlap(last, PhraseCover.coverBox(line.box)) >= 0.65
                                }
                                if candidates.isEmpty, !replacement, !implausibleMotion,
                                   end - (lastConfirmed[index] ?? tracks[index].start) < maximumUnconfirmedDuration {
                                    continuing.append(index)
                                }
                            }
                        }
                    }
                }
                if let next {
                    var probes: [Double: Snapshot] = [:]
                    var probeCount = 0
                    let cuts: [Double]
                    if birthProbeStep != nil, !remaining.isEmpty {
                        if let intervalCuts { cuts = intervalCuts }
                        else if let detectCuts = dependencies.detectCuts { cuts = try await detectCuts(current.time, end) }
                        else { cuts = [] }
                    } else { cuts = [] }
                    for hit in remaining {
                        var firstTime = next.time
                        var firstHit = hit
                        var envelope = hit.box
                        if let birthProbeStep {
                            var lower = max(current.time, cuts.filter { $0 > current.time && $0 <= end }.max() ?? current.time)
                            var upper = next.time
                            var firstProbe = true
                            // Only positively decoded observations move the start earlier.
                            // One shared cache and budget bounds work when many hits are born.
                            while upper - lower > birthProbeStep {
                                try check(cancellation)
                                let nominalMidpoint = (previousRequested + requested) / 2
                                let probeTime = firstProbe && nominalMidpoint > lower && nominalMidpoint < upper
                                    ? nominalMidpoint : (lower + upper) / 2
                                firstProbe = false
                                let snapshot: Snapshot
                                if let cached = probes[probeTime] { snapshot = cached }
                                else {
                                    guard probeCount < 12 else { break }
                                    snapshot = try await dependencies.recognize(probeTime)
                                    try check(cancellation)
                                    try validate(snapshot, duration: duration)
                                    probes[probeTime] = snapshot
                                    probeCount += 1
                                }
                                // Match the current target's selected terms, not every input
                                // term: full-line and tiled OCR may read different additional
                                // wanted words in the same physical line.
                                let wanted = PhraseCover.parse(hit.phrase).phrases
                                let observed = hits(snapshot.lines, phrases: wanted)
                                let direct = observed.filter { AutoDetector.overlap($0.box, hit.box) >= 0.25 }
                                // The same sentence may also appear elsewhere on screen.
                                // A unique direct positional observation wins; semantic motion
                                // fallback is useful only when no direct observation exists.
                                let candidates = direct.isEmpty ? observed.filter {
                                    candidate in
                                    candidate.recognizedText == hit.recognizedText && plausibleBirthMotion(candidate.box, to: hit.box)
                                        && !establishedTargets.contains { established in
                                            !Set(PhraseCover.parse(established.phrase).phrases).isDisjoint(with: wanted)
                                                && AutoDetector.overlap(established.box, candidate.box) >= 0.25
                                        }
                                } : direct
                                if candidates.count == 1, snapshot.time > lower, snapshot.time < firstTime {
                                    firstTime = snapshot.time
                                    firstHit = candidates[0]
                                    envelope = envelope.union(firstHit.box)
                                    upper = probeTime
                                } else {
                                    // Requested brackets advance even if a low-rate decoder
                                    // repeats a neighboring frame; actualTime never invents proof.
                                    lower = probeTime
                                }
                            }
                        }
                        firstHit.box = envelope
                        firstHit.phrase = hit.phrase
                        let index = try add(firstHit, at: firstTime)
                        if firstTime < next.time {
                            guard keyframes < maximumKeyframes else { throw TrackError.resourceLimit }
                            tracks[index].samples.append(.init(time: next.time, box: hit.box))
                            tracks[index].end = next.time
                            keyframes += 1
                            lastConfirmed[index] = next.time
                            lastConfirmedText[index] = hit.recognizedText
                            if let evidence = hit.evidence {
                                tracks[index].coverEvidence.append(.init(time: next.time, points: evidence, generousBox: hit.box))
                            }
                            review(index, firstTime, next.time, .textUnconfirmed)
                        }
                        continuing.append(index)
                    }
                    current = next
                    previousRequested = requested
                }
                active = continuing
                progress(min(1, end / duration))
            }
            try check(cancellation)
            return result(false)
        } catch is CancellationError { return result(true) }
    }

    private static func plausibleBirthMotion(_ box: CGRect, to observed: CGRect) -> Bool {
        guard box.width > 0, box.height > 0, observed.width > 0, observed.height > 0 else { return false }
        let width = box.width / observed.width
        let height = box.height / observed.height
        return (0.5...2).contains(width) && (0.65...1.5).contains(height)
            && (0.5...2).contains(width / height)
            && hypot(box.midX - observed.midX, box.midY - observed.midY) <= 0.25
    }

    private static func plausibleTextMotion(_ box: CGRect, from anchor: CGRect) -> Bool {
        guard [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite),
              box.width > 0, box.height > 0, anchor.width > 0, anchor.height > 0 else { return false }
        let widthRatio = box.width / anchor.width
        let heightRatio = box.height / anchor.height
        let aspectRatio = widthRatio / heightRatio
        return (0.65...1.5).contains(widthRatio) && (0.65...1.5).contains(heightRatio)
            && (0.7...1.4).contains(aspectRatio)
            && hypot(box.midX - anchor.midX, box.midY - anchor.midY) <= max(anchor.width, anchor.height) * 0.75
    }

    private struct Hit { var phrase: String; var box: CGRect; var evidence: [CGPoint]?; var recognizedText: String }
    private static func hits(_ lines: [AutoDetector.RecognizedLine], phrases: [String]) -> [Hit] {
        var result: [Hit] = []
        for line in lines.sorted(by: { $0.box.width * $0.box.height > $1.box.width * $1.box.height }) {
            let matches = phrases.filter { PhraseCover.matches(line.text, phrases: [$0]) }
            guard !matches.isEmpty, line.box.width > 0, line.box.height > 0,
                  [line.box.minX, line.box.minY, line.box.width, line.box.height].allSatisfy(\.isFinite) else { continue }
            let hit = Hit(phrase: matches.joined(separator: ", "), box: PhraseCover.coverBox(line.box),
                          evidence: AutoDetector.phraseEvidence(line: line, phrases: matches),
                          recognizedText: PhraseCover.normalize(line.text))
            guard !result.contains(where: { existing in
                guard existing.phrase == hit.phrase else { return false }
                let intersection = existing.box.intersection(hit.box)
                let smallerArea = min(existing.box.width * existing.box.height, hit.box.width * hit.box.height)
                // Full-frame and tiled OCR can report a whole line and a contained
                // substring. They are one cover, even when their IoU is small.
                return AutoDetector.overlap(existing.box, hit.box) >= 0.65
                    || (!intersection.isNull && smallerArea > 0
                        && intersection.width * intersection.height / smallerArea >= 0.9)
            }) else { continue }
            result.append(hit)
        }
        return result
    }
    private static func validate(_ snapshot: Snapshot, duration: Double) throws {
        guard snapshot.time.isFinite, snapshot.time >= 0, snapshot.time < duration else { throw TrackError.invalidFrameTime }
    }
    private static func check(_ cancellation: ObjectTracker.Cancellation) throws {
        try Task.checkCancellation()
        if cancellation.isCancelled { throw CancellationError() }
    }

    /// Conservative hard-cut heuristic over every decoded frame. Flashes can also trigger a review;
    /// gradual transitions and visually similar cuts still require human review of the result.
    static func sceneCuts(url: URL, from start: Double, until end: Double,
                          cancellation: ObjectTracker.Cancellation) async throws -> [Double] {
        let asset = VideoAssetPolicy.asset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ObjectTracker.TrackError.noVideoTrack }
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60_000),
                                duration: CMTime(seconds: max(0.001, end - start), preferredTimescale: 60_000))
        return try SceneCutScanner(asset: asset, track: track, cancellation: cancellation, readRange: range)
            .cuts(from: start, until: end)
    }

    /// Retaining decoder buffers is cheaper than decoding twice, but must stay
    /// bounded on high-resolution or unusually long intervals. Overflow releases
    /// everything and selects the unchanged independent tracker reader.
    final class SharedFrameBuffer {
        private let maximumBytes: Int
        private let maximumFrames: Int
        private var bytes = 0
        private(set) var frames: [ObjectTracker.ForwardFrame]? = []
        init(maximumBytes: Int = 128 * 1024 * 1024, maximumFrames: Int = 64) {
            self.maximumBytes = maximumBytes; self.maximumFrames = maximumFrames
        }
        func discard() { frames = nil }
        func append(time: Double, image: CIImage, byteCount: Int? = nil) {
            guard frames != nil else { return }
            let area = image.extent.width * image.extent.height
            guard area.isFinite, area > 0, area <= CGFloat(Int.max / 4),
                  frames!.count < maximumFrames else { frames = nil; return }
            let size = byteCount ?? Int(ceil(area)) * 4
            guard size > 0, size <= maximumBytes - bytes else { frames = nil; return }
            bytes += size
            frames!.append(.init(time: time, image: image))
        }
    }

    /// One reader/context per phrase run. Each interval still compares exactly its own
    /// decoded frames, excluding the end boundary as AVAssetReader.timeRange does.
    /// Boundary samples are retained for tracking as well as the next interval,
    /// with explicit count/allocation caps. Overflow falls back to independent
    /// tracking and subsequent bounded reads, preserving all source frames.
    final class SceneCutScanner {
        private let reader: AVAssetReader
        private let output: AVAssetReaderTrackOutput
        private let context: CIContext
        private let asset: AVAsset
        private let track: AVAssetTrack
        private let canSwitchToBoundedReads: Bool
        private var usesBoundedReads = false
        private let maximumPendingFrames: Int
        private let maximumPendingBytes: Int
        /// False only when this call's requested look-ahead could not be retained.
        /// Its scene cuts are still complete; tracking must use its independent reader.
        private(set) var captureComplete = true
        /// Counts visited samples (including a retained boundary) for decoder-bound regression tests.
        private(set) var visitedFrameCount = 0
        private let space = CGColorSpaceCreateDeviceRGB()
        private let cancellation: ObjectTracker.Cancellation
        private var pending: [CMSampleBuffer] = []
        private var previousEnd = 0.0

        init(asset: AVAsset, track: AVAssetTrack, cancellation: ObjectTracker.Cancellation,
             readRange: CMTimeRange? = nil, context: CIContext? = nil,
             maximumPendingFrames: Int = 4, maximumPendingBytes: Int = 32 * 1024 * 1024) throws {
            try PhraseTracker.check(cancellation)
            self.cancellation = cancellation
            self.asset = asset
            self.track = track
            self.maximumPendingFrames = maximumPendingFrames
            self.maximumPendingBytes = maximumPendingBytes
            self.context = context ?? CIContext()
            canSwitchToBoundedReads = readRange == nil
            reader = try AVAssetReader(asset: asset)
            if let readRange { reader.timeRange = readRange }
            output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw ObjectTracker.TrackError.readFailed }
            reader.add(output)
            guard reader.startReading() else { throw ObjectTracker.TrackError.readFailed }
        }

        deinit { if reader.status == .reading { reader.cancelReading() } }

        func cuts(from start: Double, until end: Double, frameUpperBound: Double? = nil,
                  onFrame: ((Double, CIImage, Int) -> Void)? = nil) throws -> [Double] {
            try PhraseTracker.check(cancellation)
            guard start.isFinite, end.isFinite, start >= previousEnd, end > start,
                  frameUpperBound == nil || (frameUpperBound!.isFinite && frameUpperBound! >= end) else {
                throw TrackError.invalidInput
            }
            captureComplete = true
            // No active phrase may exist for minutes between calls. Seeking directly
            // to that interval avoids decoding the entire unused gap. Once discontinuous,
            // keep bounded interval readers while sharing this run's renderer and track.
            if usesBoundedReads || (canSwitchToBoundedReads && start - previousEnd > 1) {
                usesBoundedReads = true
                pending.removeAll(keepingCapacity: false)
                if reader.status == .reading { reader.cancelReading() }
                let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60_000),
                    duration: CMTime(seconds: max(end, frameUpperBound ?? end) - start, preferredTimescale: 60_000))
                let bounded = try SceneCutScanner(asset: asset, track: track, cancellation: cancellation,
                    readRange: range, context: context, maximumPendingFrames: maximumPendingFrames,
                    maximumPendingBytes: maximumPendingBytes)
                let cuts = try bounded.cuts(from: start, until: end, frameUpperBound: frameUpperBound, onFrame: onFrame)
                visitedFrameCount += bounded.visitedFrameCount
                captureComplete = bounded.captureComplete
                previousEnd = end
                return cuts
            }
            var previous: [UInt8]?
            var cuts: [Double] = []
            let captureUpper = max(end, frameUpperBound ?? end)
            var retained: [CMSampleBuffer] = []
            var retainedBytes = 0
            var stoppedForPendingLimit = false
            func next() -> CMSampleBuffer? {
                if !pending.isEmpty { return pending.removeFirst() }
                return output.copyNextSampleBuffer()
            }
            while let sample = next() {
                visitedFrameCount += 1
                try PhraseTracker.check(cancellation)
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard time.isFinite else { throw ObjectTracker.TrackError.readFailed }
                if time >= end {
                    let size = CMSampleBufferGetImageBuffer(sample).map(CVPixelBufferGetDataSize) ?? 0
                    guard retained.count < maximumPendingFrames, size > 0,
                          size <= maximumPendingBytes - retainedBytes else {
                        // Cuts only compare frames before `end`, which have all
                        // been consumed. Recover future intervals by seeking rather
                        // than dropping any of these unretained boundary samples.
                        captureComplete = false
                        stoppedForPendingLimit = true
                        usesBoundedReads = true
                        retained.removeAll(keepingCapacity: false)
                        pending.removeAll(keepingCapacity: false)
                        if reader.status == .reading { reader.cancelReading() }
                        break
                    }
                    retainedBytes += size
                    retained.append(sample)
                    if time >= captureUpper { break }
                    if let pixels = CMSampleBufferGetImageBuffer(sample) { onFrame?(time, CIImage(cvPixelBuffer: pixels), CVPixelBufferGetDataSize(pixels)) }
                    continue
                }
                guard time >= start, let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
                let image = CIImage(cvPixelBuffer: pixels)
                onFrame?(time, image, CVPixelBufferGetDataSize(pixels))
                let thumb = image.transformed(by: CGAffineTransform(scaleX: 16 / image.extent.width, y: 16 / image.extent.height))
                var bytes = [UInt8](repeating: 0, count: 16 * 16 * 4)
                context.render(thumb, toBitmap: &bytes, rowBytes: 16 * 4,
                    bounds: CGRect(x: 0, y: 0, width: 16, height: 16), format: .RGBA8, colorSpace: space)
                if let previous {
                    let difference = zip(previous, bytes).enumerated().filter { $0.offset % 4 != 3 }
                        .reduce(0.0) { $0 + abs(Double($1.element.0) - Double($1.element.1)) } / Double(16 * 16 * 3 * 255)
                    if difference > 0.30 { cuts.append(time) }
                }
                previous = bytes
            }
            pending = retained + pending
            try PhraseTracker.check(cancellation)
            guard reader.status != .failed, (reader.status != .cancelled || stoppedForPendingLimit), previous != nil else {
                throw ObjectTracker.TrackError.readFailed
            }
            previousEnd = end
            return cuts
        }
    }
}
