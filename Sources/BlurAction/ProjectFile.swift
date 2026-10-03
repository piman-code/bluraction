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
    /// The media file name when it sits next to the project (keeps usernames out of shared
    /// projects), otherwise an absolute path.
    var mediaPath: String
    var regions: [Region]
    var drawings: [DrawingAnnotation]
    /// Optional backward-compatible v1 integrity extension used by both OS adapters.
    var sourceSHA256: String? = nil

    enum ProjectError: LocalizedError {
        case tooLarge, unsupportedVersion, invalidContent, sourceNeedsRelink
        var errorDescription: String? {
            switch self {
            case .tooLarge: return "프로젝트 파일이 너무 큽니다."
            case .unsupportedVersion: return "이 버전의 BlurAction이 열 수 없는 프로젝트 형식입니다."
            case .invalidContent: return "프로젝트 파일 내용이 올바르지 않습니다."
            case .sourceNeedsRelink: return "다른 OS에서 저장했거나 이동한 원본입니다. 원본 파일을 다시 연결하세요."
            }
        }
    }

    static func mediaReference(for media: URL, projectURL: URL?) -> String {
        guard let projectURL,
              media.deletingLastPathComponent().standardizedFileURL == projectURL.deletingLastPathComponent().standardizedFileURL
        else { return media.path }
        return media.lastPathComponent
    }

    /// Resolves `mediaPath` against the project's folder when it is a bare file name.
    func mediaURL(relativeTo projectURL: URL?) -> URL {
        if mediaPath.hasPrefix("/") || projectURL == nil { return URL(fileURLWithPath: mediaPath) }
        let name = Self.portableFileName(mediaPath) // never climb out of the folder, either OS separator
        return projectURL!.deletingLastPathComponent().appendingPathComponent(name)
    }

    static func portableFileName(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last ?? path
    }

    var needsPlatformRelink: Bool {
        let bytes = Array(mediaPath.utf8)
        let drive = bytes.count >= 2 && ((65...90).contains(bytes[0]) || (97...122).contains(bytes[0])) && bytes[1] == 58
        return drive || mediaPath.hasPrefix("\\") || mediaPath.hasPrefix("//")
    }

    func validateSource(_ url: URL) throws {
        if let expected = sourceSHA256, try PageWorkspace.digest(of: url) != expected {
            throw PageWorkspace.WorkspaceError.sourceChanged
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
        guard sourceSHA256.map({ $0.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }) ?? true,
              !mediaPath.isEmpty, mediaPath.count <= 4096, !mediaPath.contains("\0"),
              regions.count <= 1_000, drawings.count <= 5_000 else { return false }
        // Every item needs its own ID: editing code indexes items by ID.
        let ids = regions.map(\.shape.id) + drawings.map(\.id)
        guard Set(ids).count == ids.count else { return false }
        for region in regions {
            let effect = region.effect
            guard ok(region.shape.boundingRect), ok(effect.timeRange), ok(effect.keyframes), effect.color.isValid,
                  effect.blurRadius.isFinite, (0...500).contains(effect.blurRadius),
                  effect.featherRadius.isFinite, (0...500).contains(effect.featherRadius),
                  effect.erasures.count <= 10_000, effect.erasures.allSatisfy({ $0.isValid && $0.width <= 16 && $0.points.allSatisfy(ok) }),
                  (effect.name?.count ?? 0) <= 200 else { return false }
            switch region.shape {
            case .rectangle(_, _, let size), .ellipse(_, _, let size):
                guard size.width >= 0, size.height >= 0 else { return false }
            case .polygon(_, let points):
                guard points.count <= 100_000, points.allSatisfy(ok) else { return false }
            }
        }
        for drawing in drawings {
            guard drawing.points.count <= 100_000, drawing.points.allSatisfy(ok), ok(drawing.timeRange), ok(drawing.keyframes),
                  RGBAColor(red: drawing.red, green: drawing.green, blue: drawing.blue, alpha: drawing.alpha).isValid,
                  drawing.lineWidth.isFinite, drawing.lineWidth > 0, drawing.lineWidth <= 16,
                  drawing.erasures.count <= 10_000,
                  drawing.erasures.allSatisfy({ $0.isValid && $0.width <= 16 && $0.points.allSatisfy(ok) }),
                  (drawing.name?.count ?? 0) <= 200, (drawing.fontName?.count ?? 0) <= 200,
                  drawing.textBackground?.isValid ?? true,
                  drawing.fillOpacity.isFinite, (0...1).contains(drawing.fillOpacity),
                  drawing.text.count <= 1_000 else { return false }
        }
        return true
    }
}
