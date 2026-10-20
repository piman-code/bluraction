import CoreGraphics
import Testing
@testable import BlurAction

@Suite
struct AutoDetectionEvidenceTests {
    private func quad(_ x: CGFloat, _ y: CGFloat = 0.2, width: CGFloat = 0.04) -> [CGPoint] {
        [.init(x: x, y: y), .init(x: x + width, y: y),
         .init(x: x + width, y: y + 0.08), .init(x: x, y: y + 0.08)]
    }
    private func line(_ text: String, confidence: Float = 0.95) -> AutoDetector.RecognizedLine {
        let fragments = text.enumerated().map { index, character in
            AutoDetector.RecognizedFragment(text: String(character), quad: quad(0.1 + CGFloat(index) * 0.05))
        }
        return .init(text: text, box: .init(x: 0.1, y: 0.2, width: CGFloat(text.count) * 0.05, height: 0.08),
                     quad: quad(0.1, width: CGFloat(text.count) * 0.05), confidence: confidence, fragments: fragments)
    }

    @Test func legacyInjectedLinesKeepNoEvidenceAndWholeLineFallback() {
        let legacy = AutoDetector.RecognizedLine(text: "학생 A 이름", box: .init(x: 0.1, y: 0.2, width: 0.5, height: 0.1))
        #expect(AutoDetector.phraseEvidence(line: legacy, phrases: ["학생A"]) == nil)
        #expect(legacy.quad == nil && legacy.confidence == nil && legacy.fragments.isEmpty)
    }

    @Test func normalizedMatchingUsesObservedCharactersNotProportionalLineSlicing() throws {
        let recognized = line("학생-A 이름")
        let points = try #require(AutoDetector.phraseEvidence(line: recognized, phrases: ["학생 a"]))
        #expect(points == recognized.fragments[0].quad + recognized.fragments[1].quad + recognized.fragments[3].quad)
        #expect(points.map(\.x).max()! < recognized.box.maxX)
    }

    @Test func everyRepeatedOccurrenceIsCoveredAndMultiplePhrasesAreCombined() throws {
        let recognized = line("AB AB CD")
        let points = try #require(AutoDetector.phraseEvidence(line: recognized, phrases: ["ab", "cd"]))
        #expect(points.count == 24)
        #expect(points.contains(recognized.fragments[7].quad[2]))
    }

    @Test func missingOrWeakCharacterEvidenceNeverSilentlyDropsMatchedCharacters() {
        var recognized = line("AB CD")
        recognized.fragments[1].quad = []
        #expect(AutoDetector.phraseEvidence(line: recognized, phrases: ["ab"]) == nil)
        #expect(AutoDetector.phraseEvidence(line: line("AB", confidence: 0.4), phrases: ["ab"]) == nil)
        recognized = line("AB")
        recognized.fragments.removeLast()
        #expect(AutoDetector.phraseEvidence(line: recognized, phrases: ["ab"]) == nil)
    }

    @Test func wholeLineEvidenceAllowedOnlyForExactNormalizedLine() {
        var recognized = line("AB CD")
        recognized.fragments = []
        #expect(AutoDetector.phraseEvidence(line: recognized, phrases: ["ABCD"]) == recognized.quad)
        #expect(AutoDetector.phraseEvidence(line: recognized, phrases: ["AB"]) == nil)
    }

    @Test func malformedOrOutOfFrameQuadrilateralsAreRejected() {
        #expect(!AutoDetector.validQuad([.zero, .zero, .zero, .zero]))
        #expect(!AutoDetector.validQuad(quad(-0.1)))
        #expect(!AutoDetector.validQuad([.init(x: CGFloat.nan, y: 0), .zero, .zero, .zero]))
        #expect(AutoDetector.validQuad(quad(0.2)))
    }

    @Test func trackerEvidenceExistsOnlyAtDecodedOCRAnchorsAndBoxesStayLegacy() async throws {
        let recognized = line("AB CD")
        let cover = PhraseCover.coverBox(recognized.box)
        let dependencies = PhraseTracker.Dependencies(recognize: { requested in
            .init(time: requested, lines: [recognized])
        }, follow: { start, end, boxes in
            .init(outcomes: boxes.map { box in
                .init(samples: [.init(time: start + 0.5, box: box), .init(time: end, box: box)],
                      lostTarget: false, cancelled: false)
            })
        })
        let outcome = try await PhraseTracker.track(duration: 2, phrases: ["AB"], cancellation: .init(), dependencies: dependencies)
        let track = try #require(outcome.tracks.first)
        #expect(outcome.tracks.count == 1)
        #expect(track.samples.allSatisfy { $0.box == cover })
        #expect(track.samples.map(\.time) == [0, 0.5, 1, 1.5, 2])
        #expect(track.coverEvidence.map(\.time) == [0, 1])
        #expect(track.coverEvidence.allSatisfy { $0.generousBox == cover && $0.points.count == 8 })
    }
}
