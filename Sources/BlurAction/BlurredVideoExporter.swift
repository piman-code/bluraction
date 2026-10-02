import Foundation
import AVFoundation
import CoreImage
import AudioToolbox

private final class ExportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value || Task.isCancelled { throw CancellationError() }
    }
}

/// MainActor owns terminal state/publication; decoding, rendering and encoding run off-main.
@MainActor
final class BlurredVideoExporter: ObservableObject {
    enum ExportError: LocalizedError, Equatable {
        case noInput, noVideoTrack, writerInitFailed, readSampleFailed, videoSizeUnknown, videoFrameTooLarge, invalidVideoMetadata
        case finalizeFailed(String)
        var errorDescription: String? {
            switch self {
            case .noInput: return "입력 영상이 없습니다."
            case .noVideoTrack: return "비디오 트랙이 없습니다."
            case .writerInitFailed: return "출력 파일을 만들 수 없습니다."
            case .readSampleFailed: return "미디어 샘플을 읽지 못했습니다."
            case .videoSizeUnknown: return "영상 크기 또는 길이를 알 수 없습니다."
            case .videoFrameTooLarge: return "영상 프레임이 너무 큽니다. 한 변은 32,768픽셀, 전체는 134,217,728픽셀 이하여야 합니다."
            case .invalidVideoMetadata: return "영상의 프레임률 또는 비트레이트 정보가 올바르지 않아 내보낼 수 없습니다."
            case .finalizeFailed(let reason): return "내보내기 실패: \(reason)"
            }
        }
    }
    @Published var isExporting = false
    @Published var progress: Double = 0
    @Published var statusText = ""
    @Published var lastOutputURL: URL?
    @Published private(set) var wasCancelled = false
    private var cancelFlag = false
    private var cancellation = ExportCancellation()
    typealias SourceFingerprinter = @MainActor (URL) async throws -> String
    private let sourceFingerprinter: SourceFingerprinter

    /// The injected fingerprinter lets tests suspend the final integrity check.
    /// Production hashing still runs off-main and propagates all read failures.
    init(sourceFingerprinter: @escaping SourceFingerprinter = { url in
        try await Task.detached { try PageWorkspace.digest(of: url) }.value
    }) {
        self.sourceFingerprinter = sourceFingerprinter
    }

    nonisolated static let maximumFramePixels = 134_217_728.0
    nonisolated static let maximumDimension = 32_768.0
    nonisolated static let maximumFrameRate = 240.0
    nonisolated static let maximumVideoBitRate = 500_000_000.0

    nonisolated static func validateOutputSize(_ size: CGSize) throws {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size.width <= maximumDimension, size.height <= maximumDimension else { throw ExportError.videoSizeUnknown }
        guard size.width <= maximumFramePixels / size.height else { throw ExportError.videoFrameTooLarge }
    }

    nonisolated static func outputBitRate(quality: QualityPreset, estimatedRate: Double, frameRate: Double, size: CGSize) throws -> Int {
        guard estimatedRate.isFinite, estimatedRate >= 0, estimatedRate <= maximumVideoBitRate,
              frameRate.isFinite, frameRate >= 0, frameRate <= maximumFrameRate else { throw ExportError.invalidVideoMetadata }
        let rawRate: Double
        if quality == .original { rawRate = max(500_000, estimatedRate) }
        else { rawRate = Double(size.width) * Double(size.height) * max(1, frameRate) * quality.bitsPerPixelPerSecond }
        guard rawRate.isFinite, rawRate >= 0 else { throw ExportError.invalidVideoMetadata }
        return Int(min(maximumVideoBitRate, max(500_000, rawRate)))
    }

    func cancel() { if isExporting { cancelFlag = true; cancellation.cancel() } }
    private func checkCancellation() throws {
        if cancelFlag || Task.isCancelled { throw CancellationError() }
    }

    func export(input: URL, pairs: [(shape: RegionShape, effect: RegionEffect)],
                quality: QualityPreset, canvasBounds: CGSize,
                annotations: [DrawingAnnotation] = [],
                expectedSourceSHA256: String? = nil,
                progressCallback: ((Double, String) -> Void)? = nil) async {
        guard !isExporting else { return }
        cancelFlag = false
        cancellation = ExportCancellation()
        wasCancelled = false
        lastOutputURL = nil
        isExporting = true
        progress = 0
        statusText = "준비 중…"
        // Same directory/volume enables atomic hard-link publication without overwrite.
        let ext = input.pathExtension.lowercased() == "mov" ? "mov" : "mp4"
        let temp = input.deletingLastPathComponent().appendingPathComponent(".bluraction-\(UUID().uuidString).\(ext)")
        defer { isExporting = false; try? FileManager.default.removeItem(at: temp) }
        do {
            try checkCancellation()
            if let expectedSourceSHA256 {
                let current = try await sourceFingerprinter(input)
                guard current == expectedSourceSHA256 else { throw PageWorkspace.WorkspaceError.sourceChanged }
            }
            try checkCancellation()
            try await Self.runExport(input: input, output: temp, pairs: pairs, quality: quality,
                                     canvasBounds: canvasBounds, annotations: annotations, cancellation: cancellation) { p, text in
                self.progress = p
                self.statusText = text
                progressCallback?(p, text)
            }
            try checkCancellation()
            if let expectedSourceSHA256 {
                let current = try await sourceFingerprinter(input)
                guard current == expectedSourceSHA256 else { throw PageWorkspace.WorkspaceError.sourceChanged }
            }
            // cancel() may run while the final hash is suspended; never publish after it.
            try checkCancellation()
            let output = try publish(temp, for: input)
            lastOutputURL = output
            progress = 1
            statusText = "완료: \(output.lastPathComponent)"
        } catch is CancellationError {
            wasCancelled = true
            statusText = "취소됨"
        } catch {
            if cancelFlag || Task.isCancelled {
                wasCancelled = true
                statusText = "취소됨"
            } else { statusText = "실패: \(error.localizedDescription)" }
        }
    }

    private func publish(_ temp: URL, for input: URL) throws -> URL {
        for index in 0..<10000 {
            let final = Self.outputURL(for: input, collision: index)
            do {
                try FileManager.default.linkItem(at: temp, to: final)
                return final
            } catch {
                if FileManager.default.fileExists(atPath: final.path) { continue }
                throw error
            }
        }
        throw ExportError.finalizeFailed("출력 파일 이름 충돌")
    }

    /// Reserve filesystem byte space for the suffix and extension, including collision numbers.
    static func outputURL(for input: URL, collision: Int) -> URL {
        let ext = input.pathExtension.lowercased() == "mov" ? "mov" : "mp4"
        let stem = input.deletingPathExtension().lastPathComponent
        let filename = ImageSavePanel.filename(stem: stem, extension: ext, collision: collision)
        return input.deletingLastPathComponent().appendingPathComponent(filename)
    }

    nonisolated private static func runExport(input: URL, output: URL, pairs: [(shape: RegionShape, effect: RegionEffect)],
                           quality: QualityPreset, canvasBounds: CGSize, annotations: [DrawingAnnotation],
                           cancellation: ExportCancellation,
                           progressCallback: @MainActor (Double, String) -> Void) async throws {
        let asset = VideoAssetPolicy.asset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideoTrack }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let assetDuration = try await asset.load(.duration)
        let duration = assetDuration.seconds
        let fps = Double(try await track.load(.nominalFrameRate))
        let estimatedRate = Double(try await track.load(.estimatedDataRate))
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        let size = CGSize(width: ceil(rect.width), height: ceil(rect.height))
        try validateOutputSize(size)
        guard assetDuration.isValid, assetDuration.isNumeric, assetDuration.timescale > 0,
              duration.isFinite, duration > 0,
              canvasBounds.width.isFinite, canvasBounds.height.isFinite,
              canvasBounds.width > 0, canvasBounds.height > 0 else { throw ExportError.videoSizeUnknown }
        try cancellation.check()
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: output.pathExtension == "mov" ? .mov : .mp4)
        // Preserve the asset's exact endpoint, including fractional edit-list
        // boundaries. A default movie timescale can round that endpoint.
        writer.movieTimeScale = assetDuration.timescale
        defer {
            if reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
        }
        let videoOut = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOut.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOut) else { throw ExportError.readSampleFailed }
        reader.add(videoOut)
        let rate = try outputBitRate(quality: quality, estimatedRate: estimatedRate, frameRate: fps, size: size)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: rate]])
        guard writer.canAdd(videoIn) else { throw ExportError.writerInitFailed }
        writer.add(videoIn)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        var audio: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for audioTrack in try await asset.loadTracks(withMediaType: .audio) {
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            let descriptions = try await audioTrack.load(.formatDescriptions)
            guard let desc = descriptions.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else {
                throw ExportError.readSampleFailed
            }
            let channels = min(2, max(1, Int(asbd.pointee.mChannelsPerFrame)))
            let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100, AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 128000])
            guard reader.canAdd(out), writer.canAdd(audioIn) else { throw ExportError.writerInitFailed }
            reader.add(out); writer.add(audioIn)
            audio.append((out, audioIn))
        }
        guard reader.startReading() else { throw reader.error ?? ExportError.readSampleFailed }
        guard writer.startWriting() else { throw writer.error ?? ExportError.writerInitFailed }
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        var videoDone = false
        var audioDone = Set<Int>()
        var frameCount = 0
        while !videoDone || audioDone.count < audio.count {
            try cancellation.check()
            if writer.status == .failed { throw writer.error ?? ExportError.writerInitFailed }
            if reader.status == .failed { throw reader.error ?? ExportError.readSampleFailed }
            var advanced = false
            if !videoDone, videoIn.isReadyForMoreMediaData {
                if let sample = videoOut.copyNextSampleBuffer() {
                    var frameProgress = 0.0
                    try autoreleasepool {
                        guard let buffer = CMSampleBufferGetImageBuffer(sample), let pool = adaptor.pixelBufferPool else {
                            throw ExportError.readSampleFailed
                        }
                        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                        let source = BlurRenderer.oriented(CIImage(cvPixelBuffer: buffer), transform: transform)
                        let final = try BlurRenderer.render(image: source, pairs: pairs, canvasSize: canvasBounds,
                                                            time: pts.seconds, annotations: annotations)
                        var destination: CVPixelBuffer?
                        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination) == kCVReturnSuccess,
                              let destination else { throw ExportError.writerInitFailed }
                        context.render(final, to: destination, bounds: CGRect(origin: .zero, size: size),
                                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                        guard adaptor.append(destination, withPresentationTime: pts) else {
                            throw writer.error ?? ExportError.writerInitFailed
                        }
                        frameCount += 1
                        frameProgress = min(0.99, max(0, pts.seconds / duration))
                    }
                    await progressCallback(frameProgress, "진행 \(Int(frameProgress * 100))%")
                } else { videoIn.markAsFinished(); videoDone = true }
                advanced = true
            }
            for (index, stream) in audio.enumerated() where !audioDone.contains(index) && stream.1.isReadyForMoreMediaData {
                if let sample = stream.0.copyNextSampleBuffer() {
                    guard stream.1.append(sample) else { throw writer.error ?? ExportError.writerInitFailed }
                } else { stream.1.markAsFinished(); audioDone.insert(index) }
                advanced = true
            }
            // Back off under encoder backpressure and observe task cancellation promptly.
            try await Task.sleep(nanoseconds: advanced ? 1_000 : 2_000_000)
        }
        guard frameCount > 0, reader.status == .completed else { throw reader.error ?? ExportError.readSampleFailed }
        try cancellation.check()
        // Pixel-buffer appends carry PTS but not the original sample duration.
        // Without an explicit end, the writer can extend the last VFR frame or
        // encoded audio packet beyond the source asset's presentation interval.
        writer.endSession(atSourceTime: assetDuration)
        await writer.finishWriting()
        try cancellation.check()
        guard writer.status == .completed else { throw writer.error ?? ExportError.finalizeFailed("출력 미완료") }
    }
}
