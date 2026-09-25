import AppKit
import Testing
import UniformTypeIdentifiers
import ImageIO
@testable import BlurAction

@Suite(.serialized)
struct ImageSavePanelTests {
    @MainActor
    @Test
    func testSuggestionSkipsDanglingSymlink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("input_blurred.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.appendingPathComponent("missing.png"))
        let output = ImageSavePanel.suggestedURL(original: directory.appendingPathComponent("input.png"), type: .png)
        #expect(output.lastPathComponent == "input_blurred(1).png")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path).hasSuffix("missing.png"))
    }

    @MainActor
    @Test
    func testLongDecomposedKoreanNameExportsAndCollisionKeepsSuffix() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = String(repeating: "긴한글합성이미지파일이름검증용", count: 6)
            .decomposedStringWithCanonicalMapping + ".png"
        let original = directory.appendingPathComponent(name)
        let context = try #require(CGContext(data: nil, width: 32, height: 24,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let image = try #require(context.makeImage())
        let writer = try #require(CGImageDestinationCreateWithURL(original as CFURL,
            UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, nil)
        try #require(CGImageDestinationFinalize(writer))
        let input = try Data(contentsOf: original)
        var names = Set<String>()
        for _ in 0..<3 {
            let panel = ImageSavePanel.make(original: original, type: .png)
            let filename = panel.nameFieldStringValue
            #expect(filename == filename.precomposedStringWithCanonicalMapping)
            #expect(filename.utf8.count <= 255)
            #expect(filename.decomposedStringWithCanonicalMapping.utf8.count <= 255)
            #expect(filename.hasSuffix(".png"))
            #expect(filename.contains("_blurred"))
            #expect(names.insert(filename).inserted)
            let output = directory.appendingPathComponent(filename)
            try BlurredImageExporter.export(source: image, pairs: [], canvasSize: CGSize(width: 32, height: 24),
                inputURL: original, outputURL: output, type: .png, quality: 1)
            let reader = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
            let saved = try #require(CGImageSourceCreateImageAtIndex(reader, 0, nil))
            #expect(saved.width == 32 && saved.height == 24)
            #expect(try Data(contentsOf: original) == input)
        }
    }

    @MainActor
    @Test
    func testTruncationDoesNotSplitEmojiAndReservesCollisionDigits() {
        let stem = String(repeating: "👩🏽‍💻가", count: 60)
        for ext in ["png", "jpeg", "heic", "tiff"] {
            let filename = ImageSavePanel.filename(stem: stem, extension: ext, collision: 12345)
            #expect(filename.hasSuffix("_blurred(12345).\(ext)"))
            #expect(filename.decomposedStringWithCanonicalMapping.utf8.count <= 255)
            let prefix = filename.components(separatedBy: "_blurred")[0]
            #expect(stem.hasPrefix(prefix))
        }
    }

    @MainActor
    @Test
    func testEveryFormatHasMatchingNameAndPreservesExistingFiles() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("합성 이미지.tiff")
        let sentinel = Data("synthetic original".utf8)
        try sentinel.write(to: original)
        for type in [UTType.png, .jpeg, .heic, .tiff] {
            let ext = try #require(type.preferredFilenameExtension)
            let existing = directory.appendingPathComponent("합성 이미지_blurred.\(ext)")
            try sentinel.write(to: existing)
            let panel = ImageSavePanel.make(original: original, type: type)
            #expect(panel.allowedContentTypes == [type])
            #expect(!panel.allowsOtherFileTypes)
            #expect(panel.canCreateDirectories)
            #expect(panel.directoryURL?.standardizedFileURL == directory.standardizedFileURL)
            #expect(panel.nameFieldStringValue == "합성 이미지_blurred(1).\(ext)")
            #expect(try Data(contentsOf: original) == sentinel)
            #expect(try Data(contentsOf: existing) == sentinel)
        }
    }
}
