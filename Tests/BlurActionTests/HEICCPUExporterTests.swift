import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Testing
@testable import BlurAction

/// Actual helper input is supplied explicitly by the test runner, never by the
/// product. Missing pins fail these integration tests rather than hiding them.
@Suite(.serialized)
struct HEICCPUExporterTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("heic-export-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }
    private func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private func helper() throws -> HEICCPUEncoder.Helper {
        let env = ProcessInfo.processInfo.environment
        let path = try #require(env["BLURACTION_TEST_HEIC_CPU_HELPER"])
        let expected = try #require(env["BLURACTION_TEST_HEIC_CPU_HELPER_SHA256"])
        let url = URL(fileURLWithPath: path)
        #expect(digest(try Data(contentsOf: url)) == expected)
        return .init(url: url, sha256: expected)
    }
    private func fixture(alpha: Bool = false) throws -> CGImage {
        var bytes = [UInt8]()
        for y in 0..<64 {
            for x in 0..<96 {
                var pixel: [UInt8] = [UInt8(x * 255 / 95), UInt8(y * 255 / 63), 83, 255]
                if alpha && y < 16 && x < 24 { pixel = [0, 0, 0, 0] }
                else if alpha && y < 16 && x >= 72 { pixel = [80, 50, 20, 128] }
                bytes += pixel
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: 96, height: 64, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 96 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    private func writeInput(_ source: CGImage, parent: URL) throws -> URL {
        let url = parent.appendingPathComponent("source.tiff")
        let writer = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, source, [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Synthetic private-source sentinel"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.0, kCGImagePropertyGPSLatitudeRef: "N"]
        ] as CFDictionary)
        try #require(CGImageDestinationFinalize(writer))
        return url
    }
    private func expectNoStaging(_ parent: URL) throws {
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: parent.path))
            .contains { $0.hasPrefix(".blur-action-") || $0.hasPrefix("bluraction-heic-cpu-") })
    }

    @Test func forcedNativeFailureExportsActualHEICAlphaMaskAndFreshMetadata() throws {
        let executable = try helper()
        let parent = try directory(); defer { try? FileManager.default.removeItem(at: parent) }
        for alpha in [false, true] {
            let part = parent.appendingPathComponent(alpha ? "alpha" : "opaque", isDirectory: true)
            try FileManager.default.createDirectory(at: part, withIntermediateDirectories: false)
            let source = try fixture(alpha: alpha), input = try writeInput(source, parent: part)
            let original = try Data(contentsOf: input)
            let providerBefore = try #require(source.dataProvider?.data) as Data
            let inputReader = try #require(CGImageSourceCreateWithURL(input as CFURL, nil))
            let inputMetadata = try #require(CGImageSourceCopyPropertiesAtIndex(inputReader, 0, nil) as? [String: Any])
            #expect(inputMetadata[kCGImagePropertyExifDictionary as String] != nil)
            #expect(inputMetadata[kCGImagePropertyGPSDictionary as String] != nil)
            let output = part.appendingPathComponent("covered.heic")
            let cover = RegionShape.rectangle(id: UUID(), origin: CGPoint(x: 24, y: 16), size: CGSize(width: 48, height: 32))
            let effect = RegionEffect(blurRadius: 0, featherRadius: 0, style: .solid, color: .black)
            var flattened: HEICCPUEncoder.Pixels?, attempts = 0
            try BlurredImageExporter.export(source: source, pairs: [(cover, effect)],
                canvasSize: CGSize(width: 96, height: 64), inputURL: input, outputURL: output,
                type: .heic, quality: 0.9, expectedSourceSHA256: digest(original), heicCPUHelper: executable,
                nativeEncoder: { pixels, candidate, type, _ in
                    attempts += 1; #expect(type == .heic)
                    #expect(candidate.lastPathComponent.hasPrefix(".blur-action-"))
                    flattened = try HEICCPUEncoder.normalizedPixels(pixels)
                    return false
                })
            #expect(attempts == 1)
            let reference = try #require(flattened)
            let reader = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
            #expect(CGImageSourceGetType(reader).map { $0 as String } == UTType.heic.identifier)
            let decoded = try #require(CGImageSourceCreateImageAtIndex(reader, 0, nil))
            #expect(decoded.width == 96 && decoded.height == 64)
            let actual = try HEICCPUEncoder.normalizedPixels(decoded)
            for offset in stride(from: 3, to: actual.rgba.count, by: 4) {
                #expect(actual.rgba[offset] == reference.rgba[offset])
            }
            // Deep inside a large opaque black cover: no lossy RGB tolerance.
            for y in 28..<36 { for x in 42..<54 {
                let p = (y * 96 + x) * 4
                #expect(Array(actual.rgba[p..<p+4]) == [0, 0, 0, 255])
            }}
            let metadata = try #require(CGImageSourceCopyPropertiesAtIndex(reader, 0, nil) as? [String: Any])
            #expect(metadata[kCGImagePropertyExifDictionary as String] == nil)
            #expect(metadata[kCGImagePropertyGPSDictionary as String] == nil)
            #expect(metadata[kCGImagePropertyOrientation as String] == nil || metadata[kCGImagePropertyOrientation as String] as? Int == 1)
            #expect(try Data(contentsOf: input) == original)
            let providerAfter = try #require(source.dataProvider?.data) as Data
            #expect(providerAfter == providerBefore)
            try expectNoStaging(part)
        }
        #expect(digest(try Data(contentsOf: executable.url)) == executable.sha256)
    }

    @Test func destinationRaceAfterNativeFailurePreservesRivalAndSource() throws {
        let executable = try helper()
        let parent = try directory(); defer { try? FileManager.default.removeItem(at: parent) }
        let source = try fixture(), input = try writeInput(source, parent: parent)
        let original = try Data(contentsOf: input), rival = Data("rival publication".utf8)
        let output = parent.appendingPathComponent("raced.heic")
        var attempts = 0
        do {
            try BlurredImageExporter.export(source: source, pairs: [], canvasSize: CGSize(width: 96, height: 64),
                inputURL: input, outputURL: output, type: .heic, quality: 0.9,
                expectedSourceSHA256: digest(original), heicCPUHelper: executable,
                nativeEncoder: { _, _, _, _ in
                    attempts += 1; try rival.write(to: output, options: .withoutOverwriting); return false
                })
            Issue.record("Expected exclusive final publication to reject the rival")
        } catch BlurredImageExporter.ExportError.destinationExists { }
        let rivalAfter = try Data(contentsOf: output)
        #expect(attempts == 1 && rivalAfter == rival)
        #expect(try Data(contentsOf: input) == original)
        try expectNoStaging(parent)
        #expect(digest(try Data(contentsOf: executable.url)) == executable.sha256)
    }

    @Test func cancelAfterNativeFailureDoesNotInvokeCPUOrPublish() throws {
        let parent = try directory(); defer { try? FileManager.default.removeItem(at: parent) }
        let source = try fixture(), input = try writeInput(source, parent: parent)
        let original = try Data(contentsOf: input), output = parent.appendingPathComponent("cancelled.heic")
        var requested = false, attempts = 0
        let absent = HEICCPUEncoder.Helper(url: parent.appendingPathComponent("must-not-open"), sha256: String(repeating: "0", count: 64))
        do {
            try BlurredImageExporter.export(source: source, pairs: [], canvasSize: CGSize(width: 96, height: 64),
                inputURL: input, outputURL: output, type: .heic, quality: 0.9, cancel: { requested },
                heicCPUHelper: absent, nativeEncoder: { _, _, _, _ in attempts += 1; requested = true; return false })
            Issue.record("Expected cancellation before CPU fallback")
        } catch BlurredImageExporter.ExportError.cancelled { }
        #expect(attempts == 1 && !FileManager.default.fileExists(atPath: output.path))
        #expect(try Data(contentsOf: input) == original)
        try expectNoStaging(parent)
    }

    @Test func otherFormatsNeverUseHEICFallbackAndExistingOutputsRemainIntact() throws {
        let parent = try directory(); defer { try? FileManager.default.removeItem(at: parent) }
        let source = try fixture(), input = try writeInput(source, parent: parent)
        let original = try Data(contentsOf: input)
        let absent = HEICCPUEncoder.Helper(url: parent.appendingPathComponent("must-not-open"), sha256: String(repeating: "0", count: 64))
        for type in [UTType.png, .jpeg, .tiff] {
            let output = parent.appendingPathComponent(type.preferredFilenameExtension!)
            do {
                try BlurredImageExporter.export(source: source, pairs: [], canvasSize: CGSize(width: 96, height: 64),
                    inputURL: input, outputURL: output, type: type, quality: 0.9,
                    heicCPUHelper: absent, nativeEncoder: { _, _, _, _ in false })
                Issue.record("Expected nonHEIC native failure, not a CPU attempt")
            } catch BlurredImageExporter.ExportError.encodeFailed { }
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
        let existing = parent.appendingPathComponent("existing.heic"), sentinel = Data("keep existing".utf8)
        try sentinel.write(to: existing)
        var attempts = 0
        do {
            try BlurredImageExporter.export(source: source, pairs: [], canvasSize: CGSize(width: 96, height: 64),
                inputURL: input, outputURL: existing, type: .heic, quality: 0.9, heicCPUHelper: absent,
                nativeEncoder: { _, _, _, _ in attempts += 1; return false })
            Issue.record("Expected existing destination rejection")
        } catch BlurredImageExporter.ExportError.destinationExists { }
        let existingAfter = try Data(contentsOf: existing)
        #expect(attempts == 0 && existingAfter == sentinel)
        #expect(try Data(contentsOf: input) == original)
        try expectNoStaging(parent)
    }

    @Test func originalHighDepthCannotBeHiddenByFlatteningBeforeCPUFallback() throws {
        let parent = try directory(); defer { try? FileManager.default.removeItem(at: parent) }
        let provider = try #require(CGDataProvider(data: Data(repeating: 0, count: 96 * 64 * 2) as CFData))
        let source = try #require(CGImage(width: 96, height: 64, bitsPerComponent: 16, bitsPerPixel: 16,
            bytesPerRow: 96 * 2, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let input = try writeInput(source, parent: parent), original = try Data(contentsOf: input)
        let output = parent.appendingPathComponent("high-depth.heic")
        let absent = HEICCPUEncoder.Helper(url: parent.appendingPathComponent("must-not-open"), sha256: String(repeating: "0", count: 64))
        var attempts = 0
        do {
            try BlurredImageExporter.export(source: source, pairs: [], canvasSize: CGSize(width: 96, height: 64),
                inputURL: input, outputURL: output, type: .heic, quality: 0.9, heicCPUHelper: absent,
                nativeEncoder: { _, _, _, _ in attempts += 1; return false })
            Issue.record("Expected original high-depth color hold")
        } catch HEICCPUEncoder.EncoderError.colorReviewRequired { }
        #expect(attempts == 1 && !FileManager.default.fileExists(atPath: output.path))
        #expect(try Data(contentsOf: input) == original)
        try expectNoStaging(parent)
    }

    @Test func wrongOriginalSHARejectsBeforeAnyEncoderAttempt() throws {
        let parent = try directory(); defer { try? FileManager.default.removeItem(at: parent) }
        let source = try fixture(), input = try writeInput(source, parent: parent)
        let original = try Data(contentsOf: input), output = parent.appendingPathComponent("changed.heic")
        var attempts = 0
        do {
            try BlurredImageExporter.export(source: source, pairs: [], canvasSize: CGSize(width: 96, height: 64),
                inputURL: input, outputURL: output, type: .heic, quality: 0.9,
                expectedSourceSHA256: String(repeating: "0", count: 64),
                nativeEncoder: { _, _, _, _ in attempts += 1; return false })
            Issue.record("Expected source fingerprint rejection")
        } catch PageWorkspace.WorkspaceError.sourceChanged { }
        #expect(attempts == 0 && !FileManager.default.fileExists(atPath: output.path))
        #expect(try Data(contentsOf: input) == original)
        try expectNoStaging(parent)
    }

    @Test func originalExtendedTransferCannotBeHiddenByFlatteningBeforeCPUFallback() throws {
        let parent = try directory(); defer { try? FileManager.default.removeItem(at: parent) }
        let base = try fixture()
        let extended = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let bounds = CGRect(x: 0, y: 0, width: 96, height: 64)
        // An 8-bit extended-space CGImage is not a supported CI import on the
        // observed host. Generate supported float/extended pixels through CI,
        // and require a finite extent before testing the ORIGINAL color hold.
        let image = CIImage(color: CIColor(red: 1.25, green: 0.25, blue: 0.5)).cropped(to: bounds)
        let source = try #require(CIContext().createCGImage(image, from: bounds,
            format: .RGBAh, colorSpace: extended))
        let sourceSpace = try #require(source.colorSpace)
        try #require(CGColorSpaceUsesExtendedRange(sourceSpace))
        try #require(CIImage(cgImage: source).extent == bounds)
        let input = try writeInput(base, parent: parent), original = try Data(contentsOf: input)
        let providerBefore = try #require(source.dataProvider?.data) as Data
        let output = parent.appendingPathComponent("extended-transfer.heic")
        let absent = HEICCPUEncoder.Helper(url: parent.appendingPathComponent("must-not-open"), sha256: String(repeating: "0", count: 64))
        var attempts = 0
        do {
            try BlurredImageExporter.export(source: source, pairs: [], canvasSize: CGSize(width: 96, height: 64),
                inputURL: input, outputURL: output, type: .heic, quality: 0.9, heicCPUHelper: absent,
                nativeEncoder: { _, _, _, _ in attempts += 1; return false })
            Issue.record("Expected original extended-transfer color hold")
        } catch HEICCPUEncoder.EncoderError.colorReviewRequired { }
        #expect(attempts == 1 && !FileManager.default.fileExists(atPath: output.path))
        #expect(try Data(contentsOf: input) == original)
        let providerAfter = try #require(source.dataProvider?.data) as Data
        #expect(providerAfter == providerBefore)
        try expectNoStaging(parent)
    }

    @Test func normalizedPreviewDoesNotEraseOriginalTIFFDepthBeforeCPUFallback() throws {
        let parent = try directory(); defer { try? FileManager.default.removeItem(at: parent) }
        var bytes = [UInt8]()
        for y in 0..<64 { for x in 0..<96 {
            let sample = UInt16((x * 409 + y * 173) % 65536)
            bytes += [UInt8(sample & 255), UInt8(sample >> 8)]
        }}
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let originalImage = try #require(CGImage(width: 96, height: 64,
            bitsPerComponent: 16, bitsPerPixel: 16, bytesPerRow: 96 * 2,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: .byteOrder16Little,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let input = try writeInput(originalImage, parent: parent)
        let original = try Data(contentsOf: input)
        let rawReader = try #require(CGImageSourceCreateWithURL(input as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(rawReader, 0, nil) as? [String: Any])
        try #require(properties[kCGImagePropertyDepth as String] as? Int == 16)
        let normalized = try DocumentModel.decodeImage(url: input)
        try #require(normalized.width == 96 && normalized.height == 64)
        // This is the actual product decode boundary that previously hid the
        // file's depth. The counterexample is invalid unless it really did so.
        try #require(normalized.bitsPerComponent <= 8)
        let normalizedBefore = try #require(normalized.dataProvider?.data) as Data
        let output = parent.appendingPathComponent("normalized-original-depth.heic")
        let absent = HEICCPUEncoder.Helper(url: parent.appendingPathComponent("must-not-open"),
            sha256: String(repeating: "0", count: 64))
        var attempts = 0
        do {
            try BlurredImageExporter.export(source: normalized, pairs: [],
                canvasSize: CGSize(width: 96, height: 64), inputURL: input, outputURL: output,
                type: .heic, quality: 0.9, expectedSourceSHA256: digest(original), heicCPUHelper: absent,
                nativeEncoder: { _, _, _, _ in attempts += 1; return false })
            Issue.record("Expected original TIFF depth review before CPU lookup")
        } catch HEICCPUEncoder.EncoderError.colorReviewRequired { }
        #expect(attempts == 1 && !FileManager.default.fileExists(atPath: output.path))
        #expect(try Data(contentsOf: input) == original)
        let normalizedAfter = try #require(normalized.dataProvider?.data) as Data
        #expect(normalizedAfter == normalizedBefore)
        try expectNoStaging(parent)
    }
}
