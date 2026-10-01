import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import BlurAction

@Suite(.serialized)
struct WorkspaceBoundaryRegressionTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blur-workspace-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func image(at url: URL) throws {
        let context = try #require(CGContext(data: nil, width: 16, height: 12,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        let writer = try #require(CGImageDestinationCreateWithURL(url as CFURL,
            UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(writer))
    }

    private func pdf(at url: URL, pages: Int) throws {
        var box = CGRect(x: 0, y: 0, width: 12, height: 16)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 0..<pages {
            context.beginPage(mediaBox: &box)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(box)
            context.endPage()
        }
        context.closePDF()
    }

    @Test
    func mixedPDFAndImagePageLimitIsIndependentOfInputOrderAndSavedProjectsReopen() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("source.png")
        let acceptedPDF = dir.appendingPathComponent("199-pages.pdf")
        let rejectedPDF = dir.appendingPathComponent("200-pages.pdf")
        try image(at: png)
        try pdf(at: acceptedPDF, pages: 199)
        try pdf(at: rejectedPDF, pages: 200)
        let originals = try [png, acceptedPDF, rejectedPDF].map { try Data(contentsOf: $0) }

        for inputs in [[acceptedPDF, png], [png, acceptedPDF]] {
            let workspace = try PageWorkspace.open(inputs)
            #expect(workspace.pages.count == 200)
            let projectURL = dir.appendingPathComponent("accepted.bluraction")
            let encoded = try MultiPageProjectFile.from(workspace, projectURL: projectURL).encoded()
            let restored = try MultiPageProjectFile.decode(encoded).workspace(relativeTo: projectURL)
            #expect(restored.pages.count == 200)
        }
        for inputs in [[rejectedPDF, png], [png, rejectedPDF]] {
            #expect(throws: PageWorkspace.WorkspaceError.tooManyPages) {
                try PageWorkspace.open(inputs)
            }
        }
        #expect(try [png, acceptedPDF, rejectedPDF].map { try Data(contentsOf: $0) } == originals)
    }

    @Test
    func encodingRejectsSessionsThatDecodingCannotReopen() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.png")
        try image(at: source)
        let valid = try MultiPageProjectFile.from(PageWorkspace.open([source]),
            projectURL: dir.appendingPathComponent("session.bluraction"))
        var tooMany = valid
        tooMany.pages = Array(repeating: valid.pages[0], count: 201)
        var longTitle = valid
        longTitle.title = String(repeating: "a", count: 256)
        var invalidIndex = valid
        invalidIndex.currentIndex = 1
        var invalidGeometryVersion = valid
        invalidGeometryVersion.pages[0].pdfGeometryVersion = 1

        for invalid in [tooMany, longTitle, invalidIndex, invalidGeometryVersion] {
            #expect(throws: ProjectFile.ProjectError.invalidContent) { try invalid.encoded() }
            // Model a pre-existing file, independently of the now-validated save path.
            let savedBytes = try JSONEncoder().encode(invalid)
            #expect(throws: ProjectFile.ProjectError.invalidContent) {
                try MultiPageProjectFile.decode(savedBytes)
            }
        }
        #expect(try MultiPageProjectFile.decode(valid.encoded()).pages.count == 1)
    }

    @Test(arguments: [251, 255])
    func validLongPDFNamesAndPreviouslySavedTitlesReopen(length: Int) throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = String(repeating: "a", count: length - 4) + ".pdf"
        let source = dir.appendingPathComponent(name)
        try pdf(at: source, pages: 1)
        let original = try Data(contentsOf: source)
        let workspace = try PageWorkspace.open([source])
        #expect(workspace.title == name)
        let projectURL = dir.appendingPathComponent("short-name.bluraction")
        let project = try MultiPageProjectFile.from(workspace, projectURL: projectURL)
        let encoded = try project.encoded()
        try encoded.write(to: projectURL, options: .withoutOverwriting)
        let restored = try MultiPageProjectFile.decode(Data(contentsOf: projectURL))
            .workspace(relativeTo: projectURL)
        #expect(restored.title == name && restored.pages.count == 1)

        var legacy = project
        legacy.pages[0].pdfGeometryVersion = nil
        let previouslySaved = try JSONEncoder().encode(legacy)
        let legacyRestored = try MultiPageProjectFile.decode(previouslySaved).workspace(relativeTo: projectURL)
        #expect(legacyRestored.title == name && legacyRestored.pages.count == 1)
        #expect(try Data(contentsOf: source) == original)
        #expect(try Data(contentsOf: projectURL) == encoded)
    }

    @Test(arguments: [250, 251])
    func longPDFOutputNamesProduceSeparatePNGDirectoriesWithoutOverwriting(stemLength: Int) throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.png")
        try image(at: source)
        let original = try Data(contentsOf: source)
        let workspace = try PageWorkspace.open([source])
        let output = dir.appendingPathComponent(String(repeating: "b", count: stemLength) + ".pdf")
        try workspace.exportPDF(to: output)
        let savedPDF = try Data(contentsOf: output)
        let first = try #require(try workspace.exportImageFiles(near: output))
        #expect(first.lastPathComponent.hasSuffix("_images"))
        let firstPNG = first.appendingPathComponent("001_source_blurred.png")
        let firstBytes = try Data(contentsOf: firstPNG)
        let second = try #require(try workspace.exportImageFiles(near: output))
        #expect(first != second)
        #expect(second.lastPathComponent.hasSuffix("_images(1)"))
        for folder in [first, second] {
            #expect(folder.lastPathComponent.utf8.count <= 255)
            #expect(folder.lastPathComponent.decomposedStringWithCanonicalMapping.utf8.count <= 255)
            let contents = try FileManager.default.contentsOfDirectory(at: folder,
                includingPropertiesForKeys: nil)
            #expect(contents.count == 1)
            let reader = try #require(CGImageSourceCreateWithURL(contents[0] as CFURL, nil))
            let pixels = try #require(CGImageSourceCreateImageAtIndex(reader, 0, nil))
            #expect(pixels.width == 16 && pixels.height == 12)
        }
        #expect(try Data(contentsOf: firstPNG) == firstBytes)
        #expect(try Data(contentsOf: output) == savedPDF)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test
    func invalidImageDirectoryPathReportsPathErrorInsteadOfCollision() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.png")
        try image(at: source)
        let workspace = try PageWorkspace.open([source])
        let output = dir.appendingPathComponent("saved.pdf")
        try workspace.exportPDF(to: output)
        let savedPDF = try Data(contentsOf: output)
        let invalidParent = dir.appendingPathComponent(String(repeating: "p", count: 256), isDirectory: true)
        do {
            _ = try workspace.exportImageFiles(near: invalidParent.appendingPathComponent("output.pdf"))
            Issue.record("Expected a filename-too-long path error")
        } catch let error as POSIXError {
            #expect(error.code == .ENAMETOOLONG)
        }
        #expect(try Data(contentsOf: output) == savedPDF)
    }

    @Test
    func lastFolderCollisionSlotSucceedsAndExhaustionPreservesExistingResults() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.png")
        try image(at: source)
        let original = try Data(contentsOf: source)
        let workspace = try PageWorkspace.open([source])
        let output = dir.appendingPathComponent("result.pdf")
        try workspace.exportPDF(to: output)
        let savedPDF = try Data(contentsOf: output)
        for collision in 0..<999 {
            let name = "result_images" + (collision == 0 ? "" : "(\(collision))")
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(name),
                withIntermediateDirectories: false)
        }
        let sentinelURL = dir.appendingPathComponent("result_images/keep.txt")
        let sentinel = Data("synthetic existing result".utf8)
        try sentinel.write(to: sentinelURL, options: .withoutOverwriting)
        let last = try #require(try workspace.exportImageFiles(near: output))
        #expect(last.lastPathComponent == "result_images(999)")
        let lastPNG = last.appendingPathComponent("001_source_blurred.png")
        let result = try Data(contentsOf: lastPNG)
        #expect(throws: PageWorkspace.WorkspaceError.destinationExists) {
            try workspace.exportImageFiles(near: output)
        }
        #expect(try Data(contentsOf: lastPNG) == result)
        #expect(try Data(contentsOf: sentinelURL) == sentinel)
        #expect(try Data(contentsOf: output) == savedPDF)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test
    func reservedFolderEndingsKeepCollisionDigitsAndUnicodeGraphemes() {
        let stems = [String(repeating: "가👩🏽‍💻", count: 60),
                     String(repeating: "합성이미지", count: 30).decomposedStringWithCanonicalMapping]
        for stem in stems {
            var names = Set<String>()
            for collision in [0, 1, 999] {
                let ending = "_images" + (collision == 0 ? "" : "(\(collision))")
                let name = ImageSavePanel.boundedName(stem: stem, ending: ending)
                #expect(name.hasSuffix(ending))
                #expect(name.utf8.count <= 255)
                #expect(name.decomposedStringWithCanonicalMapping.utf8.count <= 255)
                let prefix = String(name.dropLast(ending.count))
                #expect(stem.precomposedStringWithCanonicalMapping.hasPrefix(prefix))
                #expect(names.insert(name).inserted)
            }
        }
    }
}
