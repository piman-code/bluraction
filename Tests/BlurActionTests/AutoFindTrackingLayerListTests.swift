import Testing
import AppKit
import AVFoundation
import CoreText
@testable import BlurAction

/// Face/text auto-find, stronger tracking (several targets, backward, smoothing, start frame),
/// hidden-area picking, layer list reordering and multi-row selection, window-close cancel.
/// Real face photos are never used: face finding through the app uses a stand-in detector.
/// Generated videos stay in the system temporary folder (tests never delete files).
@Suite(.serialized)
@MainActor
final class AutoFindTrackingLayerListTests {
    // MARK: Tracker

    /// Two textured patches: A moves right on the upper row, B moves left on the lower row (320×180, 30 fps).
    private func twoTargetVideo(seconds: Int = 4, rate: String = "30") throws -> (URL, URL) {
        let fixtures = VideoExportTests()
        let directory = try fixtures.directory()
        let input = directory.appendingPathComponent("two.mp4")
        try fixtures.ffmpeg(["-f", "lavfi", "-i", "color=c=0x202020:s=320x180:d=\(seconds):r=\(rate)",
                             "-f", "lavfi", "-i", "testsrc2=s=48x48:d=\(seconds):r=\(rate)",
                             "-f", "lavfi", "-i", "testsrc2=s=48x48:d=\(seconds):r=\(rate)",
                             "-filter_complex", "[0][1]overlay=x='20+t*50':y=40[a];[a][2]overlay=x='252-t*50':y=100",
                             "-c:v", "libx264", "-pix_fmt", "yuv420p", input.path])
        return (directory, input)
    }

    /// Normalized bottom-left boxes of A and B at time `t`.
    private func boxes(at t: Double) -> (CGRect, CGRect) {
        (CGRect(x: (20 + t * 50) / 320, y: (180 - 40 - 48) / 180.0, width: 48.0 / 320, height: 48.0 / 180),
         CGRect(x: (252 - t * 50) / 320, y: (180 - 100 - 48) / 180.0, width: 48.0 / 320, height: 48.0 / 180))
    }

    private func nearest(_ outcome: ObjectTracker.Outcome, _ time: Double) throws -> ObjectTracker.Sample {
        try #require(outcome.samples.min { abs($0.time - time) < abs($1.time - time) })
    }

    @Test
    func testSeveralTargetsForwardAndBackward() async throws {
        let (_, input) = try twoTargetVideo()
        let (a1, b1) = boxes(at: 1)
        let forward = try await ObjectTracker.trackMany(url: input, from: 1, until: 3, boxes: [a1, b1], cancellation: .init()) { _ in }
        #expect(forward.count == 2)
        let a = try nearest(forward[0], 2.5), b = try nearest(forward[1], 2.5)
        #expect(abs(a.box.midX * 320 - (20 + 125 + 24)) < 12, "A forward x \(a.box.midX * 320)")
        #expect(abs(b.box.midX * 320 - (252 - 125 + 24)) < 12, "B forward x \(b.box.midX * 320)")
        #expect(forward.allSatisfy { $0.samples.first!.time > 1 && $0.samples.map(\.time) == $0.samples.map(\.time).sorted() })

        var back = ObjectTracker.Options()
        back.direction = .backward
        let (a3, b3) = boxes(at: 3)
        let backward = try await ObjectTracker.trackMany(url: input, from: 3, until: 0.5, boxes: [a3, b3], options: back,
                                                         cancellation: .init()) { _ in }
        let early = try nearest(backward[0], 1), lateB = try nearest(backward[1], 1)
        #expect(backward[0].samples.allSatisfy { $0.time < 3 } && (backward[0].samples.first?.time ?? 9) < 0.7, "Reaches back to 0.5 s")
        #expect(abs(early.box.midX * 320 - (20 + 50 + 24)) < 12, "A backward x \(early.box.midX * 320)")
        #expect(abs(lateB.box.midX * 320 - (252 - 50 + 24)) < 12, "B backward x \(lateB.box.midX * 320)")
    }

    @Test
    func testTrackingStartsFromTheFrameOnScreen() async throws {
        let (_, input) = try twoTargetVideo(seconds: 2)
        // 1.017 s is between frames 1.000 and 1.033: the frame on screen is 1.000.
        let outcome = try await ObjectTracker.track(url: input, from: 1.017, until: 1.5, box: boxes(at: 1).0,
                                                    cancellation: .init()) { _ in }
        let first = try #require(outcome.samples.first?.time)
        #expect(first > 1.017 && first < 1.05, "First tracked frame \(first)")
    }

    @Test
    func testSmoothingCalmsJitterAndKeepsTimes() {
        let samples = (0..<30).map { i -> ObjectTracker.Sample in
            let jitter = i % 2 == 0 ? 0.02 : -0.02
            return .init(time: Double(i) / 30, box: CGRect(x: 0.1 + Double(i) * 0.01 + jitter, y: 0.4, width: 0.1, height: 0.1))
        }
        let smooth = ObjectTracker.smoothed(samples)
        #expect(smooth.map(\.time) == samples.map(\.time))
        func deviation(_ list: [ObjectTracker.Sample]) -> Double {
            list.enumerated().dropFirst(2).dropLast(2).map { abs(Double($0.element.box.minX) - (0.1 + Double($0.offset) * 0.01)) }.max() ?? 0
        }
        #expect(deviation(smooth) < deviation(samples) / 3)
    }

    // MARK: Auto-find

    @Test
    func testTextFinderFindsRenderedTextAndNoFacesThere() throws {
        let width = 800, height = 400
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = NSFont.systemFont(ofSize: 96, weight: .bold)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "BLUR 1234", attributes: [.font: font, .foregroundColor: NSColor.black]))
        context.textPosition = CGPoint(x: 120, y: 160)
        CTLineDraw(line, context)
        let image = CIImage(cgImage: try #require(context.makeImage()))
        let text = try AutoDetector.detect(.text, in: image)
        #expect(!text.isEmpty)
        let printed = CGRect(x: 120.0 / 800, y: 160.0 / 400, width: 560.0 / 800, height: 80.0 / 400)
        #expect(text.contains { AutoDetector.overlap($0, printed) > 0.2 }, "Found \(text)")
        #expect(try AutoDetector.detect(.faces, in: image).isEmpty)
    }

    private func find(_ controller: MainWindowController, _ target: AutoDetector.Target) async {
        await withCheckedContinuation { continuation in controller.findAndCover(target) { continuation.resume() } }
    }

    @Test
    func testFindCoversEachFaceOnceAsOneUndoStep() async throws {
        let session = try await ImageSession.open()
        defer { session.close() }
        let controller = session.controller, canvas = session.canvas
        let faces = [CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.3), CGRect(x: 0.6, y: 0.5, width: 0.15, height: 0.25)]
        controller.autoDetect = { target, _ in target == .faces ? faces : [] }
        await find(controller, .faces)
        let regions = canvas.regionsBinding?() ?? []
        #expect(regions.count == 2)
        #expect(regions.allSatisfy { if case .ellipse = $0 { return true } else { return false } }, "Faces are covered with ovals")
        #expect(regions.map { controller.layerName(of: $0.id) } == ["얼굴 1", "얼굴 2"])
        let size = canvas.bounds.size
        #expect(abs(regions[0].boundingRect.minX - 0.1 * size.width) < 0.5 && abs(regions[0].boundingRect.height - 0.3 * size.height) < 0.5)

        await find(controller, .faces)
        #expect(canvas.regionsBinding?().count == 2, "Places already covered are skipped")
        controller.perform(NSSelectorFromString("groupTapped"))
        #expect(canvas.effectForID?(regions[0].id)?.groupID != nil, "The found faces stay selected together for grouping")
        controller.perform(NSSelectorFromString("undoTapped"))
        controller.perform(NSSelectorFromString("undoTapped"))
        #expect(canvas.regionsBinding?().isEmpty == true, "Finding is one undo step")
    }

    @Test
    func testFindOnVideoTracksTheNewAreasBothWays() async throws {
        let (_, input) = try twoTargetVideo()
        let controller = MainWindowController()
        controller.showWindow(nil)
        defer { controller.close() }
        let container = try #require(controller.window?.contentViewController as? MainContainerViewController)
        controller.load(url: input)
        try await waitUntil { container.slider.isEnabled && container.playerLayer.player?.currentItem?.status == .readyToPlay }
        container.view.layoutSubtreeIfNeeded()
        container.slider.doubleValue = 2
        _ = container.slider.sendAction(container.slider.action, to: container.slider.target)
        try await waitUntil { abs(container.canvas.currentVideoTime - 2) < 0.001 }
        try await Task.sleep(nanoseconds: 50_000_000)
        let target = boxes(at: 2).0
        controller.autoDetect = { _, _ in [target] }
        await find(controller, .faces)
        let region = try #require(container.canvas.regionsBinding?().first)
        try await waitUntil { !controller.isTracking && (container.canvas.effectForID?(region.id)?.keyframes.count ?? 0) > 20 }
        let effect = try #require(container.canvas.effectForID?(region.id))
        #expect(effect.keyframes.contains { $0.time < 1 } && effect.keyframes.contains { $0.time > 3 }, "Tracked both ways")
        #expect(effect.timeRange.lowerBound < 0.6, "The range now starts where tracking reached back: \(effect.timeRange)")
        let size = container.canvas.bounds.size
        let atHalf = RegionEditing.displayed((region, effect), at: 1).boundingRect
        #expect(abs(atHalf.midX / size.width * 320 - (20 + 50 + 24)) < 14, "Follows back in time: \(atHalf.midX / size.width * 320)")
        controller.perform(NSSelectorFromString("undoTapped"))
        #expect(container.canvas.regionsBinding?().isEmpty == true, "Finding and its tracking undo together")
    }

    @Test
    func testFindKeepsItsPageWhileWorking() async throws {
        let directory = try VideoExportTests().directory()
        var urls: [URL] = []
        for name in ["one.png", "two.png"] {
            let url = directory.appendingPathComponent(name)
            let context = try #require(CGContext(data: nil, width: 320, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(gray: 0.8, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 160))
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
            #expect(CGImageDestinationFinalize(destination))
            urls.append(url)
        }
        let controller = MainWindowController()
        controller.showWindow(nil)
        defer { controller.close() }
        let container = try #require(controller.window?.contentViewController as? MainContainerViewController)
        controller.load(urls: urls)
        #expect(container.pageLabel.stringValue == "1 / 2")
        controller.autoDetect = { _, _ in
            Thread.sleep(forTimeInterval: 0.3)
            return [CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.4)]
        }
        var finished = false
        controller.findAndCover(.faces) { finished = true } // as the button does
        click(container.nextPageButton)
        #expect(container.pageLabel.stringValue == "1 / 2", "Pages wait while finding")
        try await waitUntil { finished }
        #expect(container.canvas.regionsBinding?().count == 1, "The result lands on the page it was found on")
        click(container.nextPageButton)
        #expect(container.pageLabel.stringValue == "2 / 2" && container.canvas.regionsBinding?().isEmpty == true)
    }

    /// Like `performClick`, a disabled button does nothing, but no nested event loop is spun:
    /// inside an async test that loop can swallow a stop meant for the main run loop and end the run early.
    private func click(_ button: NSButton) {
        guard button.isEnabled, let action = button.action else { return }
        NSApp.sendAction(action, to: button.target, from: button)
    }

    @Test
    func testKoreanNameTagIsCoveredWhole() throws {
        let width = 900, height = 300
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = NSFont.systemFont(ofSize: 80, weight: .semibold)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "홍길동 3학년 2반", attributes: [.font: font, .foregroundColor: NSColor.black]))
        let origin = CGPoint(x: 70, y: 110)
        context.textPosition = .zero
        let glyphs = CTLineGetImageBounds(line, context).offsetBy(dx: origin.x, dy: origin.y) // measured at the origin
        context.textPosition = origin
        CTLineDraw(line, context)
        let found = try AutoDetector.detect(.text, in: CIImage(cgImage: try #require(context.makeImage())))
        let printed = CGRect(x: glyphs.minX / CGFloat(width), y: glyphs.minY / CGFloat(height),
                             width: glyphs.width / CGFloat(width), height: glyphs.height / CGFloat(height))
        // Every point of the printed line, first syllable to last, lies under a cover: no clipped ends, no gaps.
        let exposed = (0..<200).map { k in
            CGPoint(x: printed.minX + (CGFloat(k % 20) + 0.5) / 20 * printed.width, y: printed.minY + (CGFloat(k / 20) + 0.5) / 10 * printed.height)
        }.filter { point in !found.contains { $0.contains(point) } }
        #expect(exposed.isEmpty, "\(exposed.count) points of the name tag show; covers \(found) vs printed \(printed)")
        #expect(found.count == 1, "One name tag, one cover: \(found)")
    }

    @Test
    func testBackwardTrackingHandlesEachFrameOnce() async throws {
        let (_, input) = try twoTargetVideo()
        var back = ObjectTracker.Options()
        back.direction = .backward
        let outcome = try await ObjectTracker.trackMany(url: input, from: 3, until: 0.2, boxes: [boxes(at: 3).0], options: back,
                                                        cancellation: .init()) { _ in }
        let times = outcome[0].samples.map(\.time)
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        #expect(times.count > 60 && (gaps.min() ?? 0) > 1.0 / 60, "No frame twice; smallest gap \(gaps.min() ?? 0)")
    }

    /// Rates whose frames do not line up with the 1-second read chunks.
    @Test(arguments: ["30000/1001", "24000/1001", "25"])
    func testBackwardTrackingHandlesEachFrameOnceAtOddRates(rate: String) async throws {
        let (_, input) = try twoTargetVideo(rate: rate)
        let parts = rate.split(separator: "/").compactMap { Double($0) }
        let fps = parts.count == 2 ? parts[0] / parts[1] : parts[0]
        var back = ObjectTracker.Options()
        back.direction = .backward
        back.smoothing = false
        let outcome = try await ObjectTracker.trackMany(url: input, from: 3, until: 0.2, boxes: [boxes(at: 3).0], options: back,
                                                        cancellation: .init()) { _ in }
        let times = outcome[0].samples.map(\.time)
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        #expect((gaps.min() ?? 0) > 0.5 / fps, "No frame twice at \(rate); smallest gap \(gaps.min() ?? 0)")
        #expect((gaps.max() ?? 1) < 1.5 / fps, "No frame skipped at a chunk boundary at \(rate); largest gap \(gaps.max() ?? 0)")
        #expect(abs(Double(times.count) - 2.8 * fps) <= 2, "\(times.count) frames for 2.8 s at \(rate)")
    }

    @Test
    func testANonFaceTargetThatVanishesStops() async throws {
        let directory = try VideoExportTests().directory()
        let input = directory.appendingPathComponent("vanish.mp4")
        try VideoExportTests().ffmpeg(["-f", "lavfi", "-i", "color=c=0x202020:s=320x180:d=3:r=30",
                                       "-f", "lavfi", "-i", "testsrc2=s=48x48:d=3:r=30",
                                       "-filter_complex", "[0][1]overlay=x='20+t*50':y=40:enable='lt(t,1.5)'",
                                       "-c:v", "libx264", "-pix_fmt", "yuv420p", input.path])
        var options = ObjectTracker.Options()
        options.reacquireFaces = true
        let outcome = try await ObjectTracker.trackMany(url: input, from: 0.5, until: 3, boxes: [boxes(at: 0.5).0], options: options,
                                                        cancellation: .init()) { _ in }
        #expect(outcome[0].lostTarget)
        #expect((outcome[0].samples.last?.time ?? 9) < 1.7, "Stops where the target vanished")
    }

    // MARK: Hidden areas on the canvas

    @Test
    func testHiddenRegionsAreNotPickedUnlessAsked() async throws {
        let session = try await ImageSession.open()
        defer { session.close() }
        let controller = session.controller, canvas = session.canvas
        controller.perform(NSSelectorFromString("addRegionTapped"))
        let region = try #require(canvas.regionsBinding?().first)
        controller.setLayerHidden(region.id, true)
        canvas.resetInteraction()
        let center = CGPoint(x: region.boundingRect.midX, y: region.boundingRect.midY)
        try session.drag(from: center, to: CGPoint(x: center.x + 25, y: center.y))
        #expect(canvas.regionsBinding?().first?.boundingRect == region.boundingRect, "A hidden area is not grabbed")
        let option = try #require(session.descendants.compactMap { $0 as? NSButton }.first { $0.title == "숨긴 블러 영역도 캔버스에서 고르기" })
        option.state = .on
        _ = option.sendAction(option.action, to: option.target)
        try session.drag(from: center, to: CGPoint(x: center.x + 25, y: center.y))
        #expect(abs((canvas.regionsBinding?().first?.boundingRect.minX ?? 0) - (region.boundingRect.minX + 25)) < 0.5)
        // Chosen in the layer list, a hidden area can still be deleted.
        option.state = .off
        _ = option.sendAction(option.action, to: option.target)
        canvas.selectRegion(id: region.id)
        controller.perform(NSSelectorFromString("deleteSelectedTapped"))
        #expect(canvas.regionsBinding?().isEmpty == true)
    }

    // MARK: Layer list

    @Test
    func testLayerReorderAndMultiRowSelection() async throws {
        let session = try await ImageSession.open()
        defer { session.close() }
        let controller = session.controller, canvas = session.canvas
        controller.perform(NSSelectorFromString("addRegionTapped"))
        controller.perform(NSSelectorFromString("addRegionTapped"))
        session.tool(1)
        try session.drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 40))
        try session.drag(from: CGPoint(x: 60, y: 10), to: CGPoint(x: 90, y: 40))
        let before = controller.layerRows.map(\.id) // [drawing2, drawing1, region2, region1]
        #expect(before.count == 4)
        #expect(controller.moveLayer(before[0], toRow: 2), "Top drawing moves below the other drawing")
        #expect(controller.layerRows.map(\.id) == [before[1], before[0], before[2], before[3]])
        #expect(!controller.moveLayer(before[0], toRow: 4), "A drawing cannot go among blur areas")
        #expect(!controller.moveLayer(before[3], toRow: 0), "A blur area cannot go among drawings")
        #expect(controller.moveLayer(before[3], toRow: 2))
        #expect(controller.layerRows.map(\.id) == [before[1], before[0], before[3], before[2]])
        controller.perform(NSSelectorFromString("undoTapped"))
        controller.perform(NSSelectorFromString("undoTapped"))
        #expect(controller.layerRows.map(\.id) == before)

        let table = try #require(session.descendants.compactMap { $0 as? RegionTableView }.first)
        table.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)
        controller.perform(NSSelectorFromString("groupTapped"))
        let group = try #require(canvas.annotationsBinding?().first { $0.id == before[0] }?.groupID)
        #expect(canvas.effectForID?(before[2])?.groupID == group, "Rows picked together are grouped together")
        table.selectRowIndexes(IndexSet([2, 3]), byExtendingSelection: false)
        controller.perform(NSSelectorFromString("deleteSelectedTapped"))
        #expect(canvas.regionsBinding?().isEmpty == true && canvas.annotationsBinding?().count == 2, "Both picked rows are deleted")
        controller.perform(NSSelectorFromString("undoTapped"))
        #expect(canvas.regionsBinding?().count == 2, "One undo brings both back")
    }

    // MARK: Busy text scenes

    @Test
    func testTextBoxesJoinPerSignButNeverChain() {
        func same(_ a: [CGRect], _ b: [CGRect]) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy { abs($0.minX - $1.minX) + abs($0.minY - $1.minY) + abs($0.maxX - $1.maxX) + abs($0.maxY - $1.maxY) < 1e-9 }
        }
        // Padded lines of one sign overlap a little.
        let upper = CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.05), lower = CGRect(x: 0.1, y: 0.46, width: 0.18, height: 0.05)
        #expect(same(AutoDetector.mergedText([upper, lower]), [upper.union(lower)]), "Two lines of one sign become one cover")
        #expect(same(AutoDetector.mergedText([upper, upper.insetBy(dx: 0.01, dy: 0.01)]), [upper]), "Repeats from several passes collapse")
        let far = CGRect(x: 0.7, y: 0.1, width: 0.1, height: 0.04)
        #expect(AutoDetector.mergedText([upper, far]).count == 2)
        let corner = CGRect(x: 0.29, y: 0.54, width: 0.2, height: 0.3) // touches only at a corner
        #expect(AutoDetector.mergedText([upper, corner]).count == 2, "No diagonal chaining into one huge box")
        // A staircase of slanted signs, each overlapping the next by 60%: the slack must not add up.
        let stairs = (0..<12).map { CGRect(x: 0.1 + Double($0) * 0.024, y: 0.1 + Double($0) * 0.012, width: 0.06, height: 0.03) }
        let joined = AutoDetector.mergedText(stairs)
        let text = AutoDetector.unionArea(stairs), covered = AutoDetector.unionArea(joined)
        #expect(joined.allSatisfy { $0.width * $0.height <= AutoDetector.unionArea(stairs.filter($0.intersects)) * 1.3 + 1e-12 })
        #expect(covered <= text * 1.3, "Covers \(covered) for text \(text) in \(joined.count) boxes")
        #expect(abs(AutoDetector.unionArea([upper, upper]) - upper.width * upper.height) < 1e-12, "Overlaps count once")
    }

    @Test
    func testTinyFindsAreEnlargedNotDropped() {
        let tiny = CGRect(x: 0.995, y: 0.5, width: 0.004, height: 0.003).grown(toAtLeast: 0.01)
        #expect(abs(tiny.width - 0.01) < 1e-12 && abs(tiny.height - 0.01) < 1e-12 && tiny.maxX <= 1, "\(tiny)")
        #expect(abs(tiny.midY - 0.5015) < 1e-9, "Kept around its center")
        let big = CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.1)
        #expect(big.grown(toAtLeast: 0.01) == big)
        // What detect hands over survives the canvas round trip of any window size and stays trackable.
        let found = CGRect(x: 0.4, y: 0.4, width: 0.001, height: 0.001).grown(toAtLeast: 0.0101)
        for side in stride(from: 200.0, through: 4000.0, by: 1.0) {
            let back = (found.width * side) / side
            #expect(back >= ObjectTracker.minimumSide, "Window \(side)")
        }
    }

    /// A 1920×1080 street of 34 small, faint, slightly blurred signs (some slanted or vertical), JPEG-compressed.
    private func streetOfSigns() throws -> (CIImage, [CGRect]) {
        let width = 1920, height = 1080
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for i in 0..<24 { for j in 0..<14 {
            context.setFillColor(red: CGFloat((i * 37 + j * 11) % 255) / 510 + 0.3, green: CGFloat((i * 13 + j * 29) % 255) / 510 + 0.3,
                                 blue: CGFloat((i * 7 + j * 53) % 255) / 510 + 0.3, alpha: 1)
            context.fill(CGRect(x: i * 80, y: j * 80, width: 80, height: 80))
        } }
        var signs: [(String, CGFloat, CGPoint, CGFloat, Bool)] = [
            ("행복약국", 40, CGPoint(x: 80, y: 900), 0, false), ("OPEN 24H", 22, CGPoint(x: 600, y: 950), 0, false),
            ("김밥천국", 18, CGPoint(x: 1100, y: 980), 0, false), ("서울치과의원", 16, CGPoint(x: 1500, y: 860), 0, false),
            ("010-1234-5678", 14, CGPoint(x: 120, y: 700), 0, false), ("SALE 50%", 15, CGPoint(x: 700, y: 640), 0, false),
            ("미용실", 13, CGPoint(x: 1250, y: 700), 0, false), ("12가 3456", 20, CGPoint(x: 1600, y: 560), 0, false),
            ("편의점", 30, CGPoint(x: 300, y: 420), 12, false), ("CAFE", 26, CGPoint(x: 900, y: 360), -10, false),
            ("학원", 34, CGPoint(x: 1450, y: 200), 0, true), ("노래방", 28, CGPoint(x: 1750, y: 150), 0, true),
            ("주차장 입구", 12, CGPoint(x: 500, y: 150), 0, false), ("Bakery", 12, CGPoint(x: 1050, y: 120), 0, false)]
        let words = ["부동산", "세탁소", "PC방", "정형외과", "BURGER", "안경점", "꽃집", "치킨", "HOTEL", "은행",
                     "분식", "공인중개사", "헬스", "네일", "피자", "약국", "PARKING", "문구", "정육점", "카페"]
        for (k, word) in words.enumerated() {
            signs.append((word, CGFloat(11 + (k * 7) % 14), CGPoint(x: 60 + CGFloat((k * 397) % 1750), y: 60 + CGFloat((k * 233) % 960)),
                          CGFloat((k % 5) - 2) * 4, k % 7 == 3))
        }
        var truth: [CGRect] = []
        for (text, baseSize, at, angle, vertical) in signs {
            let size = baseSize * 0.85
            let font = CTFontCreateWithName("AppleSDGothicNeo-Bold" as CFString, size, nil)
            var boxes: [CGRect] = []
            context.saveGState()
            context.translateBy(x: at.x, y: at.y)
            context.rotate(by: angle * .pi / 180)
            for (k, piece) in (vertical ? text.map(String.init) : [text]).enumerated() {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: piece, attributes: [
                    .font: font, .foregroundColor: NSColor(white: 1 - 0.85 * 0.5, alpha: 1)]))
                context.textPosition = .zero
                let glyphs = CTLineGetImageBounds(line, context)
                let origin = CGPoint(x: 0, y: -CGFloat(k) * size * 1.15)
                context.setFillColor(red: 0.85, green: 0.85, blue: 0.8, alpha: 1)
                context.fill(glyphs.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -6, dy: -6))
                context.textPosition = origin
                CTLineDraw(line, context)
                boxes.append(glyphs.offsetBy(dx: origin.x, dy: origin.y))
            }
            context.restoreGState()
            let placed = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
                .applying(CGAffineTransform(translationX: at.x, y: at.y).rotated(by: angle * .pi / 180))
            truth.append(CGRect(x: placed.minX / CGFloat(width), y: placed.minY / CGFloat(height),
                                width: placed.width / CGFloat(width), height: placed.height / CGFloat(height)))
        }
        let blurred = CIImage(cgImage: try #require(context.makeImage()))
        let soft = blurred.clampedToExtent().applyingGaussianBlur(sigma: 0.6).cropped(to: blurred.extent)
        let jpeg = try #require(CIContext().jpegRepresentation(of: soft, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                               options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.5]))
        return (try #require(CIImage(data: jpeg)), truth)
    }

    @Test
    func testBusyStreetSignsAreFoundAndKeptFew() throws {
        let (image, truth) = try streetOfSigns()
        let found = try AutoDetector.detect(.text, in: image)
        func hidden(_ sign: CGRect) -> Bool {
            (0..<100).allSatisfy { k in
                let point = CGPoint(x: sign.minX + (CGFloat(k % 10) + 0.5) / 10 * sign.width, y: sign.minY + (CGFloat(k / 10) + 0.5) / 10 * sign.height)
                return found.contains { $0.contains(point) }
            }
        }
        let covered = truth.filter(hidden).count
        // Whole-frame reading alone covered 6 of these 34 when measured; tiles and the extra passes about 19.
        #expect(covered >= 15, "Covered \(covered) of \(truth.count) signs")
        #expect(found.count <= 30, "One cover per sign, not one per pass: \(found.count)")
        #expect(found.allSatisfy { $0.width * $0.height < 0.05 }, "No cover swallows a large part of the street")
    }

    @Test
    func testDenseDocumentPageStaysQuickAndCoveredWhole() throws {
        // An A4 page at 150 dpi with 40 lines of small Korean/English text.
        let width = 1240, height = 1754
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString, 22, nil)
        let words = ["학생", "생활기록부", "세부능력", "및", "특기사항", "Report", "2026", "수업", "활동에서", "적극적으로", "참여하며", "탐구", "능력을", "보여줌", "project", "발표"]
        var printed = CGRect.null
        for row in 0..<40 {
            let text = (0..<12).map { words[(row * 5 + $0 * 3) % words.count] }.joined(separator: " ")
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black]))
            let origin = CGPoint(x: 100, y: CGFloat(height) - 120 - CGFloat(row) * 22 * 1.25)
            context.textPosition = .zero
            printed = printed.union(CTLineGetImageBounds(line, context).offsetBy(dx: origin.x, dy: origin.y))
            context.textPosition = origin
            CTLineDraw(line, context)
        }
        let image = CIImage(cgImage: try #require(context.makeImage()))
        let start = Date()
        let found = try AutoDetector.detect(.text, in: image)
        let seconds = Date().timeIntervalSince(start)
        // Measured about 3 s in a release build (7 s before joining was made incremental); debug builds are slower.
        #expect(seconds < 30, "Finding text on a dense page took \(seconds) s")
        #expect(found.count <= 3, "A block of text becomes one cover, not hundreds: \(found.count)")
        let block = CGRect(x: printed.minX / CGFloat(width), y: printed.minY / CGFloat(height),
                           width: printed.width / CGFloat(width), height: printed.height / CGFloat(height))
        let shown = (0..<400).map { k in
            CGPoint(x: block.minX + (CGFloat(k % 20) + 0.5) / 20 * block.width, y: block.minY + (CGFloat(k / 20) + 0.5) / 20 * block.height)
        }.filter { point in !found.contains { $0.contains(point) } }
        #expect(shown.isEmpty, "\(shown.count) points of the text block show")
    }

    // MARK: Cancel a find, pick or remove what it found

    @Test
    func testAFindCanBeCancelledAndAddsNothing() async throws {
        let session = try await ImageSession.open()
        defer { session.close() }
        let controller = session.controller, canvas = session.canvas
        // A detector that keeps working until asked to stop (like the tiled text passes).
        controller.autoDetect = { _, _ in
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                try Task.checkCancellation()
                Thread.sleep(forTimeInterval: 0.01)
            }
            return [CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)]
        }
        var finished = false
        controller.findAndCover(.text) { finished = true }
        #expect(controller.isExporting, "Editing waits while finding")
        #expect(session.descendants.contains { ($0 as? NSButton)?.title == "취소" && !$0.isHidden }, "취소 is offered while finding")
        try await Task.sleep(nanoseconds: 100_000_000)
        let asked = Date()
        controller.cancelCurrentOperation()
        try await waitUntil { finished }
        #expect(Date().timeIntervalSince(asked) < 2, "Stops promptly, not after the 10 s the detector would take")
        #expect(canvas.regionsBinding?().isEmpty == true, "A cancelled find adds nothing")
        #expect(!controller.isExporting)
        #expect(!session.descendants.contains { ($0 as? NSButton)?.title == "취소" && !$0.isHidden })
        #expect(session.descendants.contains { ($0 as? NSTextField)?.stringValue.contains("찾기를 취소했습니다") == true })
    }

    @Test
    func testTextFindingStopsWhenCancelled() async throws {
        let (image, _) = try streetOfSigns()
        let task = Task.detached { try AutoDetector.detect(.text, in: image) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test
    func testFoundAreasCanBePickedAgainAndRemovedTogether() async throws {
        let session = try await ImageSession.open()
        defer { session.close() }
        let controller = session.controller, canvas = session.canvas
        controller.autoDetect = { _, _ in
            [CGRect(x: 0.05, y: 0.1, width: 0.2, height: 0.3), CGRect(x: 0.4, y: 0.1, width: 0.2, height: 0.3), CGRect(x: 0.7, y: 0.5, width: 0.2, height: 0.3)]
        }
        await find(controller, .faces)
        let found = try #require(canvas.regionsBinding?()).map(\.id)
        #expect(found.count == 3)
        controller.perform(NSSelectorFromString("addRegionTapped")) // something else gets picked
        #expect(controller.multiSelection.isEmpty)
        controller.selectFoundTapped()
        #expect(Set(controller.multiSelection) == Set(found), "The find's areas are picked together again")
        controller.setLayerLocked(found[1], true)
        controller.deleteFoundTapped()
        let left = try #require(canvas.regionsBinding?()).map(\.id)
        #expect(left.count == 2 && left.contains(found[1]) && !left.contains(found[0]) && !left.contains(found[2]),
                "Unlocked found areas go, the locked one and the hand-made area stay")
        controller.perform(NSSelectorFromString("undoTapped"))
        #expect(canvas.regionsBinding?().count == 4, "One undo brings them back")
    }

    @Test
    func testFoundButtonsActOnlyOnThePageTheFindRanOn() async throws {
        let directory = try VideoExportTests().directory()
        var urls: [URL] = []
        for name in ["first.png", "second.png"] {
            let url = directory.appendingPathComponent(name)
            let context = try #require(CGContext(data: nil, width: 320, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(gray: 0.7, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 160))
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
            #expect(CGImageDestinationFinalize(destination))
            urls.append(url)
        }
        let controller = MainWindowController()
        controller.showWindow(nil)
        defer { controller.close() }
        let container = try #require(controller.window?.contentViewController as? MainContainerViewController)
        controller.load(urls: urls)
        container.view.layoutSubtreeIfNeeded()
        controller.autoDetect = { _, _ in [CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.3), CGRect(x: 0.6, y: 0.2, width: 0.2, height: 0.3)] }
        await find(controller, .faces)
        let found = try #require(container.canvas.regionsBinding?()).map(\.id)
        #expect(found.count == 2)
        click(container.nextPageButton)
        #expect(container.pageLabel.stringValue == "2 / 2")
        controller.perform(NSSelectorFromString("addRegionTapped"))
        controller.selectFoundTapped()
        #expect(controller.multiSelection.isEmpty, "Nothing from page 1 is picked on page 2")
        controller.deleteFoundTapped()
        #expect(container.canvas.regionsBinding?().count == 1, "Page 2's own area stays")
        click(container.previousPageButton)
        #expect(container.pageLabel.stringValue == "1 / 2")
        controller.selectFoundTapped()
        #expect(Set(controller.multiSelection) == Set(found), "Back on page 1 the find's areas are picked again")
    }

    // MARK: Review follow-ups

    /// Every label text in the controller's window (the hint line is private).
    private func labels(_ controller: MainWindowController) -> [String] {
        var found: [String] = [], stack: [NSView] = controller.window?.contentView.map { [$0] } ?? []
        while let view = stack.popLast() {
            if let field = view as? NSTextField { found.append(field.stringValue) }
            stack += view.subviews
        }
        return found
    }

    @Test
    func testManyTargetsAreTrackedInTurns() async throws {
        let (_, input) = try twoTargetVideo(seconds: 2)
        let (a, b) = boxes(at: 0.5)
        // 40 boxes (more than one handler takes): A first, B last, so they land in different turns.
        var many = [a]
        for k in 0..<38 { many.append(CGRect(x: 0.01 + Double(k % 10) * 0.095, y: 0.02 + Double(k / 10) * 0.2, width: 0.08, height: 0.12)) }
        many.append(b)
        var seen: [Double] = []
        let outcomes = try await ObjectTracker.trackMany(url: input, from: 0.5, until: 1.5, boxes: many,
                                                         cancellation: .init()) { seen.append($0) }
        #expect(outcomes.count == 40)
        let first = try nearest(outcomes[0], 1.4), last = try nearest(outcomes[39], 1.4)
        #expect(abs(first.box.midX * 320 - (20 + 70 + 24)) < 12, "A in the first turn: \(first.box.midX * 320)")
        #expect(abs(last.box.midX * 320 - (252 - 70 + 24)) < 12, "B in the second turn: \(last.box.midX * 320)")
        #expect(seen == seen.sorted() && (seen.last ?? 0) > 0.95, "Progress runs once from 0 to 1 across turns")
    }

    @Test
    func testTinyItemsAreSkippedNotFatal() async throws {
        let (_, input) = try twoTargetVideo()
        let controller = MainWindowController()
        controller.showWindow(nil)
        defer { controller.close() }
        let container = try #require(controller.window?.contentViewController as? MainContainerViewController)
        controller.load(url: input)
        try await waitUntil { container.slider.isEnabled && container.playerLayer.player?.currentItem?.status == .readyToPlay }
        container.view.layoutSubtreeIfNeeded()
        let size = container.canvas.bounds.size, box = boxes(at: 0).0
        let rect = CGRect(x: box.minX * size.width, y: box.minY * size.height, width: box.width * size.width, height: box.height * size.height)
        container.canvas.regionsUpdate?([.rectangle(id: UUID(), origin: rect.origin, size: rect.size),
                                         .rectangle(id: UUID(), origin: CGPoint(x: 5, y: 5), size: CGSize(width: 1, height: 1))])
        let regions = try #require(container.canvas.regionsBinding?())
        #expect(regions.count == 2)
        controller.startTracking(ids: regions.map(\.id), choice: .forward)
        try await waitUntil { !controller.isTracking }
        #expect((container.canvas.effectForID?(regions[0].id)?.keyframes.count ?? 0) > 30, "The real target is still followed")
        #expect(container.canvas.effectForID?(regions[1].id)?.keyframes.isEmpty == true)
        #expect(labels(controller).contains { $0.contains("너무 작은 1개는 건너뛰었습니다") }, "\(labels(controller))")
    }

    @Test
    func testHalfCoveredFaceGetsItsOwnCover() async throws {
        let session = try await ImageSession.open()
        defer { session.close() }
        let controller = session.controller, canvas = session.canvas
        let face = CGRect(x: 0.3, y: 0.2, width: 0.2, height: 0.5)
        controller.autoDetect = { _, _ in [CGRect(x: 0.3, y: 0.45, width: 0.2, height: 0.25)] } // its upper half
        await find(controller, .faces)
        #expect(canvas.regionsBinding?().count == 1)
        controller.autoDetect = { _, _ in [face] }
        await find(controller, .faces)
        #expect(canvas.regionsBinding?().count == 2, "Half hidden is not hidden: the whole face gets covered")
        await find(controller, .faces)
        #expect(canvas.regionsBinding?().count == 2, "Once it is wholly covered, it is skipped")
    }

    @Test
    func testCoverageFollowsTheRealShapeNotItsBox() async throws {
        let session = try await ImageSession.open()
        defer { session.close() }
        let controller = session.controller, canvas = session.canvas
        controller.autoDetect = { _, _ in [CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.6)] }
        await find(controller, .faces)
        await find(controller, .faces)
        #expect(canvas.regionsBinding?().count == 1, "The same face found again is covered by its own oval")
        // Text in the oval's box corner lies outside the oval itself.
        controller.autoDetect = { _, _ in [CGRect(x: 0.21, y: 0.21, width: 0.08, height: 0.04)] }
        await find(controller, .text)
        #expect(canvas.regionsBinding?().count == 2, "Inside the bounding box but outside the oval still gets covered")
        await find(controller, .text)
        #expect(canvas.regionsBinding?().count == 2)
        // A text line sticking out of an existing cover by one twelfth still gets its own cover.
        controller.autoDetect = { _, _ in [CGRect(x: 0.21, y: 0.21, width: 0.08 * 13 / 12, height: 0.04)] }
        await find(controller, .text)
        #expect(canvas.regionsBinding?().count == 3, "The uncovered end of the line is not left showing")
        // Once eraser marks are on the oval, it no longer counts as covering the face.
        let oval = try #require(canvas.regionsBinding?().first)
        canvas.selectRegion(id: oval.id)
        controller.applyEraserStroke([CGPoint(x: 0, y: oval.boundingRect.midY), CGPoint(x: canvas.bounds.width, y: oval.boundingRect.midY)], width: 6)
        #expect(canvas.effectForID?(oval.id)?.erasures.isEmpty == false)
        controller.autoDetect = { _, _ in [CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.6)] }
        await find(controller, .faces)
        #expect(canvas.regionsBinding?().count == 4, "A face under an erased area is covered again")
    }

    @Test
    func testDeletingSeveralRemovesTheUnlockedEvenIfTheLastPickedIsLocked() async throws {
        let session = try await ImageSession.open()
        defer { session.close() }
        let controller = session.controller, canvas = session.canvas
        for _ in 0..<3 { controller.perform(NSSelectorFromString("addRegionTapped")) }
        let rows = controller.layerRows.map(\.id)
        #expect(rows.count == 3)
        controller.setLayerLocked(rows[2], true)
        let table = try #require(session.descendants.compactMap { $0 as? RegionTableView }.first)
        table.selectRowIndexes(IndexSet([0, 1, 2]), byExtendingSelection: false) // the locked row is the primary
        controller.perform(NSSelectorFromString("deleteSelectedTapped"))
        #expect(canvas.regionsBinding?().map(\.id) == [rows[2]], "Only the locked one stays")
        table.selectRowIndexes(IndexSet([0]), byExtendingSelection: false)
        controller.perform(NSSelectorFromString("deleteSelectedTapped"))
        #expect(canvas.regionsBinding?().count == 1, "A locked layer alone is not deleted")
    }

    // MARK: Window close

    @Test
    func testClosingTheWindowStopsTracking() async throws {
        let (_, input) = try twoTargetVideo(seconds: 20)
        let controller = MainWindowController()
        controller.showWindow(nil)
        let container = try #require(controller.window?.contentViewController as? MainContainerViewController)
        controller.load(url: input)
        try await waitUntil { container.slider.isEnabled && container.playerLayer.player?.currentItem?.status == .readyToPlay }
        container.view.layoutSubtreeIfNeeded()
        controller.perform(NSSelectorFromString("addRegionTapped"))
        let region = try #require(container.canvas.regionsBinding?().first)
        controller.startTracking(ids: [region.id], choice: .forward)
        #expect(controller.isTracking)
        controller.window?.close()
        try await waitUntil { controller.trackingStopRequested || !controller.isTracking }
        #expect(controller.trackingStopRequested || !controller.isTracking)
        try await waitUntil { !controller.isTracking }
    }
}
