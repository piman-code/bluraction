import AppKit
import AVFoundation
import CoreImage

/// Main-thread preview. Cache the source frame so paused edits rerender immediately.
final class LiveBlurCompositor: CALayer {
    private let outputDelegate = PreviewOutputDelegate()
    private let ciContext = CIContext()
    private var videoOutput: AVPlayerItemVideoOutput?
    private var attachedItem: AVPlayerItem?
    private weak var attachedPlayer: AVPlayer?
    private var sourceFrame: CIImage?
    private var sourceFrameTime: CMTime?
    private(set) var presentedFrameTime: CMTime?
    /// Published only after new video pixels with a valid PTS have been composited.
    var onPresentedFrameTime: ((CMTime) -> Void)?
    private var sourceFrameIsOriented = false
    private var stillFrameGenerator: AVAssetImageGenerator?
    private var requestedStillTime: Double?
    var sourceCGImage: CGImage? { didSet { sourceFrame = nil; sourceFrameTime = nil; presentedFrameTime = nil } }
    var regionsProvider: (() -> [(shape: RegionShape, effect: RegionEffect)])?
    var annotationsProvider: (() -> [DrawingAnnotation])?
    var currentTime: Double = 0
    var videoSize: CGSize = .zero
    var videoDisplayRect: CGRect = .zero
    var videoTransform: CGAffineTransform = .identity
    private(set) var renderError: Error?

    override init() {
        super.init()
        backgroundColor = CGColor(gray: 0, alpha: 1)
        outputDelegate.owner = self
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        contentsGravity = .resizeAspect
        needsDisplayOnBoundsChange = true
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    /// Do not round a known first-media boundary into the preceding empty segment.
    /// Reject invalid/overflowing inputs before converting to Int64.
    static func preciseTime(seconds: Double) -> CMTime? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let ticks = (seconds * 1_000_000_000).rounded(.up)
        guard ticks.isFinite, ticks >= 0, ticks < Double(Int64.max) else { return nil }
        return CMTime(value: Int64(ticks), timescale: 1_000_000_000)
    }

    /// This layer publishes decoded composites directly. CALayer's default display
    /// can manufacture an empty backing image on a bounds change, which must not
    /// be confused with the first decoded media frame while a load is pending.
    override func display() {
        refresh()
    }

    func attach(item: AVPlayerItem, player: AVPlayer) {
        attachedPlayer = player
        if videoOutput != nil, attachedItem === item { return }
        detach()
        attachedPlayer = player
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()])
        out.setDelegate(outputDelegate, queue: .main)
        item.add(out)
        videoOutput = out
        attachedItem = item
        out.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
        requestStillFrame(at: max(0, currentTime))
    }

    func detach() {
        stillFrameGenerator?.cancelAllCGImageGeneration()
        stillFrameGenerator = nil
        requestedStillTime = nil
        if let out = videoOutput, let item = attachedItem { item.remove(out) }
        videoOutput?.setDelegate(nil, queue: nil)
        videoOutput = nil
        attachedItem = nil
        attachedPlayer = nil
        sourceFrame = nil
        sourceFrameTime = nil
        presentedFrameTime = nil
        sourceFrameIsOriented = false
        contents = nil
        backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    func refresh() {
        guard videoDisplayRect.width > 0, videoDisplayRect.height > 0 else {
            contents = nil; presentedFrameTime = nil; return
        }
        if let image = sourceCGImage {
            present(CIImage(cgImage: image), frameTime: nil)
        } else if let out = videoOutput, let player = attachedPlayer {
            let itemTime = player.currentTime()
            var displayTime = CMTime.invalid
            if let buffer = out.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayTime) {
                guard displayTime.isNumeric, displayTime.seconds.isFinite, displayTime.seconds >= 0 else {
                    sourceFrame = nil; sourceFrameTime = nil; presentedFrameTime = nil
                    renderError = BlurRenderer.RenderError.invalidGeometry
                    contents = nil
                    return
                }
                sourceFrame = CIImage(cvPixelBuffer: buffer)
                sourceFrameTime = displayTime
                sourceFrameIsOriented = false
            }
            if let sourceFrame, let sourceFrameTime {
                present(sourceFrameIsOriented ? sourceFrame : BlurRenderer.oriented(sourceFrame, transform: videoTransform),
                        frameTime: sourceFrameTime)
            } else {
                contents = nil
                presentedFrameTime = nil
            }
        } else {
            contents = nil
            presentedFrameTime = nil
        }
    }

    /// AVPlayerItemVideoOutput may have no pixel buffer until playback starts. Decode a
    /// single still frame for the paused first frame (and paused seeks) so opening a
    /// video never leaves a black preview waiting for a resize or Play.
    func requestStillFrame(at seconds: Double) {
        guard let item = attachedItem, seconds.isFinite, seconds >= 0, sourceFrame == nil,
              let target = Self.preciseTime(seconds: seconds == 0 ? 1.0 / 30.0 : seconds) else { return }
        if let requestedStillTime, abs(requestedStillTime - seconds) < 0.000000001 { return }
        stillFrameGenerator?.cancelAllCGImageGeneration()
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.appliesPreferredTrackTransform = true
        // A request for exact zero fails on some H.264 files whose first decoded
        // sample is slightly later than the presentation timeline's zero.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        stillFrameGenerator = generator
        requestedStillTime = seconds
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: target)]) { [weak self, weak item] _, image, actualTime, result, _ in
            DispatchQueue.main.async { [weak self, weak item] in
                guard let self, let item, self.attachedItem === item,
                      self.stillFrameGenerator === generator else { return }
                guard result == .succeeded, let image, actualTime.isNumeric,
                      actualTime.seconds.isFinite, actualTime.seconds >= 0 else {
                    self.stillFrameGenerator = nil
                    self.requestedStillTime = nil
                    return
                }
                guard self.sourceFrame == nil else { return }
                self.sourceFrame = CIImage(cgImage: image)
                self.sourceFrameTime = actualTime
                self.sourceFrameIsOriented = true
                self.refresh()
            }
        }
    }

    /// Color of the currently displayed composite (what the user sees) at a canvas point.
    func color(atCanvasPoint point: CGPoint) -> NSColor? {
        guard let contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return nil }
        let image = contents as! CGImage
        guard videoDisplayRect.width > 0, videoDisplayRect.height > 0, image.width > 0, image.height > 0,
              point.x.isFinite, point.y.isFinite else { return nil }
        // Canvas is bottom-left; the CGImage raster is top-left.
        let x = min(image.width - 1, max(0, Int(point.x / videoDisplayRect.width * CGFloat(image.width))))
        let y = min(image.height - 1, max(0, Int((1 - point.y / videoDisplayRect.height) * CGFloat(image.height))))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let alpha = CGFloat(data[3]) / 255
        guard alpha > 0 else { return nil }
        return NSColor(srgbRed: CGFloat(data[0]) / 255 / alpha, green: CGFloat(data[1]) / 255 / alpha,
                       blue: CGFloat(data[2]) / 255 / alpha, alpha: 1)
    }

    private func present(_ source: CIImage, frameTime: CMTime?) {
        do {
            let final = try BlurRenderer.render(image: source, pairs: regionsProvider?() ?? [],
                                                canvasSize: videoDisplayRect.size, time: frameTime?.seconds,
                                                annotations: annotationsProvider?() ?? [])
            guard let cg = ciContext.createCGImage(final, from: final.extent) else {
                throw BlurRenderer.RenderError.filterFailed
            }
            renderError = nil
            backgroundColor = CGColor(gray: 0, alpha: 1)
            contents = cg
            let previousTime = presentedFrameTime
            presentedFrameTime = frameTime
            if let frameTime, (previousTime.map({ CMTimeCompare($0, frameTime) != 0 }) ?? true) {
                onPresentedFrameTime?(frameTime)
            }
        } catch {
            renderError = error
            // Fail closed: the AVPlayer below this layer must not expose a raw frame.
            backgroundColor = CGColor(gray: 0, alpha: 1)
            contents = nil
            presentedFrameTime = nil
        }
    }

    func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) {
        guard sender === videoOutput else { return }
        refresh()
    }
    func invalidateFrame() {
        stillFrameGenerator?.cancelAllCGImageGeneration()
        stillFrameGenerator = nil
        requestedStillTime = nil
        sourceFrame = nil
        sourceFrameTime = nil
        presentedFrameTime = nil
        sourceFrameIsOriented = false
        contents = nil
        backgroundColor = CGColor(gray: 0, alpha: 1)
        videoOutput?.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
    }
    func outputSequenceWasFlushed(_ sender: AVPlayerItemOutput) {
        guard sender === videoOutput else { return }
        invalidateFrame()
        // Use the seek target set before the seek starts; the player clock may still
        // report the old time here, and a stale still frame would block the settled one.
        if let player = attachedPlayer, player.rate == 0 {
            requestStillFrame(at: max(0, currentTime))
        }
    }

}

private final class PreviewOutputDelegate: NSObject, AVPlayerItemOutputPullDelegate, @unchecked Sendable {
    // AVFoundation invokes this delegate exclusively on DispatchQueue.main.
    weak var owner: LiveBlurCompositor?
    func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) { owner?.outputMediaDataWillChange(sender) }
    // Route through the owner's flush handler so a paused flush re-requests the still frame.
    func outputSequenceWasFlushed(_ sender: AVPlayerItemOutput) { owner?.outputSequenceWasFlushed(sender) }
}
