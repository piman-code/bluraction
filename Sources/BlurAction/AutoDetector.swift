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

    /// Reads text two ways: recognized lines (accurate, Korean first, so whole Hangul lines are boxed;
    /// fast mode clips the first syllables of Korean name tags) and text-shaped areas that cannot be
    /// read (decorative, vertical or slanted sign lettering).
    private static func textPass(_ image: CIImage) throws -> [CGRect] {
        try Task.checkCancellation() // 취소 stops between passes
        let lines = VNRecognizeTextRequest()
        lines.recognitionLevel = .accurate
        lines.recognitionLanguages = ["ko-KR", "en-US"]
        lines.usesLanguageCorrection = false
        lines.minimumTextHeight = 0
        let shapes = VNDetectTextRectanglesRequest()
        do { try VNImageRequestHandler(ciImage: image, options: [:]).perform([lines, shapes]) }
        catch { throw DetectError.visionFailed }
        return (lines.results ?? []).map(\.boundingBox) + (shapes.results ?? []).map(\.boundingBox)
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
