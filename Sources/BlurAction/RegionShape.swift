import Foundation
import CoreGraphics

/// 영역 단위: 사각형 또는 자유형 폴리곤. 캔버스 BOTTOM-LEFT 좌표 기준.
enum RegionShape: Equatable, Identifiable, Codable {
    case rectangle(id: UUID, origin: CGPoint, size: CGSize)
    case ellipse(id: UUID, origin: CGPoint, size: CGSize) // 원형/타원. size.w == size.h 이면 원
    case polygon(id: UUID, points: [CGPoint])

    var id: UUID {
        switch self {
        case .rectangle(let id, _, _): return id
        case .ellipse(let id, _, _): return id
        case .polygon(let id, _): return id
        }
    }

    var boundingRect: CGRect {
        switch self {
        case .rectangle(_, let o, let s):
            return CGRect(origin: o, size: s)
        case .ellipse(_, let o, let s):
            return CGRect(origin: o, size: s)
        case .polygon(_, let pts) where pts.isEmpty:
            return .zero
        case .polygon(_, let pts):
            let xs = pts.map(\.x), ys = pts.map(\.y)
            let minX = xs.min()!, maxX = xs.max()!
            let minY = ys.min()!, maxY = ys.max()!
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    /// 모든 영역을 합친 CGPath. 마스크 합성에 사용.
    func path() -> CGPath {
        let p = CGMutablePath()
        switch self {
        case .rectangle(_, let o, let s):
            p.addRect(CGRect(origin: o, size: s))
        case .ellipse(_, let o, let s):
            p.addEllipse(in: CGRect(origin: o, size: s))
        case .polygon(_, let pts):
            guard let first = pts.first else { return p }
            p.move(to: first)
            for pt in pts.dropFirst() { p.addLine(to: pt) }
            p.closeSubpath()
        }
        return p
    }

    /// 점이 이 영역 안에 있는지 (다각형 hit test 포함).
    /// - threshold: 점 편집 시 hit 거리(px) — 작은 폴리곤도 잡힘
    func contains(point pt: CGPoint, threshold: CGFloat = 6) -> Bool {
        switch self {
        case .rectangle(_, let o, let s):
            return CGRect(origin: o, size: s).insetBy(dx: -threshold, dy: -threshold).contains(pt)
        case .ellipse(_, let o, let s):
            let rect = CGRect(origin: o, size: s)
            let cx = rect.midX, cy = rect.midY
            let rx = max(0.001, rect.width / 2)
            let ry = max(0.001, rect.height / 2)
            let dx = (pt.x - cx) / rx
            let dy = (pt.y - cy) / ry
            let d2 = dx * dx + dy * dy
            // threshold 비율을 ellipse 반경에 맞춰 적용 (반지름이 클수록 threshold 픽셀도 커짐)
            let r = min(rx, ry)
            let t = max(0, threshold) / r
            return d2 <= (1.0 + t) * (1.0 + t)
        case .polygon(_, let pts):
            // 1) 꼭짓점에 가까우면 포함
            for v in pts {
                let dx = v.x - pt.x, dy = v.y - pt.y
                if (dx * dx + dy * dy).squareRoot() <= threshold { return true }
            }
            // 2) 변 위에 가까우면 포함 (segment-point distance)
            if pts.count >= 2 {
                for i in 0..<pts.count {
                    let a = pts[i]
                    let b = pts[(i + 1) % pts.count]
                    if distanceToSegment(pt, a, b) <= threshold { return true }
                }
            }
            // 3) 내부 (ray casting)
            guard pts.count >= 3 else { return false }
            var inside = false
            var j = pts.count - 1
            for i in 0..<pts.count {
                let xi = pts[i].x, yi = pts[i].y
                let xj = pts[j].x, yj = pts[j].y
                let intersect = ((yi > pt.y) != (yj > pt.y)) &&
                    (pt.x < (xj - xi) * (pt.y - yi) / ((yj - yi) == 0 ? 0.0001 : (yj - yi)) + xi)
                if intersect { inside.toggle() }
                j = i
            }
            return inside
        }
    }

    private func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else {
            let ex = p.x - a.x, ey = p.y - a.y
            return (ex * ex + ey * ey).squareRoot()
        }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
        t = max(0, min(1, t))
        let cx = a.x + t * dx, cy = a.y + t * dy
        let ex = p.x - cx, ey = p.y - cy
        return (ex * ex + ey * ey).squareRoot()
    }
}

/// 영역 단위 효과.
struct RegionEffect: Equatable, Codable {
    /// 0 = 비활성 (전체 영상 동안 블러 안 함). 0 초과 = 강도.
    var blurRadius: CGFloat = 25.0
    /// 테두리 feather (마스크 가장자리 부드럽게), 0~50 px.
    var featherRadius: CGFloat = 12.0
    /// 블러 적용 시간 구간 (영상 시간, 초). 닫힌 구간. 0...0만 전체 적용 표식.
    var timeRange: ClosedRange<Double> = 0.0...0.0
    /// 영역 활성화 여부 (false 면 내보내기/미리보기에서 제외)
    var enabled: Bool = true
    /// 영역의 시간별 위치 키프레임. 시간순 정렬 가정.
    /// 비어있으면 keyframes 미사용 (현재 동작 유지).
    /// - 사용 예: ▶ 재생 중 영역 이동 → 30Hz 자동 기록 → 시간대별 블러 위치 추적.
    var keyframes: [RegionKeyframe] = []
    /// How the region hides content. `blurRadius` is the blur strength or mosaic cell size.
    var style: CoverStyle = .blur
    /// Fill for `.solid`, sRGB components.
    var color: RGBAColor = .black

    /// Items sharing a group move together.
    var groupID: UUID?

    enum CoverStyle: String, Equatable, CaseIterable, Codable { case blur, mosaic, solid }

    static func alwaysOn() -> RegionEffect {
        RegionEffect(blurRadius: 25, featherRadius: 12, timeRange: 0.0...0.0, enabled: true)
    }

    var appliesToEntireVideo: Bool { timeRange.lowerBound == 0 && timeRange.upperBound == 0 }

    /// A zero-length interval at a nonzero EOF is never the whole-video sentinel.
    static func created(at time: Double?, videoDuration: Double?) -> RegionEffect {
        guard let duration = videoDuration else { return .alwaysOn() }
        guard duration.isFinite, duration > 0, let time, time.isFinite else {
            var effect = alwaysOn()
            effect.enabled = false
            return effect
        }
        var effect = alwaysOn()
        effect.timeRange = min(duration, max(0, time))...duration
        return effect
    }

    static func durationRange(startingAt time: Double, seconds: Double,
                              videoDuration: Double) -> ClosedRange<Double>? {
        guard time.isFinite, seconds.isFinite, seconds > 0,
              videoDuration.isFinite, videoDuration > 0 else { return nil }
        let start = min(videoDuration, max(0, time))
        guard start < videoDuration else { return nil }
        return start...min(videoDuration, start + seconds)
    }
}

/// 키프레임: 특정 시간에 영역의 사각형 위치 (캔버스 좌표).
struct RegionKeyframe: Equatable, Codable {
    var time: Double  // seconds
    var rect: NSRect  // canvas coords
}

/// 영역의 시간별 위치 계산. 키프레임이 없으면 baseRect 그대로, 있으면 선형 보간.
extension RegionShape {
    /// 시간 t에서 영역의 bounding rect.
    /// - baseRect: 키프레임 없을 때 (또는 모든 키프레임 이전 시간) 사용할 영역의 원래 위치.
    /// - keyframes: 시간순 정렬된 키프레임 리스트.
    func interpolatedRect(at t: Double, baseRect: NSRect, keyframes: [RegionKeyframe]) -> NSRect {
        MotionTrack.rect(at: t, base: baseRect, keyframes: keyframes)
    }

    /// Preserve identity and map polygon vertices affinely between bounding rectangles.
    func replacing(rect newRect: NSRect) -> RegionShape {
        switch self {
        case .rectangle(let id, _, _):
            return .rectangle(id: id, origin: newRect.origin, size: newRect.size)
        case .ellipse(let id, _, _):
            return .ellipse(id: id, origin: newRect.origin, size: newRect.size)
        case .polygon(let id, let points):
            let old = boundingRect
            return .polygon(id: id, points: points.map { p in
                CGPoint(x: newRect.minX + (old.width > 0 ? (p.x - old.minX) / old.width * newRect.width : 0),
                        y: newRect.minY + (old.height > 0 ? (p.y - old.minY) / old.height * newRect.height : 0))
            })
        }
    }
}

/// 내보내기 화질 프리셋.
enum QualityPreset: String, CaseIterable, Identifiable {
    case original = "원본"
    case high = "고품질"
    case medium = "중간"
    case low = "낮음"
    var id: String { rawValue }

    /// 권장 비트레이트 (bps). 영상 크기·fps와 곱해 총 비트레이트 계산.
    /// original = 비디오 자체 비트레이트 추정 (실제론 입력 메타데이터 사용).
    /// 나머지는 픽셀당 약초당 비트 전송률.
    var bitsPerPixelPerSecond: Double {
        switch self {
        case .original: return 0   // 0 = 입력 비트레이트 사용
        case .high:     return 0.10
        case .medium:   return 0.05
        case .low:      return 0.025
        }
    }
}

extension RegionEffect {
    /// nil time is a still image: ignore time range and motion keyframes.
    func shape(_ base: RegionShape, at time: Double?) -> RegionShape {
        guard let time else { return base }
        return base.replacing(rect: base.interpolatedRect(at: time, baseRect: base.boundingRect, keyframes: keyframes))
    }

    func isActive(at time: Double?) -> Bool {
        guard enabled, blurRadius.isFinite, style == .solid || blurRadius > 0 else { return false }
        guard let time else { return true }
        guard time.isFinite else { return false }
        return appliesToEntireVideo || timeRange.contains(time)
    }
}

/// Plain sRGB color value that stays Equatable and renderer-friendly.
struct RGBAColor: Equatable, Codable {
    var red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat
    static let black = RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)

    var isValid: Bool { [red, green, blue, alpha].allSatisfy { $0.isFinite && (0...1).contains($0) } }
}
