import CoreGraphics
import Foundation
import Testing
@testable import BlurAction

struct AutomaticCoverTests {
    private let base = RegionShape.rectangle(id: UUID(), origin: CGPoint(x: 100, y: 80), size: CGSize(width: 240, height: 160))
    private let quad = [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.75, y: 0.4), CGPoint(x: 0.7, y: 0.65), CGPoint(x: 0.2, y: 0.5)]
    private func cover(_ kind: AutomaticCover.Kind = .text) -> AutomaticCover {
        AutomaticCover(kind: kind, evidencePoints: quad, sourceSize: CGSize(width: 1200, height: 800),
                       baseNormalizedSize: CGSize(width: 0.2, height: 0.2))
    }
    private func mapped(_ point: CGPoint, _ box: CGRect) -> CGPoint {
        CGPoint(x: box.minX + point.x * box.width, y: box.minY + point.y * box.height)
    }

    @Test func rotatedTextAndFaceEncloseAllEvidenceWithSafetyPadding() {
        for kind in [AutomaticCover.Kind.face, .text] {
            let c = cover(kind), shape = c.shape(base: base, rect: base.boundingRect, time: nil, reviews: [])
            for p in quad { #expect(shape.contains(point: mapped(p, base.boundingRect), threshold: 0)) }
            #expect(shape.boundingRect.width < base.boundingRect.width)
            #expect(shape.id == base.id)
            if kind == .text {
                guard case .polygon(_, let points) = shape else { Issue.record("Text must use an oriented polygon"); return }
                #expect(abs(points[1].y - points[0].y) > 0.1)
            }
        }
    }

    @Test func marginScalesWithCanvasAndMaximumMarginNeverExposesEvidence() {
        var c = cover(); c.safetyMargin = 32
        let original = c.shape(base: base, rect: base.boundingRect, time: nil, reviews: [])
        let scaledBox = CGRect(x: 200, y: 160, width: 480, height: 320)
        let resized = c.shape(base: base.replacing(rect: scaledBox), rect: scaledBox, time: nil, reviews: [])
        #expect(abs(resized.boundingRect.width - original.boundingRect.width * 2) < 0.0001)
        #expect(abs(resized.boundingRect.height - original.boundingRect.height * 2) < 0.0001)
        for p in quad { #expect(resized.contains(point: mapped(p, scaledBox), threshold: 0)) }
    }

    @Test func fallbackContainsRecommendedAtMaximumMarginAndRecoversWithoutClipping() {
        var c = cover(); c.safetyMargin = 32
        let review = TrackingReview(start: 1, end: 2, reason: .recognitionGap)
        let tight = c.shape(base: base, rect: base.boundingRect, time: 0, reviews: [review])
        let wide = c.shape(base: base, rect: base.boundingRect, time: 1, reviews: [review])
        #expect(wide.boundingRect.contains(tight.boundingRect))
        #expect(wide.boundingRect.contains(base.boundingRect))
        for time in [2.1, 2.5, 3.0, 3.9] {
            let recovery = c.shape(base: base, rect: base.boundingRect, time: time, reviews: [review])
            #expect(recovery.boundingRect.contains(tight.boundingRect))
            for p in quad { #expect(recovery.contains(point: mapped(p, base.boundingRect), threshold: 0)) }
        }
        #expect(c.shape(base: base, rect: base.boundingRect, time: 4, reviews: [review]) == tight)
        c.mode = .generous
        #expect(c.shape(base: base, rect: base.boundingRect, time: 1, reviews: [review]) == base)
    }

    @Test func uncertainFaceKeepsEllipticalShapeAndContainsDenseOffsetBoundariesDuringRecovery() {
        let legacy = RegionShape.ellipse(id: UUID(), origin: CGPoint(x: 100, y: 80), size: CGSize(width: 240, height: 160))
        var c = cover(.face); c.safetyMargin = 32
        c.evidencePoints = [CGPoint(x: 0.12, y: 0.22), CGPoint(x: 0.4, y: 0.25),
                            CGPoint(x: 0.42, y: 0.66), CGPoint(x: 0.15, y: 0.7)]
        let review = TrackingReview(start: 1, end: 2, reason: .lostTarget)
        let tight = c.shape(base: legacy, rect: legacy.boundingRect, time: 0, reviews: [review])
        func boundary(_ shape: RegionShape) -> [CGPoint] {
            let r = shape.boundingRect
            return (0..<720).map { index in
                let angle = CGFloat(index) / 720 * 2 * .pi
                return CGPoint(x: r.midX + cos(angle) * r.width / 2,
                               y: r.midY + sin(angle) * r.height / 2)
            }
        }
        let uncertainty = c.shape(base: legacy, rect: legacy.boundingRect, time: 1.5, reviews: [review])
        guard case .ellipse = uncertainty else { Issue.record("Face fallback must remain an ellipse"); return }
        for p in boundary(legacy) + boundary(tight) {
            #expect(uncertainty.contains(point: p, threshold: 0.000001))
        }
        for time in [2.1, 2.5, 3, 3.9] {
            let recovery = c.shape(base: legacy, rect: legacy.boundingRect, time: time, reviews: [review])
            guard case .ellipse = recovery else { Issue.record("Face recovery must remain an ellipse"); return }
            for p in boundary(tight) { #expect(recovery.contains(point: p, threshold: 0.000001)) }
        }
        #expect(c.shape(base: legacy, rect: legacy.boundingRect, time: 4, reviews: [review]) == tight)
    }

    @Test func movingOrientationUsesConservativeEndpointHullAndKeepsCanvasDisplayInSync() {
        var c = cover()
        let shifted = quad.map { CGPoint(x: $0.x + 0.08, y: $0.y - 0.08) }
        c.evidenceKeyframes = [.init(time: 0, points: quad), .init(time: 1, points: shifted)]
        var effect = RegionEffect.alwaysOn(); effect.automaticCover = c
        let rendered = effect.shape(base, at: 0.5)
        #expect(RegionEditing.displayed((base, effect), at: 0.5) == rendered)
        for p in quad + shifted { #expect(rendered.contains(point: mapped(p, base.boundingRect), threshold: 0)) }
    }

    @Test func manualEditMaterializesGeometryAndStopsAutomaticReapplication() throws {
        var effect = RegionEffect.alwaysOn(); effect.automaticCover = cover()
        let shown = effect.shape(base, at: nil)
        let edited = shown.replacing(rect: shown.boundingRect.offsetBy(dx: 15, dy: -8))
        let result = try #require(RegionEditing.updating([edited], in: [(base, effect)], time: nil, recording: false).first)
        #expect(result.effect.automaticCover == nil)
        #expect(result.shape == edited)
        #expect(RegionEditing.displayed(result, at: nil) == edited)
    }

    @Test func pixelMarginStaysEightWhenTrackedBoxShrinks() {
        var c = cover()
        c.evidencePoints = [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.75, y: 0.25),
                            CGPoint(x: 0.75, y: 0.75), CGPoint(x: 0.25, y: 0.75)]
        for ratio: CGFloat in [0.5, 1, 2] {
            let box = CGRect(x: 100, y: 80, width: 240 * ratio, height: 160 * ratio)
            let bounds = c.shape(base: base, rect: box, time: nil, reviews: []).boundingRect
            // The baseline canvas uses one canvas point per source pixel. Changing only
            // the tracked box must not scale the source-pixel margin.
            #expect(abs(bounds.width - (box.width * 0.5 + 16)) < 0.0001)
            #expect(abs(bounds.height - (box.height * 0.5 + 16)) < 0.0001)
        }
    }

    @Test func manuallyEditingRotatingVideoKeepsOtherAnchorsContaining() throws {
        var c = cover()
        let vertical = [CGPoint(x: 0.4, y: 0.1), CGPoint(x: 0.6, y: 0.1),
                        CGPoint(x: 0.6, y: 0.9), CGPoint(x: 0.4, y: 0.9)]
        c.evidenceKeyframes = [.init(time: 0, points: quad), .init(time: 1, points: vertical)]
        var effect = RegionEffect.alwaysOn(); effect.automaticCover = c
        effect.keyframes = [.init(time: 0, rect: base.boundingRect), .init(time: 1, rect: base.boundingRect)]
        let shown = effect.shape(base, at: 0)
        let moved = shown.replacing(rect: shown.boundingRect.offsetBy(dx: 5, dy: 0))
        let edited = try #require(RegionEditing.updating([moved], in: [(base, effect)], time: 0, recording: true).first)
        #expect(edited.effect.automaticCover == nil)
        guard case .rectangle = edited.shape else { Issue.record("Rotating motion must materialize as containing rectangles"); return }
        let later = RegionEditing.displayed(edited, at: 1)
        for p in vertical { #expect(later.contains(point: mapped(p, base.boundingRect), threshold: 0)) }
        let halfway = RegionEditing.displayed(edited, at: 0.5)
        for p in quad + vertical { #expect(halfway.contains(point: mapped(p, base.boundingRect), threshold: 0)) }
    }

    @Test func fileRoundTripRejectsUnknownAndInvalidMetadataAndLeavesPlainFormatUnextended() throws {
        var effect = RegionEffect.alwaysOn(); effect.automaticCover = cover()
        let normalized = base.replacing(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        let project = ProjectFile(mediaPath: "synthetic.png", regions: [.init(shape: normalized, effect: effect)], drawings: [])
        let data = try project.encoded()
        let restored = try ProjectFile.decode(data)
        #expect(restored.version == 5)
        #expect(restored.regions == project.regions)
        let workspace = MultiPageProjectFile(title: "합성", currentIndex: 0,
            pages: [.init(mediaPath: "synthetic.png", regions: project.regions, drawings: [])])
        let reopenedWorkspace = try MultiPageProjectFile.decode(workspace.encoded())
        #expect(reopenedWorkspace.version == 6)
        #expect(reopenedWorkspace.pages[0].regions == project.regions)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var regions = try #require(json["regions"] as? [[String: Any]])
        var storedEffect = try #require(regions[0]["effect"] as? [String: Any])
        var storedCover = try #require(storedEffect["automaticCover"] as? [String: Any])
        storedCover["unexpected"] = true; storedEffect["automaticCover"] = storedCover
        regions[0]["effect"] = storedEffect; json["regions"] = regions
        #expect(throws: (any Error).self) { try ProjectFile.decode(JSONSerialization.data(withJSONObject: json)) }
        storedCover.removeValue(forKey: "unexpected"); storedCover["safetyMargin"] = -1
        storedEffect["automaticCover"] = storedCover; regions[0]["effect"] = storedEffect; json["regions"] = regions
        #expect(throws: (any Error).self) { try ProjectFile.decode(JSONSerialization.data(withJSONObject: json)) }
        effect.automaticCover = nil
        let plain = ProjectFile(mediaPath: "synthetic.png", regions: [.init(shape: normalized, effect: effect)], drawings: [])
        #expect(try ProjectFile.decode(plain.encoded()).version == 1)
        #expect(!String(decoding: try plain.encoded(), as: UTF8.self).contains("automaticCover"))
    }
}
