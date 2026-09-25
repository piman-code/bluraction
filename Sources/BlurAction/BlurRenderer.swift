import CoreImage
import CoreGraphics
import Foundation

/// Shared rendering for stills, preview and export. Coordinates are canvas bottom-left.
/// Radius/feather are output-image pixels (independent of window size).
/// Overlaps use list order, each blur sampled from the original, not repeatedly blurred.
enum BlurRenderer {
    enum RenderError: LocalizedError {
        case invalidGeometry, invalidEffect, maskAllocation, filterFailed
        var errorDescription: String? { "블러 렌더링 실패: \(self)" }
    }

    static func render(image: CIImage, pairs: [(shape: RegionShape, effect: RegionEffect)],
                       canvasSize: CGSize, time: Double?, annotations: [DrawingAnnotation] = []) throws -> CIImage {
        let extent = image.extent
        guard valid(extent), extent.width > 0, extent.height > 0,
              canvasSize.width.isFinite, canvasSize.height.isFinite,
              canvasSize.width > 0, canvasSize.height > 0,
              time == nil || time!.isFinite else { throw RenderError.invalidGeometry }
        var result = image
        for (base, effect) in pairs {
            guard effect.enabled else { continue }
            guard effect.blurRadius.isFinite, effect.featherRadius.isFinite,
                  effect.blurRadius >= 0, effect.featherRadius >= 0 else { throw RenderError.invalidEffect }
            guard effect.isActive(at: time) else { continue }
            let shape = effect.shape(base, at: time)
            guard valid(shape.boundingRect) else { throw RenderError.invalidGeometry }
            if case .polygon(_, let points) = shape {
                guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw RenderError.invalidGeometry }
            }
            guard shape.boundingRect.width > 0, shape.boundingRect.height > 0 else { continue }
            // An opaque black background is required for luminance-mask blending.
            guard extent.width <= 32768, extent.height <= 32768,
                  extent.width * extent.height <= 134_217_728,
                  let ctx = CGContext(data: nil, width: Int(ceil(extent.width)), height: Int(ceil(extent.height)),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { throw RenderError.maskAllocation }
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(origin: .zero, size: extent.size))
            ctx.scaleBy(x: extent.width / canvasSize.width, y: extent.height / canvasSize.height)
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.addPath(shape.path())
            ctx.fillPath()
            guard let cg = ctx.makeImage() else { throw RenderError.maskAllocation }
            let hard = CIImage(cgImage: cg).transformed(by: .init(translationX: extent.minX, y: extent.minY)).cropped(to: extent)
            // Make feather the approximate 5–95% transition width in source pixels,
            // centered on the path edge. Clamp the mask before blurring so shapes
            // touching the image edge do not pick up black from outside the frame.
            // Remapping the tails keeps the deep interior opaque and exterior clear.
            let mask: CIImage
            if effect.featherRadius > 0 {
                let sigma = Double(effect.featherRadius) / 3.29
                let softened = hard.clampedToExtent().applyingGaussianBlur(sigma: sigma)
                let gain: CGFloat = 1 / 0.9
                let bias: CGFloat = -0.05 / 0.9
                mask = softened.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
                    "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)
                ]).applyingFilter("CIColorClamp", parameters: [
                    "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
                ]).cropped(to: extent)
            } else {
                mask = hard
            }
            let cover: CIImage
            switch effect.style {
            case .blur:
                cover = image.clampedToExtent().applyingGaussianBlur(sigma: Double(effect.blurRadius) / 2).cropped(to: extent)
            case .mosaic:
                // Cells are anchored at the image origin so preview and export tiles line up.
                cover = image.clampedToExtent().applyingFilter("CIPixellate", parameters: [
                    kCIInputScaleKey: max(2, effect.blurRadius),
                    kCIInputCenterKey: CIVector(x: extent.minX, y: extent.minY)
                ]).cropped(to: extent)
            case .solid:
                let c = effect.color
                guard c.isValid, let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let color = CIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1, colorSpace: space)
                else { throw RenderError.invalidEffect }
                cover = CIImage(color: color).cropped(to: extent)
            }
            guard let blend = CIFilter(name: "CIBlendWithMask", parameters: [kCIInputImageKey: cover,
                kCIInputBackgroundImageKey: result, kCIInputMaskImageKey: mask]), let output = blend.outputImage
            else { throw RenderError.filterFailed }
            result = output.cropped(to: extent)
        }
        guard annotations.contains(where: { $0.isVisible(at: time) }) else { return result }
        guard extent.width <= 32768, extent.height <= 32768,
              extent.width * extent.height <= 134_217_728,
              let context = CGContext(data: nil, width: Int(ceil(extent.width)), height: Int(ceil(extent.height)),
                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw RenderError.maskAllocation }
        context.clear(CGRect(origin: .zero, size: extent.size))
        context.scaleBy(x: extent.width / canvasSize.width, y: extent.height / canvasSize.height)
        for base in annotations where base.isVisible(at: time) {
            let annotation = base.displayed(at: time)
            guard annotation.lineWidth.isFinite, annotation.lineWidth > 0,
                  annotation.fillOpacity.isFinite, (0...1).contains(annotation.fillOpacity),
                  [annotation.red, annotation.green, annotation.blue, annotation.alpha].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  annotation.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw RenderError.invalidGeometry }
            if annotation.isFilled {
                context.addPath(annotation.fillPath)
                context.setFillColor(red: annotation.red, green: annotation.green, blue: annotation.blue,
                                     alpha: annotation.alpha * annotation.fillOpacity)
                context.fillPath()
            }
            context.addPath(annotation.path)
            context.setStrokeColor(red: annotation.red, green: annotation.green, blue: annotation.blue, alpha: annotation.alpha)
            context.setLineWidth(annotation.lineWidth)
            context.setLineCap(.round); context.setLineJoin(.round)
            context.strokePath()
        }
        guard let overlay = context.makeImage() else { throw RenderError.maskAllocation }
        let overlayImage = CIImage(cgImage: overlay).transformed(by: .init(translationX: extent.minX, y: extent.minY)).cropped(to: extent)
        return overlayImage.composited(over: result).cropped(to: extent)
    }

    /// Apply the track transform exactly once, then normalize its translated extent.
    static func oriented(_ image: CIImage, transform: CGAffineTransform) -> CIImage {
        // AV track transforms are expressed in top-left raster coordinates;
        // Core Image is bottom-left. Conjugate through the vertical flip.
        let flip = CGAffineTransform(scaleX: 1, y: -1)
        let rotated = image.transformed(by: flip).transformed(by: transform).transformed(by: flip)
        return rotated.transformed(by: .init(translationX: -rotated.extent.minX, y: -rotated.extent.minY))
    }

    private static func valid(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite)
    }
}
