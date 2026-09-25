import Testing
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import BlurAction

@Suite(.serialized)
final class RenderingCoreTests {
    let context = CIContext()
    let size = CGSize(width: 128, height: 96)

    func checker() -> CIImage {
        CIFilter(name: "CICheckerboardGenerator", parameters: ["inputWidth": 2,
            "inputColor0": CIColor(red: 0, green: 0, blue: 0),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1)])!.outputImage!
            .cropped(to: CGRect(origin: .zero, size: size))
    }
    func pixels(_ image: CIImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Int(image.extent.width * image.extent.height) * 4)
        let normalized = image.transformed(by: .init(translationX: -image.extent.minX, y: -image.extent.minY))
        bytes.withUnsafeMutableBytes { buffer in
            context.render(normalized, toBitmap: buffer.baseAddress!, rowBytes: Int(image.extent.width) * 4,
                           bounds: CGRect(origin: .zero, size: image.extent.size),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        return bytes
    }
    func difference(_ a: CIImage, _ b: CIImage, rect: CGRect) -> Double {
        let aa = pixels(a.cropped(to: rect)), bb = pixels(b.cropped(to: rect))
        return zip(aa, bb).map { abs(Double($0) - Double($1)) }.reduce(0, +) / Double(aa.count)
    }
    func rectangle(_ rect: CGRect) -> RegionShape { .rectangle(id: UUID(), origin: rect.origin, size: rect.size) }

    /// Estimate mask coverage from the output against the same fully blurred source.
    /// Averaging a short checkerboard strip avoids depending on one source pixel.
    func coverage(source: CIImage, fullBlur: CIImage, output: CIImage, x: Int) -> Double {
        let strip = CGRect(x: x, y: 44, width: 1, height: 8)
        let fullyApplied = difference(source, fullBlur, rect: strip)
        XCTAssertGreaterThan(fullyApplied, 20)
        return difference(source, output, rect: strip) / fullyApplied
    }

    @Test
    func testFeatherTransitionAndOpaqueInteriorForEveryShape() throws {
        let source = checker()
        let fullBlur = source.clampedToExtent().applyingGaussianBlur(sigma: 8).cropped(to: source.extent)
        let bounds = CGRect(x: 32, y: 12, width: 72, height: 72)
        let shapes: [RegionShape] = [rectangle(bounds),
            .ellipse(id: UUID(), origin: bounds.origin, size: bounds.size),
            .polygon(id: UUID(), points: [CGPoint(x: 32, y: 12), CGPoint(x: 96, y: 12),
                                           CGPoint(x: 104, y: 84), CGPoint(x: 32, y: 84)])]

        for shape in shapes {
            func rendered(_ feather: CGFloat) throws -> CIImage {
                try BlurRenderer.render(image: source,
                    pairs: [(shape, RegionEffect(blurRadius: 16, featherRadius: feather))],
                    canvasSize: size, time: nil)
            }
            let hard = try rendered(0)
            XCTAssertLessThan(coverage(source: source, fullBlur: fullBlur, output: hard, x: 30), 0.02)
            XCTAssertGreaterThan(coverage(source: source, fullBlur: fullBlur, output: hard, x: 34), 0.98)

            let medium = try rendered(12)
            let mediumOutside = coverage(source: source, fullBlur: fullBlur, output: medium, x: 29)
            let mediumInside = coverage(source: source, fullBlur: fullBlur, output: medium, x: 35)
            XCTAssertGreaterThan(mediumOutside, 0.1)
            XCTAssertLessThan(mediumOutside, 0.45)
            XCTAssertGreaterThan(mediumInside, 0.55)
            XCTAssertLessThan(mediumInside, 0.95)
            XCTAssertLessThan(coverage(source: source, fullBlur: fullBlur, output: medium, x: 20), 0.02)
            XCTAssertGreaterThan(coverage(source: source, fullBlur: fullBlur, output: medium, x: 45), 0.98)

            let high = try rendered(32)
            let highOutside = coverage(source: source, fullBlur: fullBlur, output: high, x: 24)
            let highInside = coverage(source: source, fullBlur: fullBlur, output: high, x: 40)
            XCTAssertGreaterThan(highOutside, 0.1)
            XCTAssertLessThan(highOutside, 0.45)
            XCTAssertGreaterThan(highInside, 0.55)
            XCTAssertLessThan(highInside, 0.95)
            XCTAssertGreaterThan(highOutside,
                coverage(source: source, fullBlur: fullBlur, output: medium, x: 24) + 0.1)
            XCTAssertLessThan(coverage(source: source, fullBlur: fullBlur, output: high, x: 8), 0.02)
            XCTAssertGreaterThan(coverage(source: source, fullBlur: fullBlur, output: high, x: 56), 0.98)
        }
    }

    @Test
    func testFeatherAtMediaEdgeKeepsFullBlurWithoutBlackBleed() throws {
        let source = checker()
        let fullBlur = source.clampedToExtent().applyingGaussianBlur(sigma: 8).cropped(to: source.extent)
        let shapes: [RegionShape] = [
            rectangle(CGRect(x: -60, y: -60, width: 248, height: 216)),
            .ellipse(id: UUID(), origin: CGPoint(x: -136, y: -112), size: CGSize(width: 400, height: 320)),
            .polygon(id: UUID(), points: [CGPoint(x: -60, y: -60), CGPoint(x: 188, y: -60),
                                           CGPoint(x: 188, y: 156), CGPoint(x: -60, y: 156)])
        ]
        for shape in shapes {
            let output = try BlurRenderer.render(image: source,
                pairs: [(shape, RegionEffect(blurRadius: 16, featherRadius: 32))],
                canvasSize: size, time: nil)
            XCTAssertLessThan(difference(output, fullBlur, rect: CGRect(x: 0, y: 0, width: 8, height: 8)), 1)
            XCTAssertLessThan(difference(output, fullBlur, rect: CGRect(x: 120, y: 88, width: 8, height: 8)), 1)
        }
    }

    @Test
    func testBottomLeftMaskShapesAndUnchangedOutside() throws {
        let source = checker()
        let rect = CGRect(x: 8, y: 8, width: 40, height: 30)
        let shapes: [RegionShape] = [rectangle(rect), .ellipse(id: UUID(), origin: rect.origin, size: rect.size),
            .polygon(id: UUID(), points: [CGPoint(x: 8, y: 8), CGPoint(x: 48, y: 8), CGPoint(x: 28, y: 38)])]
        for shape in shapes {
            let result = try BlurRenderer.render(image: source, pairs: [(shape, RegionEffect(blurRadius: 16, featherRadius: 0))], canvasSize: size, time: nil)
            XCTAssertGreaterThan(difference(source, result, rect: CGRect(x: 24, y: 15, width: 8, height: 8)), 20)
            XCTAssertEqual(difference(source, result, rect: CGRect(x: 8, y: 60, width: 40, height: 30)), 0)
        }
    }

    @Test
    func testAnnotationsRenderAboveBlurAndKeepCanvasCoordinates() throws {
        let source = checker()
        let annotation = DrawingAnnotation(kind: .line,
            points: [CGPoint(x: 12, y: 20), CGPoint(x: 108, y: 72)],
            color: .systemRed, lineWidth: 6)
        let rendered = try BlurRenderer.render(image: source, pairs: [], canvasSize: size, time: nil, annotations: [annotation])
        XCTAssertGreaterThan(difference(source, rendered, rect: CGRect(x: 45, y: 35, width: 24, height: 18)), 20)
        XCTAssertEqual(difference(source, rendered, rect: CGRect(x: 8, y: 76, width: 24, height: 12)), 0)

        let blur = rectangle(CGRect(x: 32, y: 24, width: 64, height: 48))
        let combined = try BlurRenderer.render(image: source,
            pairs: [(blur, RegionEffect(blurRadius: 16, featherRadius: 0))], canvasSize: size, time: nil, annotations: [annotation])
        XCTAssertGreaterThan(difference(rendered, combined, rect: CGRect(x: 50, y: 40, width: 20, height: 20)), 1)
        // Annotation is composited last and remains visible over the blur result.
        XCTAssertGreaterThan(difference(combined, try BlurRenderer.render(image: source,
            pairs: [(blur, RegionEffect(blurRadius: 16, featherRadius: 0))], canvasSize: size, time: nil),
            rect: CGRect(x: 50, y: 40, width: 20, height: 20)), 10)
    }

    @Test
    func testPNGExportUsesTheSameAnnotationRenderer() throws {
        let sourceImage = checker()
        let source = try XCTUnwrap(context.createCGImage(sourceImage, from: sourceImage.extent))
        let annotation = DrawingAnnotation(kind: .ellipse,
            points: [CGPoint(x: 18, y: 16), CGPoint(x: 110, y: 82)], color: .systemBlue, lineWidth: 5)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("source.png"), output = folder.appendingPathComponent("result.png")
        let inputDestination = CGImageDestinationCreateWithURL(input as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(inputDestination, source, nil); XCTAssertTrue(CGImageDestinationFinalize(inputDestination))
        try BlurredImageExporter.export(source: source, pairs: [], canvasSize: size, inputURL: input, outputURL: output,
                                        type: .png, quality: 1, annotations: [annotation])
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let actual = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        let expected = try BlurRenderer.render(image: sourceImage, pairs: [], canvasSize: size, time: nil, annotations: [annotation])
        XCTAssertLessThan(difference(expected, CIImage(cgImage: actual), rect: CGRect(origin: .zero, size: size)), 1)
    }

    @Test
    func testIndependentStrengthFeatherAndWindowScaling() throws {
        let source = checker()
        let left = rectangle(CGRect(x: 10, y: 10, width: 35, height: 60))
        let right = rectangle(CGRect(x: 80, y: 10, width: 35, height: 60))
        let weak = RegionEffect(blurRadius: 0.1, featherRadius: 0)
        let strong = RegionEffect(blurRadius: 16, featherRadius: 5)
        let result = try BlurRenderer.render(image: source, pairs: [(left, weak), (right, strong)], canvasSize: size, time: nil)
        XCTAssertLessThan(difference(source, result, rect: CGRect(x: 15, y: 20, width: 20, height: 30)), 5)
        XCTAssertGreaterThan(difference(source, result, rect: CGRect(x: 85, y: 20, width: 20, height: 30)), 20)
        XCTAssertGreaterThan(difference(source, result, rect: CGRect(x: 76, y: 25, width: 3, height: 20)), 1)
        let scaled = try BlurRenderer.render(image: source, pairs: [(left.replacing(rect: left.boundingRect.applying(.init(scaleX: 2, y: 2))), weak),
            (right.replacing(rect: right.boundingRect.applying(.init(scaleX: 2, y: 2))), strong)],
            canvasSize: CGSize(width: 256, height: 192), time: nil)
        XCTAssertEqual(pixels(result), pixels(scaled))
    }

    @Test
    func testTimeStaticDisabledAndValidation() throws {
        let source = checker(), shape = rectangle(CGRect(x: 0, y: 0, width: 50, height: 50))
        var effect = RegionEffect(blurRadius: 16, featherRadius: 0, timeRange: 2...3)
        effect.keyframes = [RegionKeyframe(time: 2, rect: CGRect(x: 70, y: 0, width: 50, height: 50))]
        let still = try BlurRenderer.render(image: source, pairs: [(shape, effect)], canvasSize: size, time: nil)
        XCTAssertGreaterThan(difference(source, still, rect: CGRect(x: 10, y: 10, width: 20, height: 20)), 20)
        let inactive = try BlurRenderer.render(image: source, pairs: [(shape, effect)], canvasSize: size, time: 1)
        XCTAssertEqual(pixels(source), pixels(inactive))
        let active = try BlurRenderer.render(image: source, pairs: [(shape, effect)], canvasSize: size, time: 2)
        XCTAssertGreaterThan(difference(source, active, rect: CGRect(x: 80, y: 10, width: 20, height: 20)), 20)
        effect.enabled = false
        XCTAssertEqual(pixels(source), pixels(try BlurRenderer.render(image: source, pairs: [(shape, effect)], canvasSize: size, time: nil)))
        effect.enabled = true; effect.blurRadius = 0
        XCTAssertEqual(pixels(source), pixels(try BlurRenderer.render(image: source, pairs: [(shape, effect)], canvasSize: size, time: nil)))
        effect.blurRadius = .nan
        XCTAssertThrowsError(try BlurRenderer.render(image: source, pairs: [(shape, effect)], canvasSize: size, time: nil))
    }

    @Test
    func testKeyframeEndpointsAndPolygonAffine() {
        let shape = RegionShape.polygon(id: UUID(), points: [.zero, CGPoint(x: 10, y: 0), CGPoint(x: 0, y: 20)])
        let a = CGRect(x: 20, y: 30, width: 20, height: 40)
        let b = CGRect(x: 40, y: 50, width: 40, height: 80)
        let one = [RegionKeyframe(time: 1, rect: a)]
        XCTAssertEqual(shape.interpolatedRect(at: 0, baseRect: shape.boundingRect, keyframes: one), shape.boundingRect)
        XCTAssertEqual(shape.interpolatedRect(at: 1, baseRect: shape.boundingRect, keyframes: one), a)
        XCTAssertEqual(shape.interpolatedRect(at: 2, baseRect: shape.boundingRect, keyframes: one), a)
        let frames = one + [RegionKeyframe(time: 3, rect: b)]
        XCTAssertEqual(shape.interpolatedRect(at: 3, baseRect: .zero, keyframes: frames), b)
        XCTAssertEqual(shape.interpolatedRect(at: 2, baseRect: .zero, keyframes: frames), CGRect(x: 30, y: 40, width: 30, height: 60))
        XCTAssertEqual(shape.replacing(rect: a).boundingRect, a)
        XCTAssertEqual(shape.replacing(rect: a).id, shape.id)
    }

    @MainActor
    @Test
    func testStillPreviewMatchesRendererAndPausedEdits() throws {
        let preview = LiveBlurCompositor()
        preview.videoDisplayRect = CGRect(origin: .zero, size: size)
        let source = checker()
        preview.sourceCGImage = try XCTUnwrap(context.createCGImage(source, from: source.extent))
        var shape = rectangle(CGRect(x: 5, y: 5, width: 40, height: 40))
        let effect = RegionEffect(blurRadius: 16, featherRadius: 4, timeRange: 5...6)
        preview.regionsProvider = { [(shape, effect)] }
        preview.refresh()
        let first = try XCTUnwrap(preview.contents as! CGImage?)
        let expected = try BlurRenderer.render(image: CIImage(cgImage: preview.sourceCGImage!), pairs: [(shape, effect)], canvasSize: size, time: nil)
        XCTAssertLessThan(difference(CIImage(cgImage: first), expected, rect: source.extent), 1)
        shape = rectangle(CGRect(x: 70, y: 5, width: 40, height: 40))
        preview.refresh()
        let second = try XCTUnwrap(preview.contents as! CGImage?)
        XCTAssertGreaterThan(difference(CIImage(cgImage: first), CIImage(cgImage: second), rect: source.extent), 5)
    }

    @MainActor
    @Test
    func testFeatheredStillPreviewAndPNGExportMatchSharedRenderer() throws {
        let source = checker()
        let sourceCG = try XCTUnwrap(context.createCGImage(source, from: source.extent))
        let shape = rectangle(CGRect(x: 32, y: 12, width: 72, height: 72))
        let effect = RegionEffect(blurRadius: 16, featherRadius: 32)
        let expected = try BlurRenderer.render(image: CIImage(cgImage: sourceCG),
            pairs: [(shape, effect)], canvasSize: size, time: nil)

        let preview = LiveBlurCompositor()
        preview.videoDisplayRect = CGRect(origin: .zero, size: size)
        preview.sourceCGImage = sourceCG
        preview.regionsProvider = { [(shape, effect)] }
        preview.refresh()
        let previewCG = try XCTUnwrap(preview.contents) as! CGImage
        XCTAssertLessThan(difference(CIImage(cgImage: previewCG), expected, rect: source.extent), 1)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("feather.png")
        try BlurredImageExporter.export(source: sourceCG, pairs: [(shape, effect)],
            canvasSize: size, inputURL: directory.appendingPathComponent("source.png"),
            outputURL: output, type: .png, quality: 1)
        let encoded = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let exportedCG = try XCTUnwrap(CGImageSourceCreateImageAtIndex(encoded, 0, nil))
        XCTAssertLessThan(difference(CIImage(cgImage: exportedCG), expected, rect: source.extent), 2)
    }
}
