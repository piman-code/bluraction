import AVFoundation
import CoreImage
import Foundation
import Vision

/// Finds faces or text (licence plates, name tags, signs) in one image or video frame to
/// suggest areas to cover. Boxes are normalized to the displayed frame, bottom-left origin.
enum AutoDetector {
    enum Target: String, CaseIterable {
        case faces, text
        var label: String { self == .faces ? "얼굴" : "글자" }
    }

    enum DetectError: LocalizedError {
        case frameUnavailable, visionFailed
        var errorDescription: String? {
            switch self {
            case .frameUnavailable: return "지금 화면의 프레임을 읽지 못했습니다."
            case .visionFailed: return "자동 찾기 중 오류가 발생했습니다."
            }
        }
    }

    /// Padded, frame-clamped boxes, largest first. Faces get room for hair and chin; text a margin.
    static func detect(_ target: Target, in image: CIImage) throws -> [CGRect] {
        let raw: [CGRect]
        switch target {
        case .faces:
            let request = VNDetectFaceRectanglesRequest()
            do { try VNImageRequestHandler(ciImage: image, options: [:]).perform([request]) }
            catch { throw DetectError.visionFailed }
            raw = (request.results ?? []).map { face in
                let b = face.boundingBox
                return CGRect(x: b.minX - b.width * 0.2, y: b.minY - b.height * 0.15,
                              width: b.width * 1.4, height: b.height * 1.5)
            }
        case .text:
            raw = mergedText(try textBoxes(in: image).map { $0.insetBy(dx: -$0.height * 0.25, dy: -$0.height * 0.25).clampedToUnit })
        }
        // Something found too small to cover or track (tiny text in a 4K frame, a far face) is
        // enlarged around its center to just over 1% of the frame instead of being dropped.
        return raw.map(\.clampedToUnit)
            .filter { $0.width > 0 && $0.height > 0 }
            .map { $0.grown(toAtLeast: 0.0101) } // a hair over the 1% the tracker needs, so canvas round trips stay above it
            .sorted { $0.width * $0.height > $1.width * $1.height }
    }

    /// Detailed suggestions keep the exact legacy tracker box alongside independently observed
    /// geometry. Missing evidence always leaves the old cover available to the caller.
    struct Detection {
        var generousBox: CGRect
        var target: Target
        var evidencePoints: [CGPoint]
        var reliable: Bool
    }

    static func detectDetailed(_ target: Target, in image: CIImage) throws -> [Detection] {
        let boxes = try detect(target, in: image)
        switch target {
        case .faces:
            let request = VNDetectFaceLandmarksRequest()
            // A failure of this optional refinement must not remove successful legacy detections.
            do { try VNImageRequestHandler(ciImage: image, options: [:]).perform([request]) }
            catch { return boxes.map { Detection(generousBox: $0, target: target, evidencePoints: [], reliable: false) } }
            let faces = request.results ?? []
            return boxes.map { generous in
                let candidates = faces.filter { overlap($0.boundingBox, generous) > 0.35 }
                guard candidates.count == 1, let face = candidates.first,
                      face.confidence >= 0.85, face.boundingBox.width >= 0.025,
                      face.boundingBox.height >= 0.025,
                      let yaw = face.yaw, abs(yaw.doubleValue) <= 0.25,
                      let roll = face.roll, abs(roll.doubleValue) <= 0.35,
                      let landmarks = face.landmarks?.allPoints, landmarks.pointCount >= 20 else {
                    return Detection(generousBox: generous, target: target, evidencePoints: [], reliable: false)
                }
                if let pitch = face.pitch, abs(pitch.doubleValue) > 0.25 {
                    return Detection(generousBox: generous, target: target, evidencePoints: [], reliable: false)
                }
                let box = face.boundingBox
                var points = landmarks.normalizedPoints.map {
                    CGPoint(x: box.minX + $0.x * box.width, y: box.minY + $0.y * box.height)
                }
                // Landmarks do not include the forehead. Include an expanded face oval as well
                // as all observed landmarks, so fitting cannot shrink to eyes/nose/mouth alone.
                points += (0..<32).map { index in
                    let angle = CGFloat(index) * 2 * .pi / 32
                    return CGPoint(x: box.midX + cos(angle) * box.width * 0.55,
                                   y: box.midY + box.height * 0.04 + sin(angle) * box.height * 0.60)
                }
                return Detection(generousBox: generous, target: target, evidencePoints: points, reliable: true)
            }
        case .text:
            let lines: [RecognizedLine]
            let geometry: [TextGeometry]
            do {
                lines = try recognizedLines(in: image)
                geometry = try textGeometries(in: image)
            }
            catch { return boxes.map { Detection(generousBox: $0, target: target, evidencePoints: [], reliable: false) } }
            return boxes.map { generous in
                let candidates = lines.filter { line in
                    guard (line.confidence ?? 0) >= 0.65, validQuad(line.quad),
                          overlap(PhraseCover.coverBox(line.box), generous) >= 0.85 else { return false }
                    return true
                }
                // Tile duplicates can be folded only when they agree geometrically. A group
                // with several distinct lines or unreadable pieces keeps its original cover.
                guard let line = candidates.first,
                      candidates.allSatisfy({ overlap($0.box, line.box) >= 0.90 }),
                      let quad = line.quad else {
                    return Detection(generousBox: generous, target: target, evidencePoints: [], reliable: false)
                }
                // Include every original text-shaped observation contributing to this cover,
                // including decorative or unreadable characters. OCR alone must not trim them.
                let parts = geometry.filter { part in
                    generous.insetBy(dx: -0.000001, dy: -0.000001).contains(part.box)
                }
                guard !parts.isEmpty, parts.allSatisfy({ validQuad($0.quad) }) else {
                    return Detection(generousBox: generous, target: target, evidencePoints: [], reliable: false)
                }
                let points = quad + parts.flatMap(\.quad)
                guard points.count <= 512 else {
                    return Detection(generousBox: generous, target: target, evidencePoints: [], reliable: false)
                }
                return Detection(generousBox: generous, target: target, evidencePoints: points, reliable: true)
            }
        }
    }

    /// Reobserves geometry on each tracked frame, shared across tracks. This is deliberately
    /// bounded: a long clip keeps generous covers instead of extrapolating sparse observations.
    static func refineTracks(url: URL, target: Target, tracks: [[ObjectTracker.Sample]],
                             cancellation: ObjectTracker.Cancellation,
                             phrases: [String]? = nil) async throws -> [[PhraseTracker.CoverEvidence]] {
        var result = tracks.map { _ in [PhraseTracker.CoverEvidence]() }
        guard tracks.count <= 64, tracks.reduce(0, { $0 + $1.count }) <= 9_000 else { return result }
        struct FrameReference { var track: Int; var sample: ObjectTracker.Sample }
        var frames: [Double: [FrameReference]] = [:]
        for (index, samples) in tracks.enumerated() {
            for sample in samples {
                guard sample.time.isFinite, sample.time >= 0,
                      sample.box.width > 0, sample.box.height > 0,
                      [sample.box.minX, sample.box.minY, sample.box.width, sample.box.height].allSatisfy(\.isFinite) else { continue }
                frames[sample.time, default: []].append(.init(track: index, sample: sample))
            }
        }
        guard frames.count <= 600 else { return result }
        func check() throws {
            try Task.checkCancellation()
            if cancellation.isCancelled { throw CancellationError() }
        }
        try check()
        let source = try VideoProjectSourceBinding.Source.capture(url) { try check() }
        let generator = AVAssetImageGenerator(asset: VideoAssetPolicy.asset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 1920, height: 1920)
        for time in frames.keys.sorted() {
            try check()
            try source.validateIdentity()
            guard let frame = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 60_000)) else {
                try check()
                continue // Optional refinement failure retains this frame's generous cover.
            }
            // A decoded neighbouring frame is not evidence for the requested tracked frame.
            guard abs(frame.actualTime.seconds - time) <= 1.0 / 6_000 else { continue }
            let image = CIImage(cgImage: frame.image)
            let detections: [Detection]
            do {
                if target == .text, let phrases {
                    // OCR identity is rechecked at every frame. A generic text-shaped region may
                    // not substitute for the selected phrase after motion or an occlusion.
                    let lines = try recognizedLines(in: image)
                    detections = lines.compactMap { line in
                        guard let points = phraseEvidence(line: line, phrases: phrases) else { return nil }
                        return Detection(generousBox: PhraseCover.coverBox(line.box), target: .text,
                                         evidencePoints: points, reliable: true)
                    }
                } else {
                    detections = try detectDetailed(target, in: image).filter(\.reliable)
                }
            } catch {
                try check()
                continue // A failed optional Vision pass cannot invalidate successful tracking.
            }
            let references = frames[time] ?? []
            for reference in references {
                let candidates = detections.filter { overlap($0.generousBox, reference.sample.box) >= 0.5 }
                guard let candidate = candidates.first,
                      candidates.allSatisfy({ overlap($0.generousBox, candidate.generousBox) >= 0.90 }) else { continue }
                // No transfer of one observed face/label to two competing tracked identities.
                guard !references.contains(where: {
                    $0.track != reference.track && overlap($0.sample.box, candidate.generousBox) >= 0.5
                }) else { continue }
                result[reference.track].append(.init(time: time, points: candidate.evidencePoints,
                                                    generousBox: reference.sample.box))
            }
        }
        try source.validate { try check() }
        return result
    }

    /// Text lines from the whole picture and from enlarged tiles of it (small or faint sign text
    /// is lost when Vision scales the whole frame down), plus a contrast-raised pass. Unpadded,
    /// normalized to the whole picture, overlapping freely.
    private static func textBoxes(in image: CIImage) throws -> [CGRect] {
        let longSide = max(image.extent.width, image.extent.height)
        var found = try textPass(image)
        if longSide >= 800 {
            let enhanced = image
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.6, kCIInputSaturationKey: 0])
                .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.8])
                .cropped(to: image.extent)
            found += try tiles(of: image, grid: 2) + tiles(of: enhanced, grid: 2)
        }
        if longSide >= 1600 { found += try tiles(of: image, grid: 4) }
        return found
    }

    private struct TextGeometry { var box: CGRect; var quad: [CGPoint] }

    /// The same passes used by legacy detection, retaining the actual quadrilaterals so
    /// unreadable text shapes still participate in the conservative fitted cover.
    private static func textGeometries(in image: CIImage) throws -> [TextGeometry] {
        let longSide = max(image.extent.width, image.extent.height)
        var found = try textGeometryPass(image)
        func geometryTiles(_ input: CIImage, grid: Int) throws -> [TextGeometry] {
            let whole = input.extent
            let width = whole.width / CGFloat(grid), height = whole.height / CGFloat(grid)
            var result: [TextGeometry] = []
            for column in 0..<grid {
                for row in 0..<grid {
                    let tile = CGRect(x: whole.minX + CGFloat(column) * width - width * 0.1,
                                      y: whole.minY + CGFloat(row) * height - height * 0.1,
                                      width: width * 1.2, height: height * 1.2).intersection(whole)
                    let crop = input.cropped(to: tile).transformed(by: CGAffineTransform(translationX: -tile.minX, y: -tile.minY))
                    result += try textGeometryPass(crop).map { part in
                        TextGeometry(box: CGRect(
                            x: (tile.minX - whole.minX + part.box.minX * tile.width) / whole.width,
                            y: (tile.minY - whole.minY + part.box.minY * tile.height) / whole.height,
                            width: part.box.width * tile.width / whole.width, height: part.box.height * tile.height / whole.height),
                            quad: part.quad.map { CGPoint(x: (tile.minX - whole.minX + $0.x * tile.width) / whole.width,
                                                        y: (tile.minY - whole.minY + $0.y * tile.height) / whole.height) })
                    }
                }
            }
            return result
        }
        if longSide >= 800 {
            let enhanced = image
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.6, kCIInputSaturationKey: 0])
                .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.8]).cropped(to: image.extent)
            found += try geometryTiles(image, grid: 2) + geometryTiles(enhanced, grid: 2)
        }
        if longSide >= 1600 { found += try geometryTiles(image, grid: 4) }
        return found
    }

    /// Reads text two ways: recognized lines (accurate, Korean first, so whole Hangul lines are boxed;
    /// fast mode clips the first syllables of Korean name tags) and text-shaped areas that cannot be
    /// read (decorative, vertical or slanted sign lettering).
    private static func textPass(_ image: CIImage) throws -> [CGRect] {
        try textGeometryPass(image).map(\.box)
    }

    private static func textGeometryPass(_ image: CIImage) throws -> [TextGeometry] {
        try Task.checkCancellation() // 취소 stops between passes
        let lines = VNRecognizeTextRequest()
        lines.recognitionLevel = .accurate
        lines.recognitionLanguages = ["ko-KR", "en-US"]
        lines.usesLanguageCorrection = false
        lines.minimumTextHeight = 0
        let shapes = VNDetectTextRectanglesRequest()
        do { try VNImageRequestHandler(ciImage: image, options: [:]).perform([lines, shapes]) }
        catch { throw DetectError.visionFailed }
        let observations: [VNRectangleObservation] = (lines.results ?? []).map { $0 as VNRectangleObservation }
            + (shapes.results ?? []).map { $0 as VNRectangleObservation }
        return observations.map { TextGeometry(box: $0.boundingBox,
            quad: [$0.bottomLeft, $0.bottomRight, $0.topRight, $0.topLeft]) }
    }

    /// `grid`×`grid` tiles overlapping by 10% so text on a seam is whole in one of them.
    private static func tiles(of image: CIImage, grid: Int) throws -> [CGRect] {
        let whole = image.extent
        let width = whole.width / CGFloat(grid), height = whole.height / CGFloat(grid)
        var found: [CGRect] = []
        for column in 0..<grid {
            for row in 0..<grid {
                let tile = CGRect(x: whole.minX + CGFloat(column) * width - width * 0.1, y: whole.minY + CGFloat(row) * height - height * 0.1,
                                  width: width * 1.2, height: height * 1.2).intersection(whole)
                let crop = image.cropped(to: tile).transformed(by: CGAffineTransform(translationX: -tile.minX, y: -tile.minY))
                found += try textPass(crop).map { box in
                    CGRect(x: (tile.minX - whole.minX + box.minX * tile.width) / whole.width,
                           y: (tile.minY - whole.minY + box.minY * tile.height) / whole.height,
                           width: box.width * tile.width / whole.width, height: box.height * tile.height / whole.height)
                }
            }
        }
        return found
    }

    /// A line of text as read: what it says and where (normalized, bottom-left origin).
    struct RecognizedLine: Equatable {
        var text: String
        var box: CGRect
        var quad: [CGPoint]? = nil
        var confidence: Float? = nil
        var fragments: [RecognizedFragment] = []
    }
    struct RecognizedFragment: Equatable {
        var text: String
        var quad: [CGPoint]
    }

    /// Observed character quads corresponding to every normalized phrase occurrence. No guessed
    /// proportional slicing: missing boxes, expanded Unicode mappings, or weak OCR use the line.
    static func phraseEvidence(line: RecognizedLine, phrases: [String]) -> [CGPoint]? {
        guard (line.confidence ?? 0) >= 0.65, validQuad(line.quad) else { return nil }
        let normal = PhraseCover.normalize(line.text)
        let wanted = Array(Set(phrases.map(PhraseCover.normalize).filter { $0.count >= PhraseCover.minimumLength }))
        guard !wanted.isEmpty else { return nil }
        if line.fragments.isEmpty {
            return wanted.contains(normal) ? line.quad : nil
        }
        let pieces = line.fragments.map { PhraseCover.normalize($0.text) }
        guard pieces.joined() == normal else { return nil }
        let characters = Array(normal)
        var selected = Set<Int>()
        for phrase in wanted {
            let needle = Array(phrase)
            guard needle.count <= characters.count else { continue }
            for start in 0...(characters.count - needle.count) where Array(characters[start..<(start + needle.count)]) == needle {
                selected.formUnion(start..<(start + needle.count))
            }
        }
        guard !selected.isEmpty else { return nil }
        var offset = 0, points: [CGPoint] = []
        for (fragment, piece) in zip(line.fragments, pieces) {
            let count = piece.count
            defer { offset += count }
            if (offset..<(offset + count)).contains(where: selected.contains) {
                guard validQuad(fragment.quad) else { return nil }
                points += fragment.quad
            }
        }
        return points.isEmpty || points.count > 512 ? nil : points
    }

    static func validQuad(_ points: [CGPoint]?) -> Bool {
        guard let points, points.count == 4,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 }) else { return false }
        let turns = points.indices.map { index -> CGFloat in
            let a = points[index], b = points[(index + 1) % 4], c = points[(index + 2) % 4]
            return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
        }
        guard turns.allSatisfy({ $0 > 1e-10 }) || turns.allSatisfy({ $0 < -1e-10 }) else { return false }
        let area = abs(zip(points, Array(points.dropFirst()) + [points[0]]).reduce(CGFloat(0)) {
            $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y
        }) / 2
        return area > 1e-10
    }

    /// Lines of text the Vision recognizer reads, whole frame plus 2×2 tiles for large frames.
    /// Used by phrase covering, which needs the words, not only the places. Internal for tests.
    static func recognizedLines(in image: CIImage) throws -> [RecognizedLine] {
        try Task.checkCancellation()
        if max(image.extent.width, image.extent.height) >= 800 {
            let whole = image.extent
            let width = whole.width / 2, height = whole.height / 2
            var crops: [(tile: CGRect, image: CIImage)] = []
            for column in 0..<2 {
                for row in 0..<2 {
                    let tile = CGRect(x: whole.minX + CGFloat(column) * width - width * 0.1, y: whole.minY + CGFloat(row) * height - height * 0.1,
                                      width: width * 1.2, height: height * 1.2).intersection(whole)
                    let crop = image.cropped(to: tile).transformed(by: CGAffineTransform(translationX: -tile.minX, y: -tile.minY))
                    crops.append((tile, crop))
                }
            }
            // The same five requests share one bounded schedule. Including the whole
            // frame overlaps its recognition with the first crop without omitting a pass.
            let passes = try parallelRecognizedPasses([image] + crops.map(\.image), pass: recognizedPass)
            var found = passes[0]
            for (crop, lines) in zip(crops, passes.dropFirst()) {
                let tile = crop.tile
                found += lines.map { line in
                    func transform(_ point: CGPoint) -> CGPoint {
                        CGPoint(x: (tile.minX - whole.minX + point.x * tile.width) / whole.width,
                                y: (tile.minY - whole.minY + point.y * tile.height) / whole.height)
                    }
                    return RecognizedLine(text: line.text, box: CGRect(
                        x: (tile.minX - whole.minX + line.box.minX * tile.width) / whole.width,
                        y: (tile.minY - whole.minY + line.box.minY * tile.height) / whole.height,
                        width: line.box.width * tile.width / whole.width, height: line.box.height * tile.height / whole.height),
                        quad: line.quad?.map(transform), confidence: line.confidence,
                        fragments: line.fragments.map { RecognizedFragment(text: $0.text, quad: $0.quad.map(transform)) })
                }
            }
            return found
        }
        return try recognizedPass(image)
    }

    /// Vision owns separate requests/handlers per image. Keep at most two live
    /// requests and publish in original input order. Only the caller replenishes
    /// slots, so cancellation or an observed failure stops further submissions.
    static func parallelRecognizedPasses(_ images: [CIImage],
                                        pass: @escaping (CIImage) throws -> [RecognizedLine]) throws -> [[RecognizedLine]] {
        let batch = RecognitionBatch(count: images.count)
        var next = 0, inFlight = 0
        var cancelled = false, failed = false
        func checkCancellation() {
            do { try Task.checkCancellation() }
            catch { cancelled = true }
        }
        func submitNext() {
            let index = next
            next += 1
            inFlight += 1
            DispatchQueue.global(qos: .userInitiated).async {
                batch.complete(Result { try pass(images[index]) }, at: index)
            }
        }
        // Dispatch workers do not inherit the caller's Task. Check cancellation
        // on this caller before each submission and after every completion.
        checkCancellation()
        for _ in 0..<min(2, images.count) {
            checkCancellation()
            if cancelled { break }
            submitNext()
        }
        while inFlight > 0 {
            let result = batch.takeCompleted()
            inFlight -= 1
            if case .failure = result { failed = true }
            checkCancellation()
            if !cancelled, !failed, next < images.count { submitNext() }
        }
        // Every already submitted Vision request finishes normally, including on
        // cancellation or failure. Never publish partial results or orphan work.
        if cancelled { throw CancellationError() }
        return try images.indices.map { try batch.get($0) }
    }

    private final class RecognitionBatch {
        private let condition = NSCondition()
        private var results: [Result<[RecognizedLine], Error>?]
        private var completed: [Int] = []
        init(count: Int) { results = Array(repeating: nil, count: count) }
        func complete(_ result: Result<[RecognizedLine], Error>, at index: Int) {
            condition.lock(); defer { condition.unlock() }
            results[index] = result
            completed.append(index)
            condition.signal()
        }
        func takeCompleted() -> Result<[RecognizedLine], Error> {
            condition.lock(); defer { condition.unlock() }
            while completed.isEmpty { condition.wait() }
            let index = completed.removeFirst()
            return results[index]!
        }
        func get(_ index: Int) throws -> [RecognizedLine] {
            condition.lock(); defer { condition.unlock() }
            guard let result = results[index] else { throw DetectError.visionFailed }
            return try result.get()
        }
    }

    static func recognizedPass(_ image: CIImage) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0
        do { try VNImageRequestHandler(ciImage: image, options: [:]).perform([request]) }
        catch { throw DetectError.visionFailed }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string
            func quad(_ rectangle: VNRectangleObservation) -> [CGPoint] {
                [rectangle.bottomLeft, rectangle.bottomRight, rectangle.topRight, rectangle.topLeft]
            }
            var fragments: [RecognizedFragment] = []
            if text.count <= 128 {
                var index = text.startIndex
                while index < text.endIndex {
                    let end = text.index(after: index)
                    let range = index..<end
                    // Empty quads deliberately retain the character: phraseEvidence can then
                    // reject an incomplete matching range instead of silently omitting it.
                    let rectangle = try? candidate.boundingBox(for: range)
                    fragments.append(.init(text: String(text[range]), quad: rectangle.map(quad) ?? []))
                    index = end
                }
            }
            return RecognizedLine(text: text, box: observation.boundingBox, quad: quad(observation),
                                  confidence: candidate.confidence, fragments: fragments)
        }
    }

    /// Joins padded text boxes that touch into one cover per sign or line group, but only while the
    /// joined cover stays compact: at most 30% more area than the text boxes it is made of actually
    /// cover. Each cover keeps its original boxes, so steps of slanted signs cannot add up their
    /// slack into one huge cover. Internal for tests.
    static func mergedText(_ input: [CGRect]) -> [CGRect] {
        // The passes report nearly the same box several times; fold those first so dense pages stay cheap.
        var parts: [CGRect] = []
        for box in input where box.width > 0 && box.height > 0 {
            if let index = parts.firstIndex(where: { overlap($0, box) >= 0.7 }) { parts[index] = parts[index].union(box) }
            else { parts.append(box) }
        }
        struct Group { var cover: CGRect; var parts: [CGRect]; var area: CGFloat }
        var groups = parts.map { Group(cover: $0, parts: [$0], area: $0.width * $0.height) }
        /// The two groups as one, if that stays compact. Covered area grows by B minus what A already covers.
        func joined(_ a: Group, _ b: Group) -> Group? {
            var shared: [CGRect] = []
            for x in a.parts where x.intersects(b.cover) {
                for y in b.parts where x.intersects(y) { shared.append(x.intersection(y)) }
            }
            let area = a.area + b.area - unionArea(shared), cover = a.cover.union(b.cover)
            guard cover.width * cover.height <= area * 1.3 else { return nil }
            return Group(cover: cover, parts: a.parts + b.parts, area: area)
        }
        var changed = true
        while changed {
            changed = false
            var a = 0
            while a < groups.count {
                var b = a + 1
                while b < groups.count {
                    if groups[a].cover.intersects(groups[b].cover), let group = joined(groups[a], groups[b]) {
                        groups[a] = group
                        groups.remove(at: b)
                        changed = true
                        b = a + 1 // it grew; look at the rest again
                    } else {
                        b += 1
                    }
                }
                a += 1
            }
        }
        return groups.map(\.cover)
    }

    /// Area covered by any of `rects` (overlaps counted once), by strips between their x edges.
    static func unionArea(_ rects: [CGRect]) -> CGFloat {
        let edges = Array(Set(rects.flatMap { [$0.minX, $0.maxX] })).sorted()
        var area: CGFloat = 0
        for (left, right) in zip(edges, edges.dropFirst()) where right > left {
            let spans = rects.filter { $0.minX <= left && $0.maxX >= right }.map { ($0.minY, $0.maxY) }.sorted { $0.0 < $1.0 }
            var covered: CGFloat = 0, reach = -CGFloat.infinity
            for (low, high) in spans where high > reach {
                covered += high - max(low, reach)
                reach = high
            }
            area += covered * (right - left)
        }
        return area
    }

    /// The displayed (orientation-applied) frame of a video at `time`.
    static func frame(of url: URL, at time: Double) async throws -> CIImage {
        let generator = AVAssetImageGenerator(asset: VideoAssetPolicy.asset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        do {
            let image = try await generator.image(at: CMTime(seconds: max(0, time), preferredTimescale: 600)).image
            return CIImage(cgImage: image)
        } catch { throw DetectError.frameUnavailable }
    }

    /// The box of the person under `point` (normalized, bottom-left origin) on this frame, or nil when
    /// no person is there. Uses Vision's person-instance mask; it finds people, not who they are.
    static func personBox(in image: CIImage, at point: CGPoint) throws -> CGRect? {
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        let request = VNGeneratePersonInstanceMaskRequest()
        do { try handler.perform([request]) } catch { throw DetectError.visionFailed }
        guard let observation = request.results?.first else { return nil }
        let instance = Int(instanceLabel(in: observation.instanceMask, at: point))
        guard instance != 0 else { return nil }
        let mask: CVPixelBuffer
        do { mask = try observation.generateScaledMaskForImage(forInstances: IndexSet(integer: instance), from: handler) }
        catch { throw DetectError.visionFailed }
        return maskBox(mask)
    }

    /// Instance label (0 = background) under a normalized, bottom-left point of the label mask.
    static func instanceLabel(in labels: CVPixelBuffer, at point: CGPoint) -> UInt8 {
        CVPixelBufferLockBaseAddress(labels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(labels, .readOnly) }
        let width = CVPixelBufferGetWidth(labels), height = CVPixelBufferGetHeight(labels)
        guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(labels), point.x.isFinite, point.y.isFinite else { return 0 }
        let column = min(width - 1, max(0, Int(point.x * CGFloat(width))))
        let row = min(height - 1, max(0, Int((1 - point.y) * CGFloat(height))))
        return base.advanced(by: row * CVPixelBufferGetBytesPerRow(labels)).assumingMemoryBound(to: UInt8.self)[column]
    }

    /// Tight box of the pixels that belong to the instance (rows from the top, as the mask is upright).
    static func maskBox(_ mask: CVPixelBuffer) -> CGRect? {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        let width = CVPixelBufferGetWidth(mask), height = CVPixelBufferGetHeight(mask)
        guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(mask)
        var left = width, right = -1, top = height, bottom = -1
        for row in 0..<height {
            let line = base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
            for column in 0..<width where line[column] >= 128 {
                left = min(left, column); right = max(right, column)
                top = min(top, row); bottom = max(bottom, row)
            }
        }
        guard right >= left, bottom >= top else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        return CGRect(x: CGFloat(left) / w, y: 1 - CGFloat(bottom + 1) / h,
                      width: CGFloat(right - left + 1) / w, height: CGFloat(bottom - top + 1) / h)
    }

    /// Intersection over union of two boxes (0 when they do not overlap).
    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let i = inter.width * inter.height
        return i / (a.width * a.height + b.width * b.height - i)
    }
}

extension CGRect {
    /// At least `side` wide and high (normalized), same center where possible, kept inside 0...1.
    func grown(toAtLeast side: CGFloat) -> CGRect {
        var grown = self
        if width < side { grown.origin.x = Swift.min(Swift.max(0, midX - side / 2), 1 - side); grown.size.width = side }
        if height < side { grown.origin.y = Swift.min(Swift.max(0, midY - side / 2), 1 - side); grown.size.height = side }
        return grown
    }

    var clampedToUnit: CGRect {
        let x0 = min(max(0, minX), 1), y0 = min(max(0, minY), 1)
        let x1 = min(max(0, maxX), 1), y1 = min(max(0, maxY), 1)
        return CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }
}
