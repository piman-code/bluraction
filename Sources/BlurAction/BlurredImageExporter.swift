import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Darwin

/// Synchronous image export; callers choose their execution queue and surface thrown errors.
enum BlurredImageExporter {
    enum ExportError: LocalizedError {
        case invalidInput, unsupportedType, destinationExists, encodeFailed
        var errorDescription: String? {
            switch self {
            case .invalidInput: return "이미지 크기, 품질 또는 저장 경로가 올바르지 않습니다."
            case .unsupportedType: return "이 이미지 형식으로 저장할 수 없습니다."
            case .destinationExists: return "원본이나 기존 파일을 덮어쓸 수 없습니다. 새 파일 이름을 선택하세요."
            case .encodeFailed: return "이미지 인코딩에 실패했습니다. 파일이 저장되지 않았습니다."
            }
        }
    }

    static func export(source: CGImage,
                       pairs: [(shape: RegionShape, effect: RegionEffect)],
                       canvasSize: CGSize, inputURL: URL, outputURL: URL,
                       type: UTType, quality: Double, annotations: [DrawingAnnotation] = [],
                       expectedSourceSHA256: String? = nil) throws {
        guard inputURL.isFileURL, outputURL.isFileURL,
              !inputURL.path.utf8.contains(0), !outputURL.path.utf8.contains(0),
              canvasSize.width.isFinite, canvasSize.height.isFinite,
              canvasSize.width > 0, canvasSize.height > 0,
              quality.isFinite, (0...1).contains(quality) else { throw ExportError.invalidInput }
        guard [UTType.png, .jpeg, .heic, .tiff].contains(type),
              (CGImageDestinationCopyTypeIdentifiers() as! [String]).contains(type.identifier) else {
            throw ExportError.unsupportedType
        }
        // Resolve the parent once, but never follow a destination leaf symlink.
        let output = outputURL.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(outputURL.lastPathComponent)
        guard inputURL.resolvingSymlinksInPath().standardizedFileURL != output.standardizedFileURL else {
            throw ExportError.destinationExists
        }
        var status = stat()
        guard lstat(output.path, &status) != 0 else { throw ExportError.destinationExists }
        guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if let expectedSourceSHA256, try PageWorkspace.digest(of: inputURL) != expectedSourceSHA256 {
            throw PageWorkspace.WorkspaceError.sourceChanged
        }

        let image = try BlurRenderer.render(image: CIImage(cgImage: source), pairs: pairs,
                                            canvasSize: canvasSize, time: nil, annotations: annotations)
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        guard let pixels = CIContext().createCGImage(image, from: bounds) else {
            throw ExportError.encodeFailed
        }
        var template = Array(output.deletingLastPathComponent()
            .appendingPathComponent(".blur-action-XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        close(descriptor)
        let temporary = URL(fileURLWithPath: String(cString: template))
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL,
                type.identifier as CFString, 1, nil) else { throw ExportError.encodeFailed }
        // Only fresh orientation/quality metadata: never copy private source metadata.
        CGImageDestinationAddImage(destination, pixels, [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: 1
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encodeFailed }
        if let expectedSourceSHA256, try PageWorkspace.digest(of: inputURL) != expectedSourceSHA256 {
            throw PageWorkspace.WorkspaceError.sourceChanged
        }
        // Atomic no-replace rename also closes the destination-existence race.
        guard renamex_np(temporary.path, output.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw ExportError.destinationExists }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
