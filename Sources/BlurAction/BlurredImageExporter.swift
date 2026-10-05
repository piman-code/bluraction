import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Darwin

/// Synchronous image export; callers choose their execution queue and surface thrown errors.
enum BlurredImageExporter {
    enum ExportError: LocalizedError {
        case invalidInput, unsupportedType, destinationExists, encodeFailed, cancelled
        var errorDescription: String? {
            switch self {
            case .invalidInput: return "이미지 크기, 품질 또는 저장 경로가 올바르지 않습니다."
            case .unsupportedType: return "이 이미지 형식으로 저장할 수 없습니다."
            case .destinationExists: return "원본이나 기존 파일을 덮어쓸 수 없습니다. 새 파일 이름을 선택하세요."
            case .encodeFailed: return "이미지 인코딩에 실패했습니다. 파일이 저장되지 않았습니다."
            case .cancelled: return "이미지 저장을 취소했습니다. 파일이 저장되지 않았습니다."
            }
        }
    }

    static func export(source: CGImage,
                       pairs: [(shape: RegionShape, effect: RegionEffect)],
                       canvasSize: CGSize, inputURL: URL, outputURL: URL,
                       type: UTType, quality: Double, annotations: [DrawingAnnotation] = [],
                       expectedSourceSHA256: String? = nil,
                       cancel: (() -> Bool)? = nil,
                       heicCPUHelper: HEICCPUEncoder.Helper? = nil,
                       nativeEncoder: ((CGImage, URL, UTType, Double) throws -> Bool)? = nil) throws {
        func checkpoint() throws { if cancel?() == true { throw ExportError.cancelled } }
        try checkpoint()
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
        try checkpoint()

        let image = try BlurRenderer.render(image: CIImage(cgImage: source), pairs: pairs,
                                            canvasSize: canvasSize, time: nil, annotations: annotations)
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        guard let pixels = CIContext().createCGImage(image, from: bounds) else {
            throw ExportError.encodeFailed
        }
        try checkpoint()
        var template = Array(output.deletingLastPathComponent()
            .appendingPathComponent(".blur-action-XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        close(descriptor)
        let temporary = URL(fileURLWithPath: String(cString: template))
        defer { try? FileManager.default.removeItem(at: temporary) }
        var cpuOriginalSHA256: String?
        let nativeComplete: Bool
        if let nativeEncoder {
            // Internal deterministic failure seam; production callers leave it nil.
            nativeComplete = try nativeEncoder(pixels, temporary, type, quality)
        } else {
            nativeComplete = nativeEncode(pixels, temporary, type, quality)
        }
        try checkpoint()
        if !nativeComplete {
            guard type == .heic else { throw ExportError.encodeFailed }
            // Check the ORIGINAL, before its depth/transfer identity can be lost
            // in flattened RGBA8. The CPU slice must not silently quantize HDR.
            try HEICCPUEncoder.validateColor(source)
            cpuOriginalSHA256 = try validateOriginalCPUColor(inputURL: inputURL,
                expectedSourceSHA256: expectedSourceSHA256, cancel: cancel)
            let encoded: Data
            if let heicCPUHelper {
                encoded = try HEICCPUEncoder.encode(image: pixels, quality: quality,
                    helper: heicCPUHelper, cancel: cancel)
            } else {
                encoded = try HEICCPUEncoder.encode(image: pixels, quality: quality, cancel: cancel)
            }
            try checkpoint()
            try encoded.write(to: temporary)
        }
        try checkpoint()
        if let expectedSourceSHA256, try PageWorkspace.digest(of: inputURL) != expectedSourceSHA256 {
            throw PageWorkspace.WorkspaceError.sourceChanged
        }
        try checkpoint()
        if let cpuOriginalSHA256, try PageWorkspace.digest(of: inputURL) != cpuOriginalSHA256 {
            throw PageWorkspace.WorkspaceError.sourceChanged
        }
        try checkpoint()
        // Atomic no-replace rename also closes the destination-existence race.
        guard renamex_np(temporary.path, output.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw ExportError.destinationExists }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    // currentCGImage is an upright preview that CoreImage may already have
    // converted to RGBA8/sRGB. Inspect the ORIGINAL file before CPU fallback.
    private static func validateOriginalCPUColor(inputURL: URL,
            expectedSourceSHA256: String?, cancel: (() -> Bool)?) throws -> String {
        if cancel?() == true { throw ExportError.cancelled }
        let originalSHA = try PageWorkspace.digest(of: inputURL)
        if let expectedSourceSHA256, originalSHA != expectedSourceSHA256 {
            throw PageWorkspace.WorkspaceError.sourceChanged
        }
        let options = [kCGImageSourceShouldCache: false,
                       kCGImageSourceShouldAllowFloat: true] as CFDictionary
        guard let reader = CGImageSourceCreateWithURL(inputURL as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(reader, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let depth = properties[kCGImagePropertyDepth] as? Int,
              depth > 0, depth <= 8 else { throw HEICCPUEncoder.EncoderError.colorReviewRequired }
        try DocumentModel.validateImageDimensions(width: width, height: height)
        guard width <= 24_000_000 / height else { throw HEICCPUEncoder.EncoderError.invalidInput }
        // An SDR8 base plane can still carry an HDR gain map. The CPU slice
        // does not reproduce this auxiliary transfer representation.
        if CGImageSourceCopyAuxiliaryDataInfoAtIndex(reader, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil {
            throw HEICCPUEncoder.EncoderError.colorReviewRequired
        }
        if #available(macOS 15.0, *),
           CGImageSourceCopyAuxiliaryDataInfoAtIndex(reader, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil {
            throw HEICCPUEncoder.EncoderError.colorReviewRequired
        }
        if cancel?() == true { throw ExportError.cancelled }
        guard let raw = CGImageSourceCreateImageAtIndex(reader, 0, options) else {
            throw ExportError.encodeFailed
        }
        try DocumentModel.validateImageDimensions(width: raw.width, height: raw.height)
        try HEICCPUEncoder.validateColor(raw)
        if cancel?() == true { throw ExportError.cancelled }
        guard try PageWorkspace.digest(of: inputURL) == originalSHA else {
            throw PageWorkspace.WorkspaceError.sourceChanged
        }
        return originalSHA
    }

    private static func nativeEncode(_ pixels: CGImage, _ output: URL, _ type: UTType, _ quality: Double) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL,
                type.identifier as CFString, 1, nil) else { return false }
        // Only fresh orientation/quality metadata: never copy private source metadata.
        CGImageDestinationAddImage(destination, pixels, [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: 1
        ] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}
