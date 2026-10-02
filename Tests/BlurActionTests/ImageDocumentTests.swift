import Testing
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import BlurAction

final class ImageDocumentTests {
    private var temporaryDirectories: [URL] = []
    deinit { for url in temporaryDirectories { try? FileManager.default.removeItem(at: url) } }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    /// Six distinct RGB tiles, top row red/green/blue, bottom cyan/magenta/yellow.
    private func fixture() -> CGImage {
        let colors: [[UInt8]] = [[255,0,0,255], [0,255,0,255], [0,0,255,255],
                                 [0,255,255,255], [255,0,255,255], [255,255,0,255]]
        var bytes = [UInt8]()
        for y in 0..<32 {
            for x in 0..<48 { bytes += colors[(y / 16) * 3 + x / 16] }
        }
        return CGImage(width: 48, height: 32, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: 48 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }
    private func write(_ image: CGImage, to url: URL, orientation: Int = 1) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }
    /// A valid PNG header and empty compressed stream: large dimensions without pixel allocation.
    private func headerOnlyPNG(width: UInt32, height: UInt32) -> Data {
        func bigEndianBytes(_ value: UInt32) -> [UInt8] {
            [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
             UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
        }
        func chunk(_ type: [UInt8], _ payload: [UInt8]) -> [UInt8] {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in type + payload {
                crc ^= UInt32(byte)
                for _ in 0..<8 {
                    crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xEDB8_8320 : 0)
                }
            }
            return bigEndianBytes(UInt32(payload.count)) + type + payload + bigEndianBytes(~crc)
        }
        let ihdr = bigEndianBytes(width) + bigEndianBytes(height) + [8, 2, 0, 0, 0]
        return Data([137, 80, 78, 71, 13, 10, 26, 10]
            + chunk(Array("IHDR".utf8), ihdr)
            + chunk(Array("IDAT".utf8), [0x78, 0x9C, 0x03, 0, 0, 0, 0, 1])
            + chunk(Array("IEND".utf8), []))
    }
    private func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    @MainActor
    @Test
    func testAllEXIFOrientationsHaveCorrectPixelsAndDimensions() throws {
        let dir = try directory()
        let original = fixture()
        let originalBytes = rgba(original)
        for orientation in 1...8 {
            let url = dir.appendingPathComponent("orientation-\(orientation).tiff")
            try write(original, to: url, orientation: orientation)
            let model = DocumentModel()
            var completions = 0
            model.onLoad = {
                completions += 1
                #expect(model.hasImage)
                #expect(model.currentCGImage != nil)
                #expect(model.errorMessage == nil)
            }
            model.load(url: url)
            let result = try #require(model.currentCGImage)
            #expect(completions == 1)
            #expect(result.width == (orientation >= 5 ? 32 : 48))
            #expect(result.height == (orientation >= 5 ? 48 : 32))
            let output = rgba(result)
            // Explicit EXIF coordinate table, independent of Core Image orientation code.
            for y in 0..<32 {
                for x in 0..<48 {
                    let destination: (Int, Int)
                    switch orientation {
                    case 2: destination = (47-x, y)
                    case 3: destination = (47-x, 31-y)
                    case 4: destination = (x, 31-y)
                    case 5: destination = (y, x)
                    case 6: destination = (31-y, x)
                    case 7: destination = (31-y, 47-x)
                    case 8: destination = (y, 47-x)
                    default: destination = (x, y)
                    }
                    let a = (y*48+x)*4
                    let b = (destination.1*result.width+destination.0)*4
                    for c in 0..<3 {
                        #expect(abs(Int(originalBytes[a+c]) - Int(output[b+c])) <= 2)
                    }
                }
            }
        }
    }

    @MainActor
    @Test
    func testDecodeFailureClearsStateAndCompletesWithError() throws {
        let dir = try directory()
        let valid = dir.appendingPathComponent("valid.tiff")
        try write(fixture(), to: valid)
        let model = DocumentModel()
        model.load(url: valid)
        let corrupt = dir.appendingPathComponent("corrupt.png")
        try Data("not an image".utf8).write(to: corrupt)
        var count = 0
        model.onLoad = { count += 1 }
        model.load(url: corrupt)
        #expect(count == 1)
        #expect(!(model.hasImage))
        #expect(!(model.hasVideo))
        #expect(model.currentCGImage == nil)
        #expect(model.imageSize == .zero)
        #expect(model.errorMessage != nil)
    }

    @MainActor
    @Test
    func testOversizedHeaderFailsBeforeDecodeAndSettlesState() throws {
        let dir = try directory()
        let valid = dir.appendingPathComponent("valid.tiff")
        try write(fixture(), to: valid)
        let url = dir.appendingPathComponent("oversized-header.png")
        let data = headerOnlyPNG(width: 32_769, height: 1)
        try #require(data.count < 100)
        try data.write(to: url)
        let headerOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, headerOptions))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0,
            headerOptions) as? [CFString: Any])
        try #require(properties[kCGImagePropertyPixelWidth] as? Int == 32_769)
        try #require(properties[kCGImagePropertyPixelHeight] as? Int == 1)

        let model = DocumentModel()
        model.load(url: valid)
        #expect(model.hasImage)
        var completions = 0
        model.onLoad = {
            completions += 1
            #expect(model.url == url)
            #expect(!model.hasImage && !model.hasVideo)
            #expect(model.currentCGImage == nil)
            #expect(model.imageSize == .zero)
            #expect(model.videoSize == .zero)
            #expect(model.errorMessage == DocumentModel.LoadError.imageTooLarge.localizedDescription)
        }
        model.load(url: url)
        #expect(completions == 1)
    }

    @MainActor
    @Test
    func testPixelCountLimitWithoutAllocatingImage() throws {
        try DocumentModel.validateImageDimensions(width: 6_000, height: 4_000)
        var rejected = false
        do {
            try DocumentModel.validateImageDimensions(width: 6_001, height: 4_000)
        } catch DocumentModel.LoadError.imageTooLarge {
            rejected = true
        }
        #expect(rejected)
        // The user-facing message must state the limits actually enforced above.
        let message = DocumentModel.LoadError.imageTooLarge.localizedDescription
        #expect(message.contains("16,384") && message.contains("24,000,000"))
    }

    @MainActor
    @Test
    func testStaleVideoSuccessAndFailureCannotOverwriteImageOrComplete() async throws {
        let dir = try directory()
        let imageURL = dir.appendingPathComponent("new.tiff")
        try write(fixture(), to: imageURL)
        for succeeds in [true, false] {
            var pending: CheckedContinuation<DocumentModel.VideoMetadata, Error>?
            let model = DocumentModel(videoLoader: { _ in
                try await withCheckedThrowingContinuation { continuation in
                    pending = continuation
                }
            })
            var count = 0
            model.onLoad = { count += 1 }
            model.load(url: dir.appendingPathComponent("old.mov"))
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while pending == nil, ContinuousClock.now < deadline { await Task.yield() }
            try #require(pending != nil)
            model.load(url: imageURL)
            if succeeds {
                pending?.resume(returning: .init(size: CGSize(width: 99, height: 99), transform: .identity, duration: 9))
            } else {
                pending?.resume(throwing: DocumentModel.LoadError.noVideo)
            }
            // Let the explicitly resumed old loader run its guarded completion.
            for _ in 0..<20 { await Task.yield() }
            #expect(count == 1)
            #expect(model.hasImage)
            #expect(!(model.hasVideo))
            #expect(model.url == imageURL)
            #expect(model.imageSize == CGSize(width: 48, height: 32))
            #expect(model.errorMessage == nil)
        }
    }

    @MainActor
    @Test
    func testLatestVideoSuccessAndFailureCompleteOnceWithSettledState() async {
        for succeeds in [true, false] {
            let model = DocumentModel(videoLoader: { _ in
                if !succeeds { throw DocumentModel.LoadError.noVideo }
                return .init(size: CGSize(width: 48, height: 32), transform: .identity, duration: 2)
            })
            var count = 0
            model.onLoad = {
                count += 1
                #expect(model.hasVideo == succeeds)
                #expect(!(model.hasImage))
                #expect((model.errorMessage == nil) == succeeds)
                #expect(model.duration == (succeeds ? 2 : 0))
            }
            model.load(url: URL(fileURLWithPath: "/synthetic/video.mov"))
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while count == 0, ContinuousClock.now < deadline { await Task.yield() }
            #expect(count == 1)
        }
    }

    @Test
    func testExportPixelsAndInputPreservation() throws {
        let dir = try directory()
        let input = dir.appendingPathComponent("input.tiff")
        let source = fixture()
        try write(source, to: input)
        let before = try Data(contentsOf: input)
        let output = dir.appendingPathComponent("blurred.png")
        let shape = RegionShape.rectangle(id: UUID(), origin: .zero, size: CGSize(width: 32, height: 32))
        try BlurredImageExporter.export(source: source,
            pairs: [(shape, RegionEffect(blurRadius: 6, featherRadius: 0))],
            canvasSize: CGSize(width: 48, height: 32), inputURL: input,
            outputURL: output, type: .png, quality: 1)
        let encoded = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(encoded, 0, nil))
        #expect(decoded.width == source.width)
        #expect(decoded.height == source.height)
        let a = rgba(source), b = rgba(decoded)
        let inside = (8*48+15)*4
        #expect(abs(Int(a[inside])-Int(b[inside])) > 10)
        let outside = (8*48+44)*4
        for c in 0..<3 { #expect(abs(Int(a[outside+c]) - Int(b[outside+c])) <= 2) }
        #expect(try Data(contentsOf: input) == before)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix(".blur-action-") }))
    }

    @Test
    func testAllFormatsAndRefuseEveryExistingDestination() throws {
        let dir = try directory()
        let input = dir.appendingPathComponent("input.tiff")
        let source = fixture()
        try write(source, to: input)
        let before = try Data(contentsOf: input)
        func export(_ url: URL, type: UTType = .png, quality: Double = 1) throws {
            // Test-only explicit owned helper; production never reads this env.
            var cpuHelper: HEICCPUEncoder.Helper?
            if type == .heic, let path = ProcessInfo.processInfo.environment["BLURACTION_TEST_HEIC_CPU_HELPER"] {
                let expected = try #require(ProcessInfo.processInfo.environment["BLURACTION_TEST_HEIC_CPU_HELPER_SHA256"])
                cpuHelper = .init(url: URL(fileURLWithPath: path), sha256: expected)
            }
            try BlurredImageExporter.export(source: source, pairs: [],
                canvasSize: CGSize(width: 48, height: 32), inputURL: input,
                outputURL: url, type: type, quality: quality, heicCPUHelper: cpuHelper)
        }
        let symlink = dir.appendingPathComponent("alias.png")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: input)
        let hardlink = dir.appendingPathComponent("hard.png")
        try FileManager.default.linkItem(at: input, to: hardlink)
        let existing = dir.appendingPathComponent("existing.png")
        let sentinel = Data("keep me".utf8)
        try sentinel.write(to: existing)
        let dangling = dir.appendingPathComponent("dangling.png")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: dir.appendingPathComponent("missing"))
        for destination in [input, symlink, hardlink, existing, dangling] {
            #expect(throws: (any Error).self) { try export(destination) }
        }
        #expect(try Data(contentsOf: input) == before)
        #expect(try Data(contentsOf: existing) == sentinel)
        for type in [UTType.png, .jpeg, .heic, .tiff] {
            let output = dir.appendingPathComponent("result.\(type.preferredFilenameExtension!)")
            do {
                try export(output, type: type)
            } catch {
                Issue.record("Image export failed: \(type.identifier), \(source.width)x\(source.height), \(error)")
                throw error
            }
            let encoded = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
            #expect(CGImageSourceCreateImageAtIndex(encoded, 0, nil) != nil)
            #expect(CGImageSourceGetType(encoded) as String? == type.identifier)
        }
        let failed = dir.appendingPathComponent("failed.png")
        #expect(throws: (any Error).self) { try export(failed, quality: .nan) }
        #expect(throws: (any Error).self) { try export(failed, type: .gif) }
        #expect(!(FileManager.default.fileExists(atPath: failed.path)))
        #expect(throws: (any Error).self) { try export(dir.appendingPathComponent("missing/result.png")) }
        #expect(try Data(contentsOf: input) == before)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix(".blur-action-") }))
    }
}
