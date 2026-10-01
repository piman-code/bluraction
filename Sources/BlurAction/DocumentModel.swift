import Foundation
import AVFoundation
import AppKit
import UniformTypeIdentifiers
import ImageIO
import CoreImage

@MainActor
final class DocumentModel: ObservableObject {
    @Published var url: URL?
    @Published var displayName = ""
    @Published var videoSize: CGSize = .zero
    @Published var duration: Double = 0
    @Published var videoFPS: Double = 0
    @Published var videoBitRate: Double = 0
    @Published var videoCodec = "—"
    @Published var hasAudio = false
    @Published var sourceBytes: Int = 0
    @Published var hasVideo = false
    @Published var preferredTransform: CGAffineTransform = .identity
    @Published var hasImage = false
    @Published var imageSize: CGSize = .zero
    @Published var currentCGImage: CGImage?
    @Published var errorMessage: String?

    /// Called once after the latest load succeeds or fails, on the main actor.
    /// Image loads can complete synchronously; install this before calling load.
    var onLoad: (() -> Void)?
    private var requestID = UUID()
    private var loadTask: Task<Void, Never>?

    struct VideoMetadata {
        let size: CGSize
        let transform: CGAffineTransform
        let duration: Double
        var fps: Double = 0
        var bitRate: Double = 0
        var codec = "—"
        var hasAudio = false
    }
    typealias VideoLoader = (URL) async throws -> VideoMetadata
    private let videoLoader: VideoLoader

    init(videoLoader: VideoLoader? = nil) {
        self.videoLoader = videoLoader ?? { url in
            let asset = VideoAssetPolicy.asset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw LoadError.noVideo
            }
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            try Self.validateVideoDimensions(size: size, transform: transform)
            let duration = try await asset.load(.duration).seconds
            let fps = Double(try await track.load(.nominalFrameRate))
            let bitRate = Double(try await track.load(.estimatedDataRate))
            let descriptions = try await track.load(.formatDescriptions)
            let subtype = descriptions.first.map(CMFormatDescriptionGetMediaSubType)
            let codec = subtype.map { value -> String in
                let bytes: [UInt8] = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
                let fourCC = String(bytes: bytes, encoding: .ascii) ?? "—"
                switch fourCC { case "avc1": return "H.264"; case "hvc1", "hev1": return "HEVC"; default: return fourCC }
            } ?? "—"
            let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
            guard size.width > 0, size.height > 0, duration.isFinite, duration >= 0 else {
                throw LoadError.noVideo
            }
            return VideoMetadata(size: size, transform: transform, duration: duration,
                                 fps: fps, bitRate: bitRate, codec: codec, hasAudio: hasAudio)
        }
    }

    enum LoadError: LocalizedError, Equatable {
        case imageDecode, imageTooLarge, noVideo, videoTooLarge
        var errorDescription: String? {
            switch self {
            case .imageDecode: return "이미지를 읽을 수 없습니다. 손상되었거나 지원하지 않는 형식입니다."
            case .imageTooLarge: return "이미지가 너무 큽니다. 한 변은 16,384픽셀, 전체는 24,000,000픽셀(24MP) 이하여야 합니다."
            case .noVideo: return "재생할 수 있는 비디오 트랙이 없습니다."
            case .videoTooLarge: return "영상 프레임이 너무 큽니다. 한 변은 16,384픽셀, 전체는 33,177,600픽셀 이하여야 합니다."
            }
        }
    }

    var appliedVideoSize: CGSize {
        if hasImage { return imageSize }
        let rect = CGRect(origin: .zero, size: videoSize).applying(preferredTransform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }
    enum MediaKind { case none, video, image }
    var mediaKind: MediaKind { hasImage ? .image : (hasVideo ? .video : .none) }
    var currentNSImage: NSImage? {
        currentCGImage.map { NSImage(cgImage: $0, size: imageSize) }
    }
    var asset: AVURLAsset? { url.map { VideoAssetPolicy.asset(url: $0) } }
    nonisolated static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "tiff", "tif", "bmp", "gif"
    ]
    /// Common AVFoundation movie suffixes remain recognizable when LaunchServices
    /// resolves a file extension only to a dynamic (non-video) UTType.
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
    // A single image passes through decode, orientation, preview and export buffers.
    // Keep the source below roughly 96 MiB RGBA to leave room for those copies.
    nonisolated private static let maxImageSide = 16_384
    nonisolated private static let maxImagePixels = 24_000_000
    nonisolated private static let maxVideoSide: CGFloat = 16_384
    nonisolated private static let maxVideoPixels: CGFloat = 33_177_600
    nonisolated static func isImage(url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    func load(url: URL) {
        loadTask?.cancel()
        loadTask = nil
        let id = UUID()
        requestID = id
        self.url = url
        displayName = url.lastPathComponent
        hasVideo = false
        hasImage = false
        videoSize = .zero
        imageSize = .zero
        duration = 0
        videoFPS = 0
        videoBitRate = 0
        videoCodec = "—"
        hasAudio = false
        sourceBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        preferredTransform = .identity
        currentCGImage = nil
        errorMessage = nil

        if Self.isImage(url: url) {
            do {
                let image = try Self.decodeImage(url: url)
                currentCGImage = image
                imageSize = CGSize(width: image.width, height: image.height)
                hasImage = true
            } catch {
                errorMessage = error.localizedDescription
            }
            if requestID == id { onLoad?() }
            return
        }
        let loader = videoLoader
        loadTask = Task { [weak self] in
            do {
                let metadata = try await loader(url)
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                try Self.validateVideoDimensions(size: metadata.size, transform: metadata.transform)
                self.videoSize = metadata.size
                self.preferredTransform = metadata.transform
                self.duration = metadata.duration
                self.videoFPS = metadata.fps.isFinite ? metadata.fps : 0
                self.videoBitRate = metadata.bitRate.isFinite ? metadata.bitRate : 0
                self.videoCodec = metadata.codec
                self.hasAudio = metadata.hasAudio
                self.hasVideo = true
                self.loadTask = nil
                self.onLoad?()
            } catch {
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
                self.loadTask = nil
                self.onLoad?()
            }
        }
    }

    /// Shows one rendered page of a multi-page workspace using the existing still-image editor.
    func load(pageImage image: CGImage, sourceURL: URL, name: String) {
        loadTask?.cancel()
        loadTask = nil
        requestID = UUID()
        url = sourceURL
        displayName = name
        hasVideo = false
        hasImage = true
        videoSize = .zero
        imageSize = CGSize(width: image.width, height: image.height)
        duration = 0
        videoFPS = 0
        videoBitRate = 0
        videoCodec = "—"
        hasAudio = false
        sourceBytes = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        preferredTransform = .identity
        currentCGImage = image
        errorMessage = nil
        onLoad?()
    }

    /// Decode frame zero and bake all eight EXIF orientations into the pixels.
    nonisolated static func decodeImage(url: URL) throws -> CGImage {
        let headerOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                headerOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, headerOptions) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw LoadError.imageDecode
        }
        try validateImageDimensions(width: width, height: height)
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
        guard (1...8).contains(orientation) else { throw LoadError.imageDecode }
        guard let raw = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw LoadError.imageDecode
        }
        // Recheck decoded dimensions before CI normalization in case they exceed the header bounds.
        try validateImageDimensions(width: raw.width, height: raw.height)
        let oriented = CIImage(cgImage: raw).oriented(forExifOrientation: orientation)
        let normalized = oriented.transformed(by: CGAffineTransform(
            translationX: -oriented.extent.minX, y: -oriented.extent.minY))
        guard let result = CIContext().createCGImage(normalized, from: normalized.extent) else {
            throw LoadError.imageDecode
        }
        return result
    }

    nonisolated static func validateImageDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw LoadError.imageDecode }
        guard width <= maxImageSide, height <= maxImageSide,
              height <= maxImagePixels / width else { throw LoadError.imageTooLarge }
    }

    nonisolated static func validateVideoDimensions(size: CGSize, transform: CGAffineTransform) throws {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw LoadError.noVideo
        }
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        let width = abs(rect.width), height = abs(rect.height)
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { throw LoadError.noVideo }
        guard size.width <= maxVideoSide, size.height <= maxVideoSide,
              width <= maxVideoSide, height <= maxVideoSide,
              width <= maxVideoPixels / height else { throw LoadError.videoTooLarge }
    }
}
