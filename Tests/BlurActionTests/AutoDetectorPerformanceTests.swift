import CoreImage
import CoreText
import Foundation
import Testing
@testable import BlurAction

@Suite(.serialized)
struct AutoDetectorPerformanceTests {
    private final class Counter: @unchecked Sendable {
        let lock = NSLock()
        var live = 0, peak = 0, calls = 0
        func enter() { lock.lock(); live += 1; calls += 1; peak = max(peak, live); lock.unlock() }
        func leave() { lock.lock(); live -= 1; lock.unlock() }
    }

    @Test func tileBatchesStayBoundedPreserveEveryPassAndOriginalOrder() throws {
        let counter = Counter()
        let images = (0..<5).map { CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 100 + $0, height: 40)) }
        let lines = try AutoDetector.parallelRecognizedPasses(images) { image in
            counter.enter(); defer { counter.leave() }
            // Force different completion order without changing the returned order.
            Thread.sleep(forTimeInterval: Int(image.extent.width) % 2 == 0 ? 0.02 : 0.001)
            return [.init(text: String(Int(image.extent.width)), box: CGRect(x: 0, y: 0, width: 1, height: 1))]
        }
        #expect(counter.calls == 5)
        #expect(counter.peak <= 2)
        #expect(counter.live == 0)
        #expect(lines.map { $0.first!.text } == ["100", "101", "102", "103", "104"])
    }

    @Test func parallelErrorsKeepInputOrderAndDoNotStartFurtherBatches() throws {
        enum Failure: Error, Equatable { case pass(Int) }
        let counter = Counter()
        let images = (0..<4).map { CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 100 + $0, height: 40)) }
        #expect(throws: Failure.pass(100)) {
            try AutoDetector.parallelRecognizedPasses(images) { image in
                counter.enter(); defer { counter.leave() }
                if image.extent.width == 100 { Thread.sleep(forTimeInterval: 0.02) }
                throw Failure.pass(Int(image.extent.width))
            }
        }
        #expect(counter.calls == 2)
        #expect(counter.live == 0)
    }

    private func waitForStart(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now() + 5) == .success
    }

    @Test func cancellationDuringBatchStopsBeforePublishingOrStartingNextBatch() async throws {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let counter = Counter()
        let images = Array(repeating: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 40)), count: 4)
        let task = Task.detached {
            try AutoDetector.parallelRecognizedPasses(images) { _ in
                counter.enter(); defer { counter.leave() }
                started.signal()
                release.wait()
                return []
            }
        }
        #expect(waitForStart(started))
        task.cancel()
        release.signal(); release.signal()
        do { _ = try await task.value; Issue.record("Cancelled tile batch published results") }
        catch { #expect(error is CancellationError) }
        #expect(counter.calls <= 2)
        #expect(counter.live == 0)
    }

    @Test func fastCompletionReplenishesSlotBeforeSlowFirstPassFinishes() async throws {
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let firstFinished = DispatchSemaphore(value: 0)
        let thirdStarted = DispatchSemaphore(value: 0)
        let counter = Counter()
        let images = (0..<5).map {
            CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 100 + $0, height: 40))
        }
        let task = Task.detached {
            try AutoDetector.parallelRecognizedPasses(images) { image in
                counter.enter(); defer { counter.leave() }
                let index = Int(image.extent.width) - 100
                if index == 0 {
                    firstStarted.signal()
                    // A broken scheduler must fail the bounded test, not strand work.
                    guard releaseFirst.wait(timeout: .now() + 10) == .success else {
                        throw AutoDetector.DetectError.visionFailed
                    }
                    firstFinished.signal()
                }
                if index == 2 { thirdStarted.signal() }
                return [.init(text: String(index), box: CGRect(x: 0, y: 0, width: 1, height: 1))]
            }
        }
        #expect(waitForStart(firstStarted))
        #expect(waitForStart(thirdStarted))
        #expect(firstFinished.wait(timeout: .now()) == .timedOut)
        releaseFirst.signal()
        let lines = try await task.value
        #expect(lines.map { $0.first!.text } == ["0", "1", "2", "3", "4"])
        #expect(counter.calls == 5)
        #expect(counter.peak <= 2)
        #expect(counter.live == 0)
    }

    @Test func nativeParallelPassesMatchSerialRecognizedTextAndGeometry() throws {
        let context = try #require(CGContext(data: nil, width: 640, height: 120, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 640, height: 120))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 44, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]
        context.textPosition = CGPoint(x: 25, y: 40)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "BLUR 1234", attributes: attributes)), context)
        let image = CIImage(cgImage: try #require(context.makeImage()))
        let images = Array(repeating: image, count: 4)
        let serial = try images.map { try AutoDetector.recognizedLines(in: $0) }
        let parallel = try AutoDetector.parallelRecognizedPasses(images, pass: AutoDetector.recognizedLines)
        #expect(!serial[0].isEmpty)
        #expect(serial.map { $0.map(\.text) } == parallel.map { $0.map(\.text) })
        #expect(serial.map { $0.map(\.box) } == parallel.map { $0.map(\.box) })
        #expect(serial.map { $0.map(\.quad) } == parallel.map { $0.map(\.quad) })
        #expect(serial.map { $0.map(\.confidence) } == parallel.map { $0.map(\.confidence) })
        #expect(serial.map { $0.map { $0.fragments.map(\.quad) } } == parallel.map { $0.map { $0.fragments.map(\.quad) } })
        #expect(serial.map { $0.map { $0.fragments.map(\.text) } } == parallel.map { $0.map { $0.fragments.map(\.text) } })
    }

    @Test func nativeWholeAndFourTilesMatchOriginalSerialScheduleExactly() throws {
        let context = try #require(CGContext(data: nil, width: 1280, height: 720, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1280, height: 720))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString, 40, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]
        for (text, point) in [("얼굴 FACE 123", CGPoint(x: 40, y: 560)),
                              ("학부모 PARENT", CGPoint(x: 700, y: 560)),
                              ("안내문 NOTICE", CGPoint(x: 40, y: 180)),
                              ("얼굴 학부모 안내문", CGPoint(x: 700, y: 180))] {
            context.textPosition = point
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
        }
        // A nonzero source origin also guards the original tile-to-frame transform.
        let image = CIImage(cgImage: try #require(context.makeImage()))
            .transformed(by: CGAffineTransform(translationX: 13, y: 27))
        let whole = image.extent
        let width = whole.width / 2, height = whole.height / 2
        var serial = try AutoDetector.recognizedPass(image)
        for column in 0..<2 {
            for row in 0..<2 {
                let tile = CGRect(x: whole.minX + CGFloat(column) * width - width * 0.1,
                                  y: whole.minY + CGFloat(row) * height - height * 0.1,
                                  width: width * 1.2, height: height * 1.2).intersection(whole)
                let crop = image.cropped(to: tile)
                    .transformed(by: CGAffineTransform(translationX: -tile.minX, y: -tile.minY))
                serial += try AutoDetector.recognizedPass(crop).map { line in
                    func transform(_ point: CGPoint) -> CGPoint {
                        CGPoint(x: (tile.minX - whole.minX + point.x * tile.width) / whole.width,
                                y: (tile.minY - whole.minY + point.y * tile.height) / whole.height)
                    }
                    return AutoDetector.RecognizedLine(text: line.text, box: CGRect(
                        x: (tile.minX - whole.minX + line.box.minX * tile.width) / whole.width,
                        y: (tile.minY - whole.minY + line.box.minY * tile.height) / whole.height,
                        width: line.box.width * tile.width / whole.width,
                        height: line.box.height * tile.height / whole.height),
                        quad: line.quad?.map(transform), confidence: line.confidence,
                        fragments: line.fragments.map {
                            AutoDetector.RecognizedFragment(text: $0.text, quad: $0.quad.map(transform))
                        })
                }
            }
        }
        let parallel = try AutoDetector.recognizedLines(in: image)
        #expect(!serial.isEmpty)
        #expect(serial.contains { $0.text.contains("얼굴") })
        #expect(serial.contains { $0.text.contains("학부모") })
        #expect(serial.contains { $0.text.contains("안내문") })
        #expect(serial.map(\.text) == parallel.map(\.text))
        #expect(serial.map(\.box) == parallel.map(\.box))
        #expect(serial.map(\.quad) == parallel.map(\.quad))
        #expect(serial.map(\.confidence) == parallel.map(\.confidence))
        #expect(serial.map { $0.fragments.map(\.quad) } == parallel.map { $0.fragments.map(\.quad) })
        #expect(serial.map { $0.fragments.map(\.text) } == parallel.map { $0.fragments.map(\.text) })
    }

}
