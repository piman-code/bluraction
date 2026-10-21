import Foundation
import CoreGraphics
import CoreImage

/// Running finds (faces/text, phrases, phrase tracking, person), the latest find's areas, and the
/// injected detectors, plus the background work each find runs. It holds no reference to the
/// editor; the editor locks the UI, checks the result still belongs to the screen it was looked
/// for on, and places the covers.
@MainActor
final class FindCoordinator {
    typealias TrackPhrases = (URL, Double, [String], ObjectTracker.Cancellation,
                              @escaping (CIImage) throws -> [AutoDetector.RecognizedLine],
                              @escaping (Double) -> Void) async throws -> PhraseTracker.Outcome

    /// Where a find looked: a result is only placed if the screen still shows this.
    struct FindContext: Equatable {
        let url: URL?
        let page: Int?
        let time: Double?
        static func == (a: FindContext, b: FindContext) -> Bool {
            a.url == b.url && a.page == b.page && (a.time == nil) == (b.time == nil)
                && abs((a.time ?? 0) - (b.time ?? 0)) < MotionTrack.sameTime
        }
    }

    /// Areas the latest find created, and the document and page it ran on. Areas copied to other
    /// pages keep their ids, so the buttons only act on the page the find ran on.
    var lastFound: (ids: [UUID], url: URL?, page: Int?) = ([], nil, nil)
    /// The running find, so 취소 or closing the window can stop it.
    var findTask: Task<Result<[AutoDetector.Detection], Error>, Never>?
    var phraseTask: Task<Result<[PhraseCover.Span], Error>, Never>?
    var phraseTrackingTask: Task<Result<PhraseTracker.Outcome, Error>, Never>?
    var phraseTrackingCancellation: ObjectTracker.Cancellation?

    /// Detector used by 자동 찾기; tests replace it (real face images are not used in tests).
    var autoDetect: (AutoDetector.Target, CIImage) throws -> [CGRect] = AutoDetector.detect {
        didSet { autoDetectDetailed = nil } // Preserve legacy injection without fabricating evidence.
    }
    var autoDetectDetailed: ((AutoDetector.Target, CIImage) throws -> [AutoDetector.Detection])? = AutoDetector.detectDetailed
    /// Reader used by 문구 가리기; tests replace it with fixed text.
    var recognizeLines: (CIImage) throws -> [AutoDetector.RecognizedLine] = AutoDetector.recognizedLines
    /// Tests may supply authored tracking observations while the production path uses Vision.
    var trackPhrases: TrackPhrases = {
        try await PhraseTracker.track(url: $0, duration: $1, phrases: $2, cancellation: $3,
                                      recognizeLines: $4, progress: $5)
    }
    /// Person under a point on a frame (Vision); tests replace it because synthetic frames have no people.
    var findPersonBox: (CIImage, CGPoint) throws -> CGRect? = AutoDetector.personBox

    /// Stops every running find (the window is closing).
    func cancelAll() {
        findTask?.cancel()
        phraseTask?.cancel()
        phraseTrackingTask?.cancel()
        phraseTrackingCancellation?.cancel()
    }

    /// The latest find's areas that still exist (`present`) on the document and page it ran on, in creation order.
    func foundIDs(url: URL?, page: Int?, present: Set<UUID>) -> [UUID] {
        guard lastFound.url == url, lastFound.page == page else { return [] }
        return lastFound.ids.filter(present.contains)
    }

    /// Looks for faces or text in a still image or a video frame, off the main actor. Becomes `findTask`.
    func startDetection(_ target: AutoDetector.Target, still: CGImage?, url: URL?,
                        time: Double?) -> Task<Result<[AutoDetector.Detection], Error>, Never> {
        let detect = autoDetect
        let detailed = autoDetectDetailed
        let task = Task.detached(priority: .userInitiated) { () -> Result<[AutoDetector.Detection], Error> in
            do {
                let image: CIImage
                if let still { image = CIImage(cgImage: still) }
                else if let url, let time { image = try await AutoDetector.frame(of: url, at: time) }
                else { throw AutoDetector.DetectError.frameUnavailable }
                try Task.checkCancellation()
                let found = try detailed?(target, image) ?? detect(target, image).map {
                    AutoDetector.Detection(generousBox: $0, target: target, evidencePoints: [], reliable: false)
                }
                try Task.checkCancellation()
                return .success(found)
            } catch { return .failure(error) }
        }
        findTask = task
        return task
    }

    /// Reads `phrases` at each sample time (a still image is read once), off the main actor. Becomes `phraseTask`.
    func startPhraseSearch(_ phrases: [String], still: CGImage?, url: URL?,
                           sampling: (times: [Double], step: Double), duration: Double,
                           report: @escaping @MainActor (Int, Int) -> Void) -> Task<Result<[PhraseCover.Span], Error>, Never> {
        let recognize = recognizeLines
        let task = Task.detached(priority: .userInitiated) { () -> Result<[PhraseCover.Span], Error> in
            do {
                var samples: [(time: Double, hits: [CGRect])] = []
                for (index, time) in sampling.times.enumerated() {
                    try Task.checkCancellation()
                    let image: CIImage
                    if let still { image = CIImage(cgImage: still) }
                    else if let url { image = try await AutoDetector.frame(of: url, at: time) }
                    else { throw AutoDetector.DetectError.frameUnavailable }
                    let lines = try recognize(image)
                    let hits = lines.filter { PhraseCover.matches($0.text, phrases: phrases) }.map { PhraseCover.coverBox($0.box) }
                    samples.append((time, hits))
                    await report(index + 1, sampling.times.count)
                }
                try Task.checkCancellation()
                // A still image has one sample: each hit is simply a place to cover.
                if let still {
                    let lines = try recognize(CIImage(cgImage: still))
                    return .success(lines.filter { PhraseCover.matches($0.text, phrases: phrases) }.map {
                        PhraseCover.Span(box: PhraseCover.coverBox($0.box), start: 0, end: 0,
                                         evidencePoints: AutoDetector.phraseEvidence(line: $0, phrases: phrases))
                    })
                }
                return .success(PhraseCover.spans(samples: samples, step: sampling.step, duration: duration))
            } catch { return .failure(error) }
        }
        phraseTask = task
        return task
    }

    /// Finds and follows `phrases` through a video, off the main actor. Sets `phraseTrackingCancellation`
    /// and `phraseTrackingTask`; returns both.
    func startPhraseTracking(_ phrases: [String], url: URL, duration: Double,
                             report: @escaping (Double) -> Void)
        -> (task: Task<Result<PhraseTracker.Outcome, Error>, Never>, cancellation: ObjectTracker.Cancellation) {
        let recognize = recognizeLines, run = trackPhrases
        let cancellation = ObjectTracker.Cancellation()
        phraseTrackingCancellation = cancellation
        let task = Task.detached(priority: .userInitiated) { () -> Result<PhraseTracker.Outcome, Error> in
            do { return .success(try await run(url, duration, phrases, cancellation, recognize, report)) }
            catch { return .failure(error) }
        }
        phraseTrackingTask = task
        return (task, cancellation)
    }

    /// The person's box under a normalized point on a video frame, off the main actor.
    func startPersonSearch(url: URL, time: Double, point: CGPoint) -> Task<Result<CGRect?, Error>, Never> {
        let find = findPersonBox
        return Task.detached(priority: .userInitiated) { () -> Result<CGRect?, Error> in
            do {
                let image = try await AutoDetector.frame(of: url, at: time)
                try Task.checkCancellation()
                return .success(try find(image, point))
            } catch { return .failure(error) }
        }
    }
}
