// QA-only independent ImageIO decode. Does not invoke the failing native HEIC
// encoder or CoreImage.writeHEIFRepresentation. Compile/run only by root.
import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import Darwin

enum Failure: Error { case invalidInput, decode, dimensions, output, changed }

@main struct NativeReadback {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw Failure.invalidInput }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        guard source.lastPathComponent == "candidate.heic",
              source.deletingLastPathComponent().resolvingSymlinksInPath() == source.deletingLastPathComponent(),
              directory.lastPathComponent == "imageio",
              directory.deletingLastPathComponent() == source.deletingLastPathComponent(),
              directory.resolvingSymlinksInPath() == directory else { throw Failure.invalidInput }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 256 * 1024 * 1024 else { throw Failure.invalidInput }
        let data = try Data(contentsOf: source)
        let before = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(imageSource) == 1,
              let type = CGImageSourceGetType(imageSource),
              (type as String) == "public.heic",
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw Failure.decode }
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 24_000_000 / height else { throw Failure.dimensions }
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] ?? [:]
        let orientation = properties[kCGImagePropertyOrientation as String] as? Int
        let metadataAbsent = properties[kCGImagePropertyExifDictionary as String] == nil &&
            properties[kCGImagePropertyGPSDictionary as String] == nil &&
            properties[kCGImagePropertyIPTCDictionary as String] == nil &&
            (orientation == nil || orientation == 1)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        guard rendered else { throw Failure.decode }
        let afterData = try Data(contentsOf: source)
        guard afterData == data else { throw Failure.changed }
        let report: [String: Any] = ["status": "native-readback-complete", "type": type as String,
            "width": width, "height": height, "sourceSHA256": before,
            "sourceBytesUnchanged": true, "sourceMetadataAbsent": metadataAbsent,
            "nativeAlphaInfo": image.alphaInfo.rawValue,
            "nativeBitsPerComponent": image.bitsPerComponent,
            "colorSpaceName": image.colorSpace?.name.map { $0 as String } ?? "unreported",
            "outputPixelPolicy": "CoreGraphics sRGB RGBA8 premultipliedLast byteOrder32Big",
            "encoderVerified": false, "HDRVerified": false, "releaseApproved": false]
        try exclusive(Data(rgba), directory.appendingPathComponent("native-premultiplied.rgba"))
        try exclusive(try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
                      directory.appendingPathComponent("native-report.json"))
    }

    static func exclusive(_ data: Data, _ url: URL) throws {
        let descriptor = open(url.path, O_CREAT | O_EXCL | O_NOFOLLOW | O_WRONLY | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.output }
        defer { close(descriptor) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.output }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw Failure.output }
    }
}
