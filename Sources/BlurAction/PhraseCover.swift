import CoreGraphics
import Foundation

/// Covers every on-screen place where a listed phrase is read, for as long as it is on screen.
/// Pure logic: matching, and joining per-sample hits into time spans. Recognition lives in AutoDetector.
enum PhraseCover {
    /// A place where one phrase stays on screen: its union box (normalized, bottom-left) and time span.
    struct Span: Equatable {
        var box: CGRect
        var start: Double
        var end: Double
    }

    /// Minimum normalized length: one character would match almost everything.
    static let minimumLength = 2
    /// Samples a hit may be missing from before its span ends (brief recognition misses).
    static let allowedMisses = 1
    /// Largest number of samples per video; longer videos are sampled more coarsely.
    static let maximumSamples = 600

    /// Lowercased letters and digits only, so spacing and punctuation do not block a match.
    static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Comma- or line-separated phrases. Returns the usable phrases and how many were too short.
    static func parse(_ input: String) -> (phrases: [String], tooShort: Int) {
        var phrases: [String] = []
        var tooShort = 0
        for raw in input.split(whereSeparator: { $0 == "," || $0 == "\n" }) {
            let phrase = normalize(String(raw))
            guard !phrase.isEmpty else { continue }
            if phrase.count < minimumLength { tooShort += 1; continue }
            if !phrases.contains(phrase) { phrases.append(phrase) }
        }
        return (phrases, tooShort)
    }

    /// Whether recognized text contains one of the phrases (both normalized).
    static func matches(_ text: String, phrases: [String]) -> Bool {
        let normal = normalize(text)
        return phrases.contains { !$0.isEmpty && normal.contains($0) }
    }

    /// Joins hits from consecutive samples into spans. A hit continues a span when its box overlaps the
    /// span's latest box; a span survives `allowedMisses` samples without a hit. `times` must ascend.
    static func spans(samples: [(time: Double, hits: [CGRect])], step: Double, duration: Double) -> [Span] {
        var open: [(span: Span, misses: Int, last: CGRect)] = []
        var closed: [Span] = []
        for sample in samples {
            var unmatched = sample.hits
            var stillOpen: [(span: Span, misses: Int, last: CGRect)] = []
            for var track in open {
                // The best overlapping hit continues this span; each hit joins at most one span.
                let best = unmatched.indices
                    .map { ($0, AutoDetector.overlap(unmatched[$0], track.last)) }
                    .filter { $0.1 >= 0.3 }
                    .max { $0.1 < $1.1 }
                if let (index, _) = best {
                    let box = unmatched.remove(at: index)
                    track.span.box = track.span.box.union(box)
                    track.span.end = sample.time
                    track.last = box
                    track.misses = 0
                    stillOpen.append(track)
                } else if track.misses < allowedMisses {
                    track.misses += 1
                    stillOpen.append(track)
                } else {
                    closed.append(track.span)
                }
            }
            for box in unmatched {
                stillOpen.append((Span(box: box, start: sample.time, end: sample.time), 0, box))
            }
            open = stillOpen
        }
        closed += open.map(\.span)
        // A span is on screen until the next sample would have shown it gone, within the video.
        return closed.map { span in
            var extended = span
            extended.end = min(duration, span.end + step)
            return extended
        }.sorted { $0.start < $1.start }
    }

    /// The cover for one recognized line: padded like the text finder, and never smaller than the finder's floor.
    static func coverBox(_ box: CGRect) -> CGRect {
        box.insetBy(dx: -box.height * 0.25, dy: -box.height * 0.25).clampedToUnit.grown(toAtLeast: 0.0101)
    }

    /// Sample times across the video: one per `step`, coarser when the video is very long.
    static func sampleTimes(duration: Double, step: Double) -> (times: [Double], step: Double) {
        guard duration.isFinite, duration > 0, step.isFinite, step > 0 else { return ([0], 0) }
        let fitted = max(step, duration / Double(maximumSamples))
        let count = Int((duration / fitted).rounded(.up))
        return ((0..<max(1, count)).map { Double($0) * fitted }, fitted)
    }
}
