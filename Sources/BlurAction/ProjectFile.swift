import Foundation
import CoreGraphics
import UniformTypeIdentifiers

/// Saved editing session (`.bluraction`, JSON). Geometry is normalized to a 1×1 canvas so a
/// project reopens correctly at any window size. The media file itself is referenced, not copied.
struct ProjectFile: Codable, Equatable {
    struct Region: Codable, Equatable {
        var shape: RegionShape
        var effect: RegionEffect
    }

    static let fileExtension = "bluraction"
    static let currentVersion = 1
    static let maximumBytes = 20 * 1024 * 1024
    static var contentType: UTType { UTType(filenameExtension: fileExtension) ?? .json }

    var version = currentVersion
    var mediaPath: String
    var regions: [Region]
    var drawings: [DrawingAnnotation]

    enum ProjectError: LocalizedError {
        case tooLarge, unsupportedVersion, invalidContent
        var errorDescription: String? {
            switch self {
            case .tooLarge: return "프로젝트 파일이 너무 큽니다."
            case .unsupportedVersion: return "이 버전의 BlurAction이 열 수 없는 프로젝트 형식입니다."
            case .invalidContent: return "프로젝트 파일 내용이 올바르지 않습니다."
            }
        }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Decodes and checks an untrusted project: bounded counts, finite in-range numbers.
    static func decode(_ data: Data) throws -> ProjectFile {
        guard data.count <= maximumBytes else { throw ProjectError.tooLarge }
        let project: ProjectFile
        do { project = try JSONDecoder().decode(ProjectFile.self, from: data) } catch { throw ProjectError.invalidContent }
        guard project.version == currentVersion else { throw ProjectError.unsupportedVersion }
        guard project.isValid else { throw ProjectError.invalidContent }
        return project
    }

    private var isValid: Bool {
        // Normalized coordinates may extend a little past the frame; anything wild is rejected.
        func ok(_ v: CGFloat) -> Bool { v.isFinite && abs(v) <= 16 }
        func ok(_ p: CGPoint) -> Bool { ok(p.x) && ok(p.y) }
        func ok(_ r: CGRect) -> Bool { ok(r.origin) && ok(r.width) && ok(r.height) && r.width >= 0 && r.height >= 0 }
        func ok(_ t: ClosedRange<Double>) -> Bool { t.lowerBound.isFinite && t.upperBound.isFinite && t.lowerBound >= 0 }
        func ok(_ frames: [RegionKeyframe]) -> Bool {
            frames.count <= 100_000 && frames.allSatisfy { $0.time.isFinite && $0.time >= 0 && ok($0.rect) }
        }
        guard !mediaPath.isEmpty, mediaPath.count <= 4096, !mediaPath.contains("\0"),
              regions.count <= 1_000, drawings.count <= 5_000 else { return false }
        for region in regions {
            let effect = region.effect
            guard ok(region.shape.boundingRect), ok(effect.timeRange), ok(effect.keyframes), effect.color.isValid,
                  effect.blurRadius.isFinite, (0...500).contains(effect.blurRadius),
                  effect.featherRadius.isFinite, (0...500).contains(effect.featherRadius) else { return false }
            if case .polygon(_, let points) = region.shape, points.count > 100_000 || !points.allSatisfy(ok) { return false }
        }
        for drawing in drawings {
            guard drawing.points.count <= 100_000, drawing.points.allSatisfy(ok), ok(drawing.timeRange), ok(drawing.keyframes),
                  RGBAColor(red: drawing.red, green: drawing.green, blue: drawing.blue, alpha: drawing.alpha).isValid,
                  drawing.lineWidth.isFinite, drawing.lineWidth > 0, drawing.lineWidth <= 1,
                  drawing.fillOpacity.isFinite, (0...1).contains(drawing.fillOpacity),
                  drawing.text.count <= 1_000 else { return false }
        }
        return true
    }
}
