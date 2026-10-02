import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import Darwin
import Testing
@testable import BlurAction

@Suite(.serialized)
struct HEICCPUEncoderTests {
    private enum Fault: Error, Equatable { case cleanup }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("heic-bridge-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }
    private func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private func image(width: Int = 96, height: Int = 64, alpha: Bool = false) throws -> (CGImage, Data) {
        var bytes = [UInt8]()
        for y in 0..<height {
            for x in 0..<width {
                var pixel: [UInt8] = [UInt8(x * 255 / max(1, width - 1)), UInt8(y * 255 / max(1, height - 1)), 83, 255]
                if width / 3 <= x && x < width * 2 / 3 && height / 3 <= y && y < height * 2 / 3 {
                    pixel = [0, 0, 0, 255]
                }
                if alpha && x < width / 4 && y < height / 4 { pixel = [0, 0, 0, 0] }
                else if alpha && x >= width * 3 / 4 && y < height / 4 { pixel = [80, 50, 20, 128] }
                bytes += pixel
            }
        }
        let data = Data(bytes)
        let provider = try #require(CGDataProvider(data: data as CFData))
        let value = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return (value, data)
    }
    private func helper(_ script: String, parent: URL) throws -> HEICCPUEncoder.Helper {
        let path = parent.appendingPathComponent("synthetic-helper-" + UUID().uuidString)
        let bytes = Data(("#!/bin/sh\n" + script + "\n").utf8)
        try bytes.write(to: path, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return HEICCPUEncoder.Helper(url: path, sha256: digest(bytes))
    }
    private func failure(_ body: () throws -> Data) throws -> HEICCPUEncoder.AttemptFailure {
        do { _ = try body(); Issue.record("Expected encoder rejection") }
        catch let error as HEICCPUEncoder.AttemptFailure { return error }
        throw Fault.cleanup
    }
    private func isError(_ error: Error, _ expected: HEICCPUEncoder.EncoderError) -> Bool {
        guard let actual = error as? HEICCPUEncoder.EncoderError else { return false }
        switch (actual, expected) {
        case (.invalidInput, .invalidInput), (.colorReviewRequired, .colorReviewRequired),
             (.helperUnavailable, .helperUnavailable), (.helperChanged, .helperChanged),
             (.cancelled, .cancelled), (.timedOut, .timedOut), (.io, .io),
             (.encodeFailed, .encodeFailed), (.invalidOutput, .invalidOutput): return true
        default: return false
        }
    }

    @Test func unassociatedConversionPreservesAlphaZeroAndSourceBytes() throws {
        let (source, original) = try image(alpha: true)
        let before = digest(original)
        let pixels = try HEICCPUEncoder.normalizedPixels(source)
        #expect(pixels.width == 96 && pixels.height == 64)
        #expect(pixels.rgba.count == original.count)
        for offset in stride(from: 3, to: original.count, by: 4) {
            #expect(pixels.rgba[offset] == original[offset])
            if original[offset] == 0 {
                #expect(pixels.rgba[offset - 3] == 0 && pixels.rgba[offset - 2] == 0 && pixels.rgba[offset - 1] == 0)
            }
        }
        let partial = (5 * 96 + 80) * 4
        #expect(Array(pixels.rgba[partial..<partial+4]) == [159, 100, 40, 128])
        let providerBytes = try #require(source.dataProvider?.data) as Data
        #expect(digest(providerBytes) == before)
        let hidden = Data([255, 123, 77, 0, 160, 100, 40, 128])
        let hiddenProvider = try #require(CGDataProvider(data: hidden as CFData))
        let straight = try #require(CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: hiddenProvider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let sanitized = try HEICCPUEncoder.normalizedPixels(straight)
        #expect(Array(sanitized.rgba[0..<4]) == [0, 0, 0, 0])
        #expect(sanitized.rgba[7] == 128)
        let hiddenAfter = try #require(straight.dataProvider?.data) as Data
        #expect(hiddenAfter == hidden)
    }

    @Test func uprightOpaqueCornersAreNotFlippedOrReoriented() throws {
        let data = Data([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255])
        let provider = try #require(CGDataProvider(data: data as CFData))
        let source = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let pixels = try HEICCPUEncoder.normalizedPixels(source)
        #expect(pixels.rgba == data)
    }

    @Test func highDepthAndHDRRequireReviewBeforeLaunchingHelper() throws {
        let provider = try #require(CGDataProvider(data: Data(repeating: 0, count: 8) as CFData))
        let source = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 16, bitsPerPixel: 16,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        #expect(throws: HEICCPUEncoder.EncoderError.self) { try HEICCPUEncoder.normalizedPixels(source) }
        let extended = try #require(CGColorSpace(name: CGColorSpace.extendedSRGB))
        let rgba = try #require(CGDataProvider(data: Data(repeating: 0, count: 16) as CFData))
        let hdr = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 8, space: extended, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: rgba, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        #expect(throws: HEICCPUEncoder.EncoderError.self) { try HEICCPUEncoder.normalizedPixels(hdr) }
    }

    @Test func symlinkAndWrongExecutableDigestRejectBeforeAttempt() throws {
        let parent = try directory(); defer { try? FileManager.default.removeItem(at: parent) }
        let target = try helper("exit 0", parent: parent)
        let link = parent.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target.url)
        let (source, _) = try image()
        #expect(throws: HEICCPUEncoder.EncoderError.self) {
            try HEICCPUEncoder.encode(image: source, quality: 0.9,
                helper: .init(url: link, sha256: target.sha256), hooks: .init(temporaryParent: parent))
        }
        #expect(throws: HEICCPUEncoder.EncoderError.self) {
            try HEICCPUEncoder.encode(image: source, quality: 0.9,
                helper: .init(url: target.url, sha256: String(repeating: "0", count: 64)), hooks: .init(temporaryParent: parent))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        #expect(names.count == 2)
    }

    @Test func blockedInputTimeoutReapsOwnProcessAndPreservesNonce() throws {
        let parent = try directory(); defer { try? FileManager.default.removeItem(at: parent) }
        let executable = try helper("while :; do :; done", parent: parent) // no secondary process, never consumes stdin
        let sentinel = parent.appendingPathComponent("existing.heic")
        let sentinelBytes = Data("existing destination nonce".utf8)
        try sentinelBytes.write(to: sentinel, options: .withoutOverwriting)
        // Remain larger than a macOS pipe without making normalization consume
        // the entire process timeout on a slower native CI host.
        let (source, original) = try image(width: 256, height: 256)
        #expect(original.count > 65_536)
        var attempt: URL?, pid: Int32 = 0
        let error = try failure {
            try HEICCPUEncoder.encode(image: source, quality: 0.9, helper: executable, timeout: 2,
                hooks: .init(temporaryParent: parent, onAttempt: { attempt = $0 }, onStarted: { pid = $0 }))
        }
        #expect(isError(error.primary, .timedOut))
        #expect(pid > 0)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        let owned = try #require(attempt)
        #expect(!FileManager.default.fileExists(atPath: owned.path))
        let after = try Data(contentsOf: sentinel)
        let sourceAfter = try #require(source.dataProvider?.data) as Data
        #expect(after == sentinelBytes && sourceAfter == original)
    }

    @Test func cancellationStopsActiveInputAndDoesNotReturnLateOutput() throws {
        let parent = try directory(); defer { try? FileManager.default.removeItem(at: parent) }
        let executable = try helper("while :; do :; done", parent: parent)
        let (source, _) = try image(width: 512, height: 512)
        var started = false, polls = 0, pid: Int32 = 0
        let error = try failure {
            try HEICCPUEncoder.encode(image: source, quality: 0.9, helper: executable, timeout: 2,
                cancel: { if started { polls += 1 }; return started && polls >= 3 },
                hooks: .init(temporaryParent: parent, onStarted: { pid = $0; started = true }))
        }
        #expect(isError(error.primary, .cancelled))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(!error.cleanupNeedsRetry)
    }

    @Test func stderrFloodIsBoundedAndEncoderIsReaped() throws {
        let parent = try directory(); defer { try? FileManager.default.removeItem(at: parent) }
        let executable = try helper("while :; do printf 'diagnostic diagnostic diagnostic diagnostic\\n' >&2; done", parent: parent)
        let (source, _) = try image()
        var pid: Int32 = 0
        let error = try failure {
            try HEICCPUEncoder.encode(image: source, quality: 0.9, helper: executable, timeout: 2,
                hooks: .init(temporaryParent: parent, onStarted: { pid = $0 }))
        }
        #expect(isError(error.primary, .io))
        #expect(error.diagnostics.count <= 65536)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func firstCancellationSurvivesCleanupFailureAndRetryOwnsDirectory() throws {
        let parent = try directory(); defer { try? FileManager.default.removeItem(at: parent) }
        let executable = try helper("while :; do :; done", parent: parent)
        let (source, original) = try image()
        var started = false, removals = 0, attempt: URL?, pid: Int32 = 0
        let error = try failure {
            try HEICCPUEncoder.encode(image: source, quality: 0.9, helper: executable,
                cancel: { started }, hooks: .init(temporaryParent: parent, onAttempt: { attempt = $0 },
                    onStarted: { pid = $0; started = true }, removeDirectory: { url in
                        removals += 1
                        if removals == 1 { throw Fault.cleanup }
                        try FileManager.default.removeItem(at: url)
                    }))
        }
        #expect(isError(error.primary, .cancelled))
        #expect(error.cleanup as? Fault == .cleanup)
        #expect(error.cleanupNeedsRetry)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        let owned = try #require(attempt)
        #expect(FileManager.default.fileExists(atPath: owned.path))
        try error.retryCleanup()
        #expect(!error.cleanupNeedsRetry && !FileManager.default.fileExists(atPath: owned.path))
        let after = try #require(source.dataProvider?.data) as Data
        #expect(after == original)
    }

    @Test func exitZeroWithoutActualCandidateIsNeverAccepted() throws {
        let parent = try directory(); defer { try? FileManager.default.removeItem(at: parent) }
        let executable = try helper("exec /bin/cat", parent: parent) // consumes input, only stdout (discarded)
        let (source, _) = try image()
        let error = try failure {
            try HEICCPUEncoder.encode(image: source, quality: 0.9, helper: executable,
                hooks: .init(temporaryParent: parent))
        }
        #expect(isError(error.primary, .invalidOutput))
        #expect(!error.cleanupNeedsRetry)
    }

    @Test func completeClaimWithPNGBytesStillFailsIndependentHEICTypeCheck() throws {
        let parent = try directory(); defer { try? FileManager.default.removeItem(at: parent) }
        let (source, _) = try image(width: 1, height: 1)
        let png = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, source, nil)
        try #require(CGImageDestinationFinalize(destination))
        let report: [String: Any] = ["status": "candidate-readback-complete", "encoder": "kvazaar", "libheif": "1.23.5",
            "width": 1, "height": 1, "quality": 90, "encodedColorChroma": "420", "input": "upright-unassociated-RGBA8-sRGB",
            "alphaPresent": false, "alphaMismatch": 0, "nclx": [1, 13, 6, 1], "sourceMetadataCopied": false,
            "rgbMeanAbsoluteDifference": 0.0, "rgbMaximumAbsoluteDifference": 0,
            "colorParityApproved": false, "publishedToUserDestination": false, "HDRVerified": false, "releaseApproved": false]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: report, options: .sortedKeys), as: UTF8.self)
        let octal = (png as Data).map { String(format: "\\%03o", Int($0)) }.joined()
        let script = "printf '%s' '\(json)' > \"$4/report.json\"\n" +
            "printf '\\000\\000\\000\\377' > \"$4/decoded.rgba\"\n" +
            "printf '\(octal)' > \"$4/candidate.heic\"\nexec /bin/cat"
        let executable = try helper(script, parent: parent)
        let error = try failure {
            try HEICCPUEncoder.encode(image: source, quality: 0.9, helper: executable,
                hooks: .init(temporaryParent: parent))
        }
        #expect(isError(error.primary, .invalidOutput))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BLURACTION_TEST_HEIC_CPU_HELPER"] != nil,
        "Actual owned CPU helper must be supplied by the root; no runtime proof from synthetic helpers"))
    func actualOwnedHelperAlphaMetadataOrientationAndFiniteBlack() throws {
        let environment = ProcessInfo.processInfo.environment // Test only; never production configuration
        let path = try #require(environment["BLURACTION_TEST_HEIC_CPU_HELPER"])
        let expected = try #require(environment["BLURACTION_TEST_HEIC_CPU_HELPER_SHA256"])
        let executable = HEICCPUEncoder.Helper(url: URL(fileURLWithPath: path), sha256: expected)
        let parent = try directory(); defer { try? FileManager.default.removeItem(at: parent) }
        let sentinel = parent.appendingPathComponent("existing.heic")
        let nonce = Data(UUID().uuidString.utf8)
        try nonce.write(to: sentinel, options: .withoutOverwriting)
        for alpha in [false, true] {
            let (source, original) = try image(alpha: alpha)
            let before = digest(original)
            let pixels = try HEICCPUEncoder.normalizedPixels(source)
            var attempt: URL?
            let bytes = try HEICCPUEncoder.encode(image: source, quality: 0.9, helper: executable,
                hooks: .init(temporaryParent: parent, onAttempt: { attempt = $0 }))
            let reader = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
            #expect(CGImageSourceGetType(reader).map { $0 as String } == "public.heic")
            let decoded = try #require(CGImageSourceCreateImageAtIndex(reader, 0, nil))
            let native = try HEICCPUEncoder.normalizedPixels(decoded)
            for offset in stride(from: 3, to: native.rgba.count, by: 4) {
                #expect(native.rgba[offset] == pixels.rgba[offset])
            }
            let center = (32 * 96 + 48) * 4
            #expect(Array(native.rgba[center..<center+4]) == [0, 0, 0, 255])
            let row60 = (60 * 96 + 3) * 4, row3 = (3 * 96 + 3) * 4
            let partial = (5 * 96 + 80) * 4
            // Observe orientation below; row association is already tested by
            // exact opaque corners and full alpha coverage. No lossy RGB tolerance.
            print("HEIC_CPU_ACTUAL alpha=\(alpha) bytesSHA256=\(digest(bytes)) row3RGB=\(Array(native.rgba[row3..<row3+3])) row60RGB=\(Array(native.rgba[row60..<row60+3])) partialInputRGBA=\(Array(pixels.rgba[partial..<partial+4])) partialOutputRGBA=\(Array(native.rgba[partial..<partial+4]))")
            let properties = CGImageSourceCopyPropertiesAtIndex(reader, 0, nil) as? [String: Any] ?? [:]
            #expect(properties[kCGImagePropertyExifDictionary as String] == nil)
            #expect(properties[kCGImagePropertyGPSDictionary as String] == nil)
            #expect(properties[kCGImagePropertyOrientation as String] == nil || properties[kCGImagePropertyOrientation as String] as? Int == 1)
            let sourceAfter = try #require(source.dataProvider?.data) as Data
            #expect(digest(sourceAfter) == before)
            let owned = try #require(attempt)
            #expect(!FileManager.default.fileExists(atPath: owned.path))
        }
        let unchanged = try Data(contentsOf: sentinel)
        #expect(unchanged == nonce)
        var blackBytes = [UInt8]()
        for _ in 0..<(48 * 32) { blackBytes += [0, 0, 0, 255] }
        let blackProvider = try #require(CGDataProvider(data: Data(blackBytes) as CFData))
        let black = try #require(CGImage(width: 48, height: 32, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 48 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: blackProvider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let blackHEIC = try HEICCPUEncoder.encode(image: black, quality: 0.9, helper: executable,
                                                hooks: .init(temporaryParent: parent))
        let blackReader = try #require(CGImageSourceCreateWithData(blackHEIC as CFData, nil))
        let blackImage = try #require(CGImageSourceCreateImageAtIndex(blackReader, 0, nil))
        let blackNative = try HEICCPUEncoder.normalizedPixels(blackImage)
        #expect(blackNative.rgba == Data(blackBytes))
        // Real late successful output must still be discarded on final cancel.
        let (source, _) = try image()
        var cancelled = false
        let late = try failure {
            try HEICCPUEncoder.encode(image: source, quality: 0.9, helper: executable,
                cancel: { cancelled }, hooks: .init(temporaryParent: parent, removeDirectory: { url in
                    try FileManager.default.removeItem(at: url); cancelled = true
                }))
        }
        #expect(isError(late.primary, .cancelled) && !late.cleanupNeedsRetry)
    }
}
