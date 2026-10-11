import AppKit
import CoreImage
import CoreText
import Foundation
import Testing
@testable import BlurAction

/// 문구 가리기: pure matching and span logic, real text recognition on a rendered line, and the editor flow.
@Suite(.serialized)
struct PhraseCoverTests {
    // MARK: Pure logic

    @Test
    func phrasesAreParsedAndShortOnesCounted() {
        let parsed = PhraseCover.parse("홍길동, 010-1234 ,a, 홍길동,\nBlur")
        #expect(parsed.phrases == ["홍길동", "0101234", "blur"])
        #expect(parsed.tooShort == 1)
        #expect(PhraseCover.parse("  , ,\n").phrases.isEmpty)
    }

    @Test
    func matchingIgnoresCaseSpacingAndPunctuation() {
        #expect(PhraseCover.matches("Hong Gil-dong 010", phrases: ["honggildong"]), "Spaces and dashes do not block a match")
        #expect(PhraseCover.matches("홍 길 동!", phrases: ["홍길동"]))
        #expect(PhraseCover.matches("ID: BLUR-01", phrases: ["blur01"]))
        #expect(PhraseCover.matches("nothing here", phrases: ["blur"]) == false)
    }

    @Test
    func hitsOnConsecutiveSamplesFormOneSpan() {
        let box = CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.05)
        let samples = (0..<4).map { (time: Double($0), hits: [box]) }
        let spans = PhraseCover.spans(samples: samples, step: 1, duration: 10)
        #expect(spans.count == 1)
        #expect(spans[0].start == 0)
        #expect(spans[0].end == 4, "On screen until the next sample would have shown it gone")
        #expect(abs(spans[0].box.minX - box.minX) < 1e-9 && abs(spans[0].box.maxY - box.maxY) < 1e-9, "The union keeps the same place")
    }

    @Test
    func aOneSampleMissDoesNotSplitTheSpanButTwoDo() {
        let box = CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.05)
        let brief = [(0.0, [box]), (1.0, []), (2.0, [box])].map { (time: $0.0, hits: $0.1) }
        #expect(PhraseCover.spans(samples: brief, step: 1, duration: 10).count == 1)
        let gone = [(0.0, [box]), (1.0, []), (2.0, []), (3.0, [box])].map { (time: $0.0, hits: $0.1) }
        let split = PhraseCover.spans(samples: gone, step: 1, duration: 10)
        #expect(split.count == 2)
        #expect(split[0].end == 1 && split[1].start == 3)
    }

    @Test
    func aMovingPhraseKeepsOneSpanCoveringItsPath() {
        let samples = (0..<5).map { i in
            (time: Double(i), hits: [CGRect(x: 0.1 + Double(i) * 0.05, y: 0.4, width: 0.2, height: 0.05)])
        }
        let spans = PhraseCover.spans(samples: samples, step: 1, duration: 10)
        #expect(spans.count == 1, "Each step overlaps the last box, so it stays one span")
        #expect(spans[0].box.minX <= 0.1 + 1e-9 && spans[0].box.maxX >= 0.3 + 0.2 - 1e-9)
    }

    @Test
    func twoPlacesAtOnceAreTwoSpans() {
        let left = CGRect(x: 0.05, y: 0.2, width: 0.2, height: 0.05)
        let right = CGRect(x: 0.7, y: 0.6, width: 0.2, height: 0.05)
        let spans = PhraseCover.spans(samples: [(0, [left, right]), (1, [left, right])], step: 1, duration: 5)
        #expect(spans.count == 2)
    }

    @Test
    func spansNeverPassTheVideoEnd() {
        let box = CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.05)
        let spans = PhraseCover.spans(samples: [(time: 9, hits: [box])], step: 1, duration: 9.5)
        #expect(spans.first?.end == 9.5)
    }

    @Test
    func longVideosAreSampledMoreCoarsely() {
        let short = PhraseCover.sampleTimes(duration: 10, step: 1)
        #expect(short.times == (0..<10).map(Double.init))
        #expect(short.step == 1)
        let long = PhraseCover.sampleTimes(duration: 6000, step: 1)
        #expect(long.times.count == PhraseCover.maximumSamples)
        #expect(abs(long.step - 10) < 1e-9)
    }

    @Test
    func coversArePaddedAndNeverTiny() {
        let thin = PhraseCover.coverBox(CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.001))
        #expect(thin.height >= 0.0101 - 1e-9 && thin.width >= 0.1)
        let edge = PhraseCover.coverBox(CGRect(x: 0.95, y: 0.95, width: 0.05, height: 0.05))
        #expect(edge.maxX <= 1 + 1e-9 && edge.maxY <= 1 + 1e-9)
    }

    // MARK: Real recognition

    /// Text drawn on a white canvas, read by Vision: the phrase must come back as a line.
    @Test
    func aRenderedPhraseIsReadAndCoveredWhereItIs() throws {
        let width = 900, height = 300
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = NSFont.systemFont(ofSize: 96, weight: .bold)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "BLUR 1234", attributes: [.font: font, .foregroundColor: NSColor.black]))
        context.textPosition = .zero
        let bounds = CTLineGetImageBounds(line, context)
        context.textPosition = CGPoint(x: 80 - bounds.minX, y: 100 - bounds.minY)
        CTLineDraw(line, context)
        let image = CIImage(cgImage: try #require(context.makeImage()))
        let lines = try AutoDetector.recognizedLines(in: image)
        let phrase = try #require(lines.first { PhraseCover.matches($0.text, phrases: ["blur1234"]) }, "Vision reads the phrase: \(lines.map(\.text))")
        // The cover lands where the text is (normalized, bottom-left origin).
        let cover = PhraseCover.coverBox(phrase.box)
        #expect(cover.midX > 0.05 && cover.midX < 0.6, "Left part of the frame: \(cover)")
        #expect(cover.midY > 0.2 && cover.midY < 0.7)
    }

    // MARK: Editor flow

    @MainActor
    @Test
    func aStillImagePhraseBecomesOneUndoableCoverPerPlace() async throws {
        let session = try await ImageSession.open()
        defer { session.close() }
        let controller = session.controller
        controller.recognizeLines = { _ in [AutoDetector.RecognizedLine(text: "홍길동 010", box: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.1))] }
        let before = session.canvas.regionsBinding?().count ?? 0
        controller.findPhrases("홍길동")
        try await waitUntil { !controller.isExporting }
        let after = session.canvas.regionsBinding?().count ?? 0
        #expect(after == before + 1)
        controller.perform(NSSelectorFromString("undoTapped"))
        #expect((session.canvas.regionsBinding?().count ?? 0) == before, "One undo removes the whole find")
    }

    @MainActor
    @Test
    func aVideoPhraseCoversOnlyWhileItIsOnScreen() async throws {
        let session = try await VideoSession.open()
        defer { session.close() }
        let controller = session.controller
        // Video of 6 seconds is read once a second: hits on samples 1, 2 and 3 only.
        let calls = CallCounter()
        controller.recognizeLines = { _ in
            let index = calls.next()
            return index >= 1 && index <= 3 ? [AutoDetector.RecognizedLine(text: "홍길동", box: CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.1))] : []
        }
        controller.findPhrases("홍길동")
        try await waitUntil { !controller.isExporting }
        let saved = try VideoProjectFile.decode(controller.projectData(producerVersion: "test.phrase"))
        let region = try #require(saved.payload.regions.first, "One place, one cover")
        #expect(saved.payload.regions.count == 1)
        #expect(abs(region.effect.timeRange.lowerBound - 1) < 1e-6, "Starts with the first sample that shows it: \(region.effect.timeRange)")
        #expect(abs(region.effect.timeRange.upperBound - 4) < 1e-6, "Ends one step after the last: \(region.effect.timeRange)")
    }

    @MainActor
    @Test
    func aPhraseThatIsNotThereAddsNothing() async throws {
        let session = try await ImageSession.open()
        defer { session.close() }
        let controller = session.controller
        controller.recognizeLines = { _ in [] }
        let before = session.canvas.regionsBinding?().count ?? 0
        controller.findPhrases("없는문구")
        try await waitUntil { !controller.isExporting }
        #expect((session.canvas.regionsBinding?().count ?? 0) == before)
    }
}

/// Counts sample reads for the recognizer stub (reads happen one after another).
private final class CallCounter: @unchecked Sendable {
    private var count = 0
    func next() -> Int { defer { count += 1 }; return count }
}
