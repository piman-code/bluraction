import AVFoundation
import CoreImage
import Foundation
import Vision

/// Follows a box through a video with Vision object tracking. Boxes are normalized to the
/// displayed (orientation-applied) frame with a bottom-left origin, like the canvas.
enum ObjectTracker {
    struct Sample: Equatable {
        var time: Double
        var box: CGRect
    }

    struct Outcome {
        var samples: [Sample]
        /// True when the target was lost (low confidence) before `end`.
        var lostTarget: Bool
        var cancelled: Bool
    }

    enum TrackError: LocalizedError {
        case noVideoTrack, readFailed, boxTooSmall
        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "영상 트랙을 찾지 못했습니다."
            case .readFailed: return "영상 프레임을 읽지 못해 추적을 멈췄습니다."
            case .boxTooSmall: return "추적할 영역이 너무 작습니다. 조금 크게 잡아 주세요."
            }
        }
    }

    /// Thread-safe cancel flag shared with the UI.
    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func cancel() { lock.lock(); flag = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }

    /// Tracks `box` (normalized, at time `start`) forward until `end`. Runs synchronously; call it off
    /// the main thread. `progress` receives 0…1.
    static func track(url: URL, from start: Double, until end: Double, box: CGRect,
                      minimumConfidence: Float = 0.3, cancellation: Cancellation,
                      progress: @escaping (Double) -> Void) throws -> Outcome {
        guard box.width >= 0.01, box.height >= 0.01 else { throw TrackError.boxTooSmall }
        let asset = VideoAssetPolicy.asset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { throw TrackError.noVideoTrack }
        let transform = track.preferredTransform
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw TrackError.readFailed }
        let span = max(0, end - start)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, start), preferredTimescale: 600),
                                       duration: CMTime(seconds: span + 0.05, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw TrackError.readFailed }
        reader.add(output)
        guard reader.startReading() else { throw TrackError.readFailed }
        defer { if reader.status == .reading { reader.cancelReading() } }

        let handler = VNSequenceRequestHandler()
        var observation = VNDetectedObjectObservation(boundingBox: box.clamped01)
        var samples: [Sample] = []
        var first = true
        while let buffer = output.copyNextSampleBuffer() {
            if cancellation.isCancelled { return Outcome(samples: samples, lostTarget: false, cancelled: true) }
            let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            guard time.isFinite, let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
            if time < start - 1.0 / 240 { continue }
            if time > end + 1.0 / 240 { break }
            if first {
                // The starting frame defines the target; tracking begins with the next frame.
                first = false
                continue
            }
            let frame = BlurRenderer.oriented(CIImage(cvPixelBuffer: pixels), transform: transform)
            let request = VNTrackObjectRequest(detectedObjectObservation: observation)
            request.trackingLevel = .accurate
            do { try handler.perform([request], on: frame) } catch { throw TrackError.readFailed }
            guard let result = request.results?.first as? VNDetectedObjectObservation,
                  result.confidence >= minimumConfidence else {
                return Outcome(samples: samples, lostTarget: true, cancelled: false)
            }
            observation = result
            samples.append(Sample(time: time, box: result.boundingBox))
            progress(span > 0 ? min(1, (time - start) / span) : 1)
        }
        if reader.status == .failed { throw TrackError.readFailed }
        return Outcome(samples: samples, lostTarget: false, cancelled: false)
    }
}

private extension CGRect {
    var clamped01: CGRect {
        let x = min(max(0, minX), 1), y = min(max(0, minY), 1)
        return CGRect(x: x, y: y, width: min(width, 1 - x), height: min(height, 1 - y))
    }
}
