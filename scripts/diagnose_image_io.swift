// Standalone synthetic ImageIO/Core Image diagnostic. No BlurAction import or input media.
// Compile/run are delegated to the verification coordinator; see ImageIODiagnosticPlan.md.
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Darwin

private enum ProbeError: Error {
    case usage, invalidParent, identityChanged, allocationFailed, fileBudgetExceeded
}

// Flush a small checkpoint before native calls. A crash must leave its last
// attempted stage, rather than erase every observation until the final JSON.
private func progress(_ stage: String, _ values: [String: Any] = [:]) {
    var entry = values
    entry["diagnosticStage"] = stage
    if let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) {
        FileHandle.standardError.write(data + Data([10]))
    }
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func errorInfo(_ error: Error) -> [String: Any] {
    let native = error as NSError
    return ["domain": native.domain, "code": native.code,
            "description": String(native.localizedDescription.prefix(1024)),
            "underlying": (native.userInfo[NSUnderlyingErrorKey] as? NSError).map {
                ["domain": $0.domain, "code": $0.code,
                 "description": String($0.localizedDescription.prefix(1024))] as [String: Any]
            } ?? [:]]
}

private func colorSpaceInfo(_ space: CGColorSpace?) -> [String: Any] {
    guard let space else { return ["present": false] }
    return ["present": true, "name": space.name.map { $0 as String } ?? "unnamed",
            "model": space.model.rawValue, "components": space.numberOfComponents,
            "wideGamutRGB": space.isWideGamutRGB]
}

private func imageInfo(_ image: CGImage) -> [String: Any] {
    var result: [String: Any] = [
        "width": image.width, "height": image.height,
        "bitsPerComponent": image.bitsPerComponent, "bitsPerPixel": image.bitsPerPixel,
        "bytesPerRow": image.bytesPerRow, "alphaInfo": image.alphaInfo.rawValue,
        "bitmapInfo": image.bitmapInfo.rawValue,
        "floatComponents": image.bitmapInfo.contains(.floatComponents),
        "colorSpace": colorSpaceInfo(image.colorSpace)
    ]
    if let bytes = image.dataProvider?.data { result["providerSHA256"] = digest(bytes as Data) }
    return result
}

private func rgbaObservation(_ image: CGImage) throws -> [String: Any] {
    guard image.width > 0, image.height > 0, image.width <= 256, image.height <= 128,
          let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw ProbeError.fileBudgetExceeded }
    var bytes = Data(count: image.width * image.height * 4)
    let drew = bytes.withUnsafeMutableBytes { raw -> Bool in
        guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    guard drew else { throw ProbeError.allocationFailed }
    var samples: [[String: Any]] = []
    for y in [image.height / 4, image.height * 3 / 4] {
        for x in [image.width / 6, image.width / 2, image.width * 5 / 6] {
            let offset = (y * image.width + x) * 4
            samples.append(["x": x, "y": y, "rgba": Array(bytes[offset..<(offset + 4)])])
        }
    }
    return ["format": "sRGB-RGBA8-premultipliedLast-CoreGraphics-copy",
            "SHA256": digest(bytes), "tileInteriorSamples": samples]
}

// Only opaque authored RGB colors. The 48x32 case matches the existing six-tile fixture.
private func makeSource(width: Int, height: Int, space: CGColorSpace) throws -> (CGImage, Data) {
    let colors: [[UInt8]] = [[255,0,0,255], [0,255,0,255], [0,0,255,255],
                             [0,255,255,255], [255,0,255,255], [255,255,0,255]]
    var bytes = Data(count: width * height * 4)
    bytes.withUnsafeMutableBytes { raw in
        let pixels = raw.bindMemory(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let color = colors[min(2, x * 3 / width) + (y < height / 2 ? 0 : 3)]
                let offset = (y * width + x) * 4
                for c in 0..<4 { pixels[offset + c] = color[c] }
            }
        }
    }
    guard let provider = CGDataProvider(data: bytes as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8,
              bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { throw ProbeError.allocationFailed }
    return (image, bytes)
}

// The directory and each candidate are created exclusively. Existing paths are never reused.
private final class OwnedDirectory {
    let url: URL
    private let device: dev_t
    private let inode: ino_t

    init(parent: URL) throws {
        var parentStat = stat()
        guard parent.isFileURL, !parent.path.utf8.contains(0),
              lstat(parent.path, &parentStat) == 0,
              (parentStat.st_mode & S_IFMT) == S_IFDIR,
              parent.standardizedFileURL == parent.resolvingSymlinksInPath().standardizedFileURL
        else { throw ProbeError.invalidParent }
        url = parent.appendingPathComponent("image-io-diagnostic-" + UUID().uuidString,
                                           isDirectory: true)
        guard mkdir(url.path, mode_t(0o700)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var status = stat()
        guard lstat(url.path, &status) == 0 else { throw ProbeError.identityChanged }
        device = status.st_dev
        inode = status.st_ino
    }

    func check() throws {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_dev == device, status.st_ino == inode,
              (status.st_mode & S_IFMT) == S_IFDIR else { throw ProbeError.identityChanged }
    }

    func reserve(_ name: String) throws -> URL {
        try check()
        let candidate = url.appendingPathComponent(name)
        let fd = open(candidate.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard Darwin.close(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return candidate
    }

    func cleanup() throws {
        try check()
        // Only the exact private UUID directory captured at creation is removed.
        try FileManager.default.removeItem(at: url)
    }
}

private func outputInfo(_ url: URL, expectedType: String, width: Int, height: Int) throws -> [String: Any] {
    var status = stat()
    guard lstat(url.path, &status) == 0,
          (status.st_mode & S_IFMT) == S_IFREG, status.st_size >= 0,
          status.st_size <= 16 * 1024 * 1024 else { throw ProbeError.fileBudgetExceeded }
    let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
    var result: [String: Any] = ["path": url.path, "fileBytes": bytes.count,
                                "fileSHA256": digest(bytes), "readbackSucceeded": false]
    guard let source = CGImageSourceCreateWithData(bytes as CFData, nil) else {
        result["readbackStage"] = "image-source-create-failed"
        return result
    }
    let actualType = CGImageSourceGetType(source).map { $0 as String } ?? "unknown"
    result["actualType"] = actualType
    result["expectedType"] = expectedType
    result["imageCount"] = CGImageSourceGetCount(source)
    result["sourceStatus"] = CGImageSourceGetStatus(source).rawValue
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
    let metadataWidth = (properties?[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue
    let metadataHeight = (properties?[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue
    result["metadataWidth"] = metadataWidth ?? -1
    result["metadataHeight"] = metadataHeight ?? -1
    // Never decode an unexpected dimension allocation, even if the file was authored here.
    guard metadataWidth == width, metadataHeight == height, width <= 256, height <= 128 else {
        result["readbackStage"] = "metadata-dimension-mismatch"
        return result
    }
    guard let decoded = CGImageSourceCreateImageAtIndex(source, 0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
        result["readbackStage"] = "image-decode-failed"
        return result
    }
    result["decoded"] = imageInfo(decoded)
    result["decodedRGBAObservation"] = try rgbaObservation(decoded)
    result["readbackSucceeded"] = actualType == expectedType &&
        CGImageSourceGetCount(source) == 1 && decoded.width == width && decoded.height == height
    result["readbackStage"] = "decoded"
    // This is decode/format evidence; lossy HEIC/JPEG pixels are not declared exact RGB parity.
    return result
}

private func encode(_ image: CGImage, variant: String, contextOptions: [String: Any],
                    type: UTType, directory: OwnedDirectory, listed: Bool) -> [String: Any] {
    let witness: [String: Any] = ["variant": variant, "type": type.identifier,
        "width": image.width, "height": image.height]
    progress("image-properties", witness)
    var result: [String: Any] = ["variant": variant, "contextOptions": contextOptions,
        "type": type.identifier, "listedAsImageIODestination": listed,
        "sourceCGImage": imageInfo(image), "destinationCreated": false,
        "nativeFinalize": NSNull(), "succeeded": false]
    do {
        let ext = type.preferredFilenameExtension ?? "bin"
        let url = try directory.reserve("\(image.width)x\(image.height)-\(variant).\(ext)")
        result["path"] = url.path
        progress("destination-create", witness)
        if let destination = CGImageDestinationCreateWithURL(url as CFURL,
                type.identifier as CFString, 1, nil) {
            result["destinationCreated"] = true
            progress("destination-add-image", witness)
            CGImageDestinationAddImage(destination, image, [
                kCGImageDestinationLossyCompressionQuality: 1.0,
                kCGImagePropertyOrientation: 1
            ] as CFDictionary)
            progress("destination-finalize", witness)
            let finalized = CGImageDestinationFinalize(destination)
            result["nativeFinalize"] = finalized
            result["stage"] = finalized ? "finalized" : "finalize-failed"
        } else { result["stage"] = "destination-create-failed" }
        progress("destination-readback", witness)
        let readback = try outputInfo(url, expectedType: type.identifier,
                                      width: image.width, height: image.height)
        result["readback"] = readback
        result["succeeded"] = (result["nativeFinalize"] as? Bool == true) &&
                              (readback["readbackSucceeded"] as? Bool == true)
    } catch {
        result["error"] = errorInfo(error)
        result["stage"] = "diagnostic-file-error"
    }
    progress("image-attempt-complete", witness.merging(["succeeded": result["succeeded"] ?? false]) { _, new in new })
    return result
}

private func softwareHEIF(_ image: CIImage, width: Int, height: Int,
                          context: CIContext, space: CGColorSpace,
                          directory: OwnedDirectory) -> [String: Any] {
    var result: [String: Any] = ["variant": "software-writeHEIFRepresentation",
        "width": width, "height": height, "format": "RGBA8", "colorSpace": "sRGB",
        "useSoftwareRenderer": true, "apiReturnedWithoutError": false,
        "nativeFinalize": NSNull(), "succeeded": false]
    do {
        let url = try directory.reserve("\(width)x\(height)-software-writeHEIFRepresentation.heic")
        result["path"] = url.path
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 1.0
        ]
        progress("software-heif-write", ["width": width, "height": height])
        try context.writeHEIFRepresentation(of: image, to: url, format: .RGBA8,
                                           colorSpace: space, options: options)
        result["apiReturnedWithoutError"] = true
        result["stage"] = "write-returned"
        let readback = try outputInfo(url, expectedType: UTType.heic.identifier, width: width, height: height)
        result["readback"] = readback
        result["succeeded"] = readback["readbackSucceeded"] as? Bool == true
    } catch {
        result["error"] = errorInfo(error)
        result["stage"] = "write-or-readback-failed"
        if let path = result["path"] as? String,
           let info = try? outputInfo(URL(fileURLWithPath: path), expectedType: UTType.heic.identifier,
                                      width: width, height: height) { result["readback"] = info }
    }
    return result
}

@main
private struct ImageIODiagnostic {
    static func main() {
        progress("main-enter")
        var report: [String: Any] = ["schemaVersion": 1, "diagnosticOnly": true,
            "productCodeExecuted": false, "existingFilesOverwritten": false,
            "physicalDeviceCapabilityVerified": false,
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "softwareRendererIsNotSoftwareEncoderGuarantee": true,
            "stderrCaptureRequired": true, "results": []]
        var exitStatus: Int32 = 1
        var cleanup = false
        var ownedDirectory: OwnedDirectory?
        #if arch(arm64)
        report["architecture"] = "arm64"
        #elseif arch(x86_64)
        report["architecture"] = "x86_64"
        #else
        report["architecture"] = "other"
        #endif
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            var parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            var i = 0
            while i < args.count {
                if args[i] == "--cleanup" { cleanup = true; i += 1 }
                else if args[i] == "--output-parent", i + 1 < args.count, args[i + 1].hasPrefix("/") {
                    parent = URL(fileURLWithPath: args[i + 1], isDirectory: true); i += 2
                } else { throw ProbeError.usage }
            }
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw ProbeError.allocationFailed }
            let directory = try OwnedDirectory(parent: parent)
            ownedDirectory = directory
            report["outputDirectory"] = directory.url.path
            report["cleanupRequested"] = cleanup
            report["retainedArtifacts"] = true
            report["bounds"] = ["maxSourcePixels": 32768, "sourceCount": 3,
                "imageIOAttemptCount": 48, "separateHEIFAttemptCount": 3,
                "maxReadbackFileBytes": 16 * 1024 * 1024,
                "nativeHangDeadline": "caller must impose a bounded process deadline"]
            let types = [UTType.png, .jpeg, .heic, .tiff]
            let destinationTypes = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
            report["imageIODestinationTypeIdentifiers"] = destinationTypes.sorted()
            progress("default-context-create")
            let defaultContext = CIContext()
            progress("software-context-create")
            let softwareContext = CIContext(options: [.useSoftwareRenderer: true,
                .workingColorSpace: space, .outputColorSpace: space, .cacheIntermediates: false])
            progress("context-properties")
            report["contexts"] = [
                "default": ["requestedOptions": [:] as [String: Any],
                    "workingFormatRaw": defaultContext.workingFormat.rawValue,
                    "workingColorSpace": colorSpaceInfo(defaultContext.workingColorSpace)],
                "software": ["requestedOptions": ["useSoftwareRenderer": true,
                    "workingColorSpace": "sRGB", "outputColorSpace": "sRGB", "cacheIntermediates": false],
                    "workingFormatRaw": softwareContext.workingFormat.rawValue,
                    "workingColorSpace": colorSpaceInfo(softwareContext.workingColorSpace)]
            ]
            var results: [[String: Any]] = []
            var sources: [[String: Any]] = []
            var preserved = true
            for (width, height) in [(48, 32), (96, 64), (256, 128)] {
                try autoreleasepool {
                    progress("source-create", ["width": width, "height": height])
                    let (source, bytes) = try makeSource(width: width, height: height, space: space)
                    let before = digest(bytes)
                    let ci = CIImage(cgImage: source)
                    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
                    // Lazy factories avoid retaining multiple rendered buffers across encoding attempts.
                    let variants: [(String, [String: Any], () -> CGImage?)] = [
                        ("direct-source", ["context": "none"], { source }),
                        ("default-CI", ["context": "default", "requestedFormat": "unspecified"], {
                            defaultContext.createCGImage(ci, from: bounds)
                        }),
                        ("explicit-RGBA8-sRGB", ["context": "default", "requestedFormat": "RGBA8", "outputColorSpace": "sRGB"], {
                            defaultContext.createCGImage(ci, from: bounds, format: .RGBA8, colorSpace: space)
                        }),
                        ("software-RGBA8-sRGB", ["context": "software", "useSoftwareRenderer": true,
                            "requestedFormat": "RGBA8", "workingColorSpace": "sRGB", "outputColorSpace": "sRGB"], {
                            softwareContext.createCGImage(ci, from: bounds, format: .RGBA8, colorSpace: space)
                        })
                    ]
                    for (name, options, create) in variants {
                        autoreleasepool {
                            progress("variant-create", ["variant": name, "width": width, "height": height])
                            if let rendered = create() {
                                for type in types {
                                    let result = autoreleasepool {
                                        encode(rendered, variant: name, contextOptions: options, type: type,
                                               directory: directory, listed: destinationTypes.contains(type.identifier))
                                    }
                                    results.append(result)
                                }
                            } else {
                                for type in types { results.append(["variant": name, "contextOptions": options,
                                    "width": width, "height": height, "type": type.identifier,
                                    "stage": "createCGImage-failed", "succeeded": false]) }
                            }
                        }
                    }
                    results.append(autoreleasepool {
                        softwareHEIF(ci, width: width, height: height, context: softwareContext,
                                     space: space, directory: directory)
                    })
                    let after = digest(bytes)
                    let providerAfter: String?
                    if let providerBytes = source.dataProvider?.data { providerAfter = digest(providerBytes as Data) }
                    else { providerAfter = nil }
                    let same = before == after && providerAfter == before
                    preserved = preserved && same
                    sources.append(["sourceCGImage": imageInfo(source), "authoredRGBA8SHA256": before,
                                    "sourceRGBAObservation": try rgbaObservation(source), "sourcePreserved": same])
                    defaultContext.clearCaches()
                    softwareContext.clearCaches()
                }
            }
            let failures = results.filter { $0["succeeded"] as? Bool != true }.count
            report["sources"] = sources
            report["results"] = results
            report["attemptCount"] = results.count
            report["failedAttemptCount"] = failures
            report["sourcesPreserved"] = preserved
            report["status"] = failures == 0 && preserved ? "all-diagnostic-encodes-readable" : "diagnostic-failures-observed"
            exitStatus = failures == 0 && preserved ? 0 : 3
        } catch {
            report["status"] = "diagnostic-incomplete"
            report["error"] = errorInfo(error)
        }
        if cleanup, let directory = ownedDirectory {
            do { try directory.cleanup(); report["retainedArtifacts"] = false; report["cleanupSucceeded"] = true }
            catch { report["cleanupSucceeded"] = false; report["cleanupError"] = errorInfo(error); exitStatus = 1 }
        }
        do {
            let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(bytes)
            FileHandle.standardOutput.write(Data([10]))
        } catch {
            FileHandle.standardError.write(Data("diagnostic JSON serialization failed\n".utf8))
            exitStatus = 1
        }
        exit(exitStatus)
    }
}
