import AppKit
import CoreImage
import CoreText
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import BlurAction

@Suite(.serialized)
struct PageWorkspaceTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blur-pages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func image(at url: URL, color: CGColor) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8,
                                bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func redPixel(in url: URL, x: Int, y: Int) throws -> UInt8 {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let crop = try #require(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &bytes, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return bytes[0]
    }

    @Test
    func multipleImagesExportSeparatePNGsAndOneFlattenedPDF() throws {
        let dir = try directory()
        let first = dir.appendingPathComponent("first.png")
        let second = dir.appendingPathComponent("second.png")
        try image(at: first, color: .init(red: 1, green: 1, blue: 1, alpha: 1))
        try image(at: second, color: .init(red: 1, green: 1, blue: 1, alpha: 1))
        let before = try [Data(contentsOf: first), Data(contentsOf: second)]
        var workspace = try PageWorkspace.open([first, second])
        var effect = RegionEffect()
        effect.style = .solid
        effect.featherRadius = 0
        workspace.pages[0].regions = [ProjectFile.Region(
            shape: .rectangle(id: UUID(), origin: CGPoint(x: 0.1, y: 0.1),
                              size: CGSize(width: 0.4, height: 0.4)), effect: effect)]
        let projectURL = dir.appendingPathComponent("session.bluraction")
        let project = try MultiPageProjectFile.decode(MultiPageProjectFile.from(workspace, projectURL: projectURL).encoded())
        #expect(project.pages.count == 2)
        #expect(project.pages[0].regions.count == 1)
        let reopened = try project.workspace(relativeTo: projectURL)
        #expect(reopened.pages[0].regions.count == 1)
        #expect(reopened.pages[1].regions.isEmpty)

        let output = dir.appendingPathComponent("result.pdf")
        try workspace.exportPDF(to: output)
        #expect(PDFDocument(url: output)?.pageCount == 2)
        #expect(throws: (any Error).self) { try workspace.exportPDF(to: output) }
        let imageFolder = try #require(try workspace.exportImageFiles(near: output))
        let names = try FileManager.default.contentsOfDirectory(atPath: imageFolder.path)
        #expect(names.count == 2)
        #expect(names.allSatisfy { $0.hasSuffix("_blurred.png") })
        let firstOutput = imageFolder.appendingPathComponent("001_first_blurred.png")
        let secondOutput = imageFolder.appendingPathComponent("002_second_blurred.png")
        #expect(try redPixel(in: firstOutput, x: 20, y: 40) < 30)
        #expect(try redPixel(in: secondOutput, x: 20, y: 40) > 220)
        #expect(try Data(contentsOf: first) == before[0])
        #expect(try Data(contentsOf: second) == before[1])
    }

    @Test
    func changedSourceRequiresPageReviewBeforeExportOrProjectReopen() throws {
        let dir = try directory()
        let source = dir.appendingPathComponent("source.png")
        try image(at: source, color: .init(red: 1, green: 1, blue: 1, alpha: 1))
        let workspace = try PageWorkspace.open([source])
        let projectURL = dir.appendingPathComponent("session.bluraction")
        let saved = try MultiPageProjectFile.decode(
            MultiPageProjectFile.from(workspace, projectURL: projectURL).encoded())
        #expect(saved.pages[0].sourceSHA256?.count == 64)

        try image(at: source, color: .init(red: 0, green: 0, blue: 0, alpha: 1))
        let output = dir.appendingPathComponent("result.pdf")
        #expect(throws: PageWorkspace.WorkspaceError.sourceChanged) {
            try workspace.exportPDF(to: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(throws: PageWorkspace.WorkspaceError.sourceChanged) {
            try saved.workspace(relativeTo: projectURL)
        }
    }

    @Test
    func retargetedParentSymlinkCannotBypassSourceCheck() throws {
        let dir = try directory()
        let firstFolder = dir.appendingPathComponent("first", isDirectory: true)
        let secondFolder = dir.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: false)
        try image(at: firstFolder.appendingPathComponent("page.png"), color: .init(red: 1, green: 1, blue: 1, alpha: 1))
        try image(at: secondFolder.appendingPathComponent("page.png"), color: .init(red: 0, green: 0, blue: 0, alpha: 1))
        let alias = dir.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: firstFolder)
        let workspace = try PageWorkspace.open([alias.appendingPathComponent("page.png")])
        try FileManager.default.moveItem(at: alias, to: dir.appendingPathComponent("old-alias"))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: secondFolder)
        let output = dir.appendingPathComponent("result.pdf")
        #expect(throws: PageWorkspace.WorkspaceError.sourceChanged) {
            try workspace.exportPDF(to: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(throws: PageWorkspace.WorkspaceError.sourceChanged) {
            try MultiPageProjectFile.from(workspace, projectURL: dir.appendingPathComponent("session.bluraction"))
        }
    }

    @Test
    func pdfOpensAsIndividualPages() throws {
        let dir = try directory()
        let source = dir.appendingPathComponent("source.pdf")
        var media = CGRect(x: 0, y: 0, width: 100, height: 80)
        let context = try #require(CGContext(source as CFURL, mediaBox: &media, nil))
        for _ in 0..<3 {
            context.beginPage(mediaBox: &media)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(media)
            let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
            let text = NSAttributedString(string: "SECRET", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                .foregroundColor: NSColor.black
            ])
            context.textPosition = CGPoint(x: 10, y: 30)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPage()
        }
        context.closePDF()
        #expect(PDFDocument(url: source)?.string?.contains("SECRET") == true)
        let workspace = try PageWorkspace.open([source])
        #expect(workspace.pages.count == 3)
        #expect(try workspace.image(at: 2).width > 0)
        let saved = try MultiPageProjectFile.decode(MultiPageProjectFile.from(
            workspace, projectURL: dir.appendingPathComponent("session.bluraction")).encoded())
        #expect(saved.pages[2].pdfPageIndex == 2)
        let output = dir.appendingPathComponent("flattened.pdf")
        try workspace.exportPDF(to: output)
        #expect(PDFDocument(url: output)?.pageCount == 3)
        #expect(PDFDocument(url: output)?.string?.contains("SECRET") != true)
    }

    /// PDFKit draws /Rotate and crop origins itself. Check asymmetric page
    /// geometry and independent corner colors so a rotated/cropped page cannot
    /// pass merely because it has nonempty pixels or a plausible aspect ratio.
    @Test(arguments: [0, 90, 180, 270])
    func pdfRotationAndCropPreserveEdgesAnnotationsAndExportGeometry(rotation: Int) throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let geometries = [
            (CGRect(x: 0, y: 0, width: 100, height: 160), CGRect(x: 0, y: 0, width: 100, height: 160)),
            (CGRect(x: 0, y: 0, width: 120, height: 180), CGRect(x: 10, y: 20, width: 100, height: 140)),
            (CGRect(x: 30, y: 40, width: 120, height: 180), CGRect(x: 40, y: 60, width: 100, height: 140))
        ]
        for (index, geometry) in geometries.enumerated() {
            let source = dir.appendingPathComponent("geometry-\(index).pdf")
            try geometryPDF(at: source, media: geometry.0, crop: geometry.1, rotation: rotation)
            let sourceBytes = try Data(contentsOf: source)
            var workspace = try PageWorkspace.open([source])
            let displayedSize = rotation % 180 == 0 ? geometry.1.size
                : CGSize(width: geometry.1.height, height: geometry.1.width)
            let original = try workspace.image(at: 0)
            #expect(original.width == Int(displayedSize.width * 3))
            #expect(original.height == Int(displayedSize.height * 3))
            try expectPDFGeometryMarkers(original, crop: geometry.1, rotation: rotation)

            var cover = RegionEffect.alwaysOn()
            cover.style = .solid; cover.featherRadius = 0
            workspace.pages[0].regions = [ProjectFile.Region(
                shape: .rectangle(id: UUID(), origin: CGPoint(x: 0.35, y: 0.18),
                                  size: CGSize(width: 0.1, height: 0.1)), effect: cover)]
            workspace.pages[0].drawings = [DrawingAnnotation(kind: .rectangle,
                points: [CGPoint(x: 0.7, y: 0.65), CGPoint(x: 0.8, y: 0.75)],
                color: NSColor(srgbRed: 0, green: 1, blue: 1, alpha: 1),
                lineWidth: 0.002, fillOpacity: 1)]
            let rendered = try workspace.renderedImage(at: 0, context: CIContext())
            #expect(rendered.width == original.width && rendered.height == original.height)
            try expectPDFGeometryMarkers(rendered, crop: geometry.1, rotation: rotation)
            expectPixel(rendered, normalized: CGPoint(x: 0.4, y: 0.23), equals: [0, 0, 0, 255])
            expectPixel(rendered, normalized: CGPoint(x: 0.75, y: 0.7), equals: [0, 255, 255, 255])

            let output = dir.appendingPathComponent("geometry-\(index)-output.pdf")
            try workspace.exportPDF(to: output)
            let page = try #require(PDFDocument(url: output)?.page(at: 0))
            #expect(page.bounds(for: .mediaBox).size == displayedSize)
            #expect(page.rotation == 0)
            let exported = try PageWorkspace.open([output]).image(at: 0)
            #expect(exported.width == original.width && exported.height == original.height)
            try expectPDFGeometryMarkers(exported, crop: geometry.1, rotation: rotation)
            expectPixel(exported, normalized: CGPoint(x: 0.4, y: 0.23), equals: [0, 0, 0, 255])
            expectPixel(exported, normalized: CGPoint(x: 0.75, y: 0.7), equals: [0, 255, 255, 255])
            #expect(try Data(contentsOf: source) == sourceBytes)
        }
    }

    @Test
    func ordinaryPDFNormalizedProjectEditsStillSaveAndRestore() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("ordinary.pdf")
        let box = CGRect(x: 0, y: 0, width: 100, height: 160)
        try geometryPDF(at: source, media: box, crop: box, rotation: 0)
        var workspace = try PageWorkspace.open([source])
        var effect = RegionEffect.alwaysOn(); effect.style = .solid; effect.featherRadius = 0
        workspace.pages[0].regions = [ProjectFile.Region(
            shape: .rectangle(id: UUID(), origin: CGPoint(x: 0.35, y: 0.18),
                              size: CGSize(width: 0.1, height: 0.1)), effect: effect)]
        workspace.pages[0].drawings = [DrawingAnnotation(kind: .rectangle,
            points: [CGPoint(x: 0.7, y: 0.65), CGPoint(x: 0.8, y: 0.75)],
            color: NSColor(srgbRed: 0, green: 1, blue: 1, alpha: 1),
            lineWidth: 0.002, fillOpacity: 1)]
        let projectURL = dir.appendingPathComponent("ordinary.bluraction")
        let project = try MultiPageProjectFile.from(workspace, projectURL: projectURL)
        try project.encoded().write(to: projectURL)
        let reopened = try MultiPageProjectFile.decode(Data(contentsOf: projectURL)).workspace(relativeTo: projectURL)
        #expect(reopened.pages[0].regions == workspace.pages[0].regions)
        #expect(reopened.pages[0].drawings == workspace.pages[0].drawings)
        let image = try reopened.renderedImage(at: 0, context: CIContext())
        try expectPDFGeometryMarkers(image, crop: box, rotation: 0)
        expectPixel(image, normalized: CGPoint(x: 0.4, y: 0.23), equals: [0, 0, 0, 255])
        expectPixel(image, normalized: CGPoint(x: 0.75, y: 0.7), equals: [0, 255, 255, 255])
    }

    @Test
    func legacyPDFEditsRequireReviewOnlyWhenTheirDisplayGeometryChanges() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cases: [(crop: CGRect, rotation: Int, affected: Bool)] = [
            (CGRect(x: 0, y: 0, width: 100, height: 160), 0, false),
            (CGRect(x: 0, y: 0, width: 100, height: 160), 180, false),
            (CGRect(x: 0, y: 0, width: 100, height: 100), 90, false),
            (CGRect(x: 0, y: 0, width: 100, height: 160), 90, true),
            (CGRect(x: 0, y: 0, width: 100, height: 160), 270, true),
            (CGRect(x: 10, y: 20, width: 100, height: 140), 0, true),
            (CGRect(x: 10, y: 20, width: 100, height: 140), 180, true)
        ]
        for (index, item) in cases.enumerated() {
            let source = dir.appendingPathComponent("legacy-\(index).pdf")
            let media = CGRect(x: 0, y: 0, width: max(100, item.crop.maxX), height: max(160, item.crop.maxY))
            try geometryPDF(at: source, media: media, crop: item.crop, rotation: item.rotation)
            let sourceHash = try PageWorkspace.digest(of: source)
            var workspace = try PageWorkspace.open([source])
            var effect = RegionEffect.alwaysOn(); effect.style = .solid; effect.featherRadius = 0
            workspace.pages[0].regions = [ProjectFile.Region(
                shape: .rectangle(id: UUID(), origin: CGPoint(x: 0.2, y: 0.2), size: CGSize(width: 0.2, height: 0.2)), effect: effect)]
            workspace.pages[0].drawings = [DrawingAnnotation(kind: .rectangle,
                points: [CGPoint(x: 0.6, y: 0.6), CGPoint(x: 0.8, y: 0.8)], lineWidth: 0.002)]
            let legacyURL = dir.appendingPathComponent("legacy-\(index).bluraction")
            let fixed = try MultiPageProjectFile.from(workspace, projectURL: legacyURL)
            #expect(fixed.pages[0].pdfGeometryVersion == 1)
            var legacy = fixed; legacy.pages[0].pdfGeometryVersion = nil
            let legacyBytes = try legacy.encoded(); try legacyBytes.write(to: legacyURL)
            let decodedLegacy = try MultiPageProjectFile.decode(Data(contentsOf: legacyURL))
            if item.affected {
                #expect(throws: PageWorkspace.WorkspaceError.legacyPDFEditsNeedReview) {
                    try decodedLegacy.workspace(relativeTo: legacyURL)
                }
                var drawingOnly = decodedLegacy; drawingOnly.pages[0].regions = []
                #expect(throws: PageWorkspace.WorkspaceError.legacyPDFEditsNeedReview) {
                    try drawingOnly.workspace(relativeTo: legacyURL)
                }
            } else {
                let restored = try decodedLegacy.workspace(relativeTo: legacyURL)
                #expect(restored.currentIndex == legacy.currentIndex)
                #expect(restored.pages[0].regions == legacy.pages[0].regions)
                #expect(restored.pages[0].drawings == legacy.pages[0].drawings)
            }
            var empty = legacy; empty.pages[0].regions = []; empty.pages[0].drawings = []
            #expect(try empty.workspace(relativeTo: legacyURL).pages[0].regions.isEmpty)
            let fixedRestored = try MultiPageProjectFile.decode(fixed.encoded()).workspace(relativeTo: legacyURL)
            #expect(fixedRestored.pages[0].regions == workspace.pages[0].regions)
            #expect(fixedRestored.pages[0].drawings == workspace.pages[0].drawings)
            let second = try MultiPageProjectFile.from(fixedRestored, projectURL: legacyURL)
            #expect(second.pages[0].pdfGeometryVersion == 1)
            #expect(try MultiPageProjectFile.decode(second.encoded()).workspace(relativeTo: legacyURL).pages.count == 1)
            #expect(try Data(contentsOf: legacyURL) == legacyBytes)
            #expect(try PageWorkspace.digest(of: source) == sourceHash)
            for version in [0, 2, -1] {
                var unknown = fixed; unknown.pages[0].pdfGeometryVersion = version
                #expect(throws: ProjectFile.ProjectError.invalidContent) { try MultiPageProjectFile.decode(unknown.encoded()) }
            }
        }
        let imageURL = dir.appendingPathComponent("image.png")
        try image(at: imageURL, color: NSColor.white.cgColor)
        var imageProject = try MultiPageProjectFile.from(PageWorkspace.open([imageURL]),
            projectURL: dir.appendingPathComponent("image.bluraction"))
        #expect(imageProject.pages[0].pdfGeometryVersion == nil)
        imageProject.pages[0].pdfGeometryVersion = 1
        #expect(throws: ProjectFile.ProjectError.invalidContent) { try MultiPageProjectFile.decode(imageProject.encoded()) }
    }

    @MainActor
    @Test
    func refusingAffectedLegacyPDFKeepsTheCurrentControllerWorkspace() throws {
        _ = NSApplication.shared
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("first.png"), second = dir.appendingPathComponent("second.png")
        try image(at: first, color: NSColor.white.cgColor); try image(at: second, color: NSColor.white.cgColor)
        var current = try PageWorkspace.open([first, second]); current.currentIndex = 1
        current.pages[1].regions = [ProjectFile.Region(
            shape: .rectangle(id: UUID(), origin: CGPoint(x: 0.2, y: 0.2), size: CGSize(width: 0.2, height: 0.2)), effect: .alwaysOn())]
        let currentURL = dir.appendingPathComponent("current.bluraction")
        let currentProject = try MultiPageProjectFile.from(current, projectURL: currentURL)
        let affectedSource = dir.appendingPathComponent("rotated.pdf")
        try geometryPDF(at: affectedSource, media: CGRect(x: 0, y: 0, width: 100, height: 160),
                        crop: CGRect(x: 0, y: 0, width: 100, height: 160), rotation: 90)
        var affected = try MultiPageProjectFile.from(PageWorkspace.open([affectedSource]),
            projectURL: dir.appendingPathComponent("affected.bluraction"))
        affected.pages[0].regions = current.pages[1].regions; affected.pages[0].pdfGeometryVersion = nil
        let controller = MainWindowController(); controller.showWindow(nil)
        defer { controller.close() }
        try controller.openWorkspaceProject(currentProject, relativeTo: currentURL)
        let container = try #require(controller.window?.contentViewController as? MainContainerViewController)
        #expect(container.pageLabel.stringValue == "2 / 2")
        #expect(throws: PageWorkspace.WorkspaceError.legacyPDFEditsNeedReview) {
            try controller.openWorkspaceProject(affected, relativeTo: dir.appendingPathComponent("affected.bluraction"))
        }
        #expect(container.pageLabel.stringValue == "2 / 2")
        #expect(container.canvas.regionsBinding?().map(\.id) == current.pages[1].regions.map { $0.shape.id })
        let savedURL = dir.appendingPathComponent("still-current.bluraction")
        try controller.saveWorkspaceProject(to: savedURL)
        let preserved = try MultiPageProjectFile.decode(Data(contentsOf: savedURL))
        #expect(preserved.title == current.title && preserved.currentIndex == 1 && preserved.pages.count == 2)
        #expect(preserved.pages.allSatisfy { $0.pdfPageIndex == nil && $0.pdfGeometryVersion == nil })
        #expect(preserved.pages[1].regions.map { $0.shape.id } == current.pages[1].regions.map { $0.shape.id })
    }

    private func geometryPDF(at url: URL, media: CGRect, crop: CGRect, rotation: Int) throws {
        var box = media
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPage(mediaBox: &box)
        context.setFillColor(NSColor.white.cgColor); context.fill(media)
        let squares = [
            CGRect(x: crop.minX + 3, y: crop.minY + 3, width: 10, height: 10),
            CGRect(x: crop.maxX - 13, y: crop.minY + 3, width: 10, height: 10),
            CGRect(x: crop.minX + 3, y: crop.maxY - 13, width: 10, height: 10),
            CGRect(x: crop.maxX - 13, y: crop.maxY - 13, width: 10, height: 10)
        ]
        let colors = [NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
                      NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1),
                      NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1),
                      NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)]
        for (square, color) in zip(squares, colors) {
            context.setFillColor(color.cgColor); context.fill(square)
        }
        context.endPage(); context.closePDF()
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        page.setBounds(crop, for: .cropBox); page.rotation = rotation
        let annotation = PDFAnnotation(bounds: CGRect(x: crop.midX - 6, y: crop.midY - 6, width: 12, height: 12),
                                       forType: .square, withProperties: nil)
        annotation.color = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        annotation.interiorColor = annotation.color
        page.addAnnotation(annotation)
        #expect(document.write(to: url))
    }

    private func expectPDFGeometryMarkers(_ image: CGImage, crop: CGRect, rotation: Int) throws {
        let positions = [CGPoint(x: 8, y: 8), CGPoint(x: crop.width - 8, y: 8),
                         CGPoint(x: 8, y: crop.height - 8), CGPoint(x: crop.width - 8, y: crop.height - 8),
                         CGPoint(x: crop.width / 2, y: crop.height / 2)]
        let colors = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 0, 255], [255, 0, 255, 255]]
        let displaySize = rotation % 180 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width)
        for (point, color) in zip(positions, colors) {
            let rotated: CGPoint
            switch rotation {
            case 90: rotated = CGPoint(x: point.y, y: crop.width - point.x)
            case 180: rotated = CGPoint(x: crop.width - point.x, y: crop.height - point.y)
            case 270: rotated = CGPoint(x: crop.height - point.y, y: point.x)
            default: rotated = point
            }
            expectPixel(image, normalized: CGPoint(x: rotated.x / displaySize.width, y: rotated.y / displaySize.height), equals: color)
        }
    }

    private func expectPixel(_ image: CGImage, normalized point: CGPoint, equals expected: [Int]) {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { data in
            CIContext().render(CIImage(cgImage: image), toBitmap: data.baseAddress!, rowBytes: 4,
                               bounds: CGRect(x: floor(point.x * CGFloat(image.width)), y: floor(point.y * CGFloat(image.height)), width: 1, height: 1),
                               format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        #expect(zip(bytes.map(Int.init), expected).allSatisfy { abs($0 - $1) <= 2 })
    }

    @MainActor
    @Test
    func switchingPagesKeepsEachPagesEditsAndUndoHistory() throws {
        _ = NSApplication.shared
        let dir = try directory()
        let first = dir.appendingPathComponent("a.png")
        let second = dir.appendingPathComponent("b.png")
        try image(at: first, color: .init(red: 1, green: 1, blue: 1, alpha: 1))
        try image(at: second, color: .init(red: 1, green: 1, blue: 1, alpha: 1))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(pasteboard.writeObjects([first as NSURL, second as NSURL]))
        #expect(VideoCanvasView.supportedDroppedURLs(from: pasteboard)?.count == 2)
        let controller = MainWindowController()
        controller.showWindow(nil)
        defer { controller.close() }
        controller.load(urls: [first, second])
        let container = try #require(controller.window?.contentViewController as? MainContainerViewController)
        #expect(container.pageLabel.stringValue == "1 / 2")
        #expect(container.canvas.regionsBinding?().count == 0)
        controller.perform(NSSelectorFromString("addRegionTapped"))
        #expect(container.canvas.regionsBinding?().count == 1)
        container.nextPageButton.performClick(nil)
        #expect(container.pageLabel.stringValue == "2 / 2")
        #expect(container.canvas.regionsBinding?().count == 0)
        container.previousPageButton.performClick(nil)
        #expect(container.canvas.regionsBinding?().count == 1)
        controller.perform(NSSelectorFromString("undoTapped"))
        #expect(container.canvas.regionsBinding?().count == 0)
        controller.perform(NSSelectorFromString("addRegionTapped"))
        controller.applyCurrentPageToAll()
        container.nextPageButton.performClick(nil)
        #expect(container.canvas.regionsBinding?().count == 1)
        controller.perform(NSSelectorFromString("addRegionTapped"))
        #expect(container.canvas.regionsBinding?().count == 2)
        container.previousPageButton.performClick(nil)
        #expect(container.canvas.regionsBinding?().count == 1)
    }

    @MainActor
    @Test
    func windowControlsNavigatePDFAndMultipleImages() throws {
        _ = NSApplication.shared
        let dir = try directory()
        let pdfURL = dir.appendingPathComponent("visual-pages.pdf")
        var media = CGRect(x: 0, y: 0, width: 600, height: 800)
        let pdf = try #require(CGContext(pdfURL as CFURL, mediaBox: &media, nil))
        for index in 1...3 {
            pdf.beginPage(mediaBox: &media)
            pdf.setFillColor(NSColor.white.cgColor)
            pdf.fill(media)
            pdf.setFillColor(NSColor.systemRed.cgColor)
            pdf.fill(CGRect(x: 100, y: 570, width: 180, height: 90))
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: "SYNTHETIC PDF PAGE \(index)", attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String):
                        CTFontCreateWithName("Helvetica" as CFString, 24, nil)
                ]))
            pdf.textPosition = CGPoint(x: 60, y: 680)
            CTLineDraw(line, pdf)
            pdf.endPage()
        }
        pdf.closePDF()
        let images = (1...3).map { dir.appendingPathComponent("visual-\($0).png") }
        for (index, url) in images.enumerated() {
            try image(at: url, color: CGColor(red: CGFloat(index) / 4,
                                              green: 0.7, blue: 0.9, alpha: 1))
        }

        let controller = MainWindowController()
        controller.showWindow(nil)
        defer { controller.close() }
        let container = try #require(controller.window?.contentViewController as? MainContainerViewController)
        controller.load(urls: [pdfURL])
        #expect(container.pageLabel.stringValue == "1 / 3")
        let pdfWindowSize = try #require(controller.window?.contentView?.bounds.size)
        controller.perform(NSSelectorFromString("addRegionTapped"))
        container.nextPageButton.performClick(nil)
        #expect(container.pageLabel.stringValue == "2 / 3")
        #expect(controller.window?.contentView?.bounds.size == pdfWindowSize)
        #expect(container.canvas.regionsBinding?().isEmpty == true)
        container.previousPageButton.performClick(nil)
        controller.applyCurrentPageToAll()
        container.nextPageButton.performClick(nil)
        #expect(container.canvas.regionsBinding?().count == 1)
        controller.perform(NSSelectorFromString("addRegionTapped"))
        #expect(container.canvas.regionsBinding?().count == 2)
        captureWindow(controller.window, name: "pdf-page-two")
        container.nextPageButton.performClick(nil)
        #expect(container.canvas.regionsBinding?().count == 1)
        let pdfProjectURL = dir.appendingPathComponent("pdf-session.bluraction")
        try controller.saveWorkspaceProject(to: pdfProjectURL)
        #expect(throws: (any Error).self) { try controller.saveWorkspaceProject(to: pdfProjectURL) }
        let reopenedPDFProject = try MultiPageProjectFile.decode(Data(contentsOf: pdfProjectURL))
        let reopenedController = MainWindowController()
        reopenedController.showWindow(nil)
        defer { reopenedController.close() }
        try reopenedController.openWorkspaceProject(reopenedPDFProject, relativeTo: pdfProjectURL)
        let reopenedContainer = try #require(reopenedController.window?.contentViewController as? MainContainerViewController)
        #expect(reopenedContainer.pageLabel.stringValue == "3 / 3")
        #expect(reopenedContainer.canvas.regionsBinding?().count == 1)
        reopenedContainer.previousPageButton.performClick(nil)
        #expect(reopenedContainer.canvas.regionsBinding?().count == 2)
        let pdfResult = dir.appendingPathComponent("pdf-result.pdf")
        try reopenedPDFProject.workspace(relativeTo: pdfProjectURL).exportPDF(to: pdfResult)
        #expect(PDFDocument(url: pdfResult)?.pageCount == 3)

        controller.load(urls: images)
        #expect(container.pageLabel.stringValue == "1 / 3")
        let imageWindowSize = try #require(controller.window?.contentView?.bounds.size)
        #expect(imageWindowSize.height >= min(760, (NSScreen.main?.visibleFrame.height ?? 760) - 80))
        controller.perform(NSSelectorFromString("addRegionTapped"))
        controller.applyCurrentPageToAll()
        container.nextPageButton.performClick(nil)
        #expect(container.canvas.regionsBinding?().count == 1)
        #expect(controller.window?.contentView?.bounds.size == imageWindowSize)
        captureWindow(controller.window, name: "image-page-two")
        let imageProjectURL = dir.appendingPathComponent("image-session.bluraction")
        try controller.saveWorkspaceProject(to: imageProjectURL)
        let reopenedImageProject = try MultiPageProjectFile.decode(Data(contentsOf: imageProjectURL))
        try reopenedController.openWorkspaceProject(reopenedImageProject, relativeTo: imageProjectURL)
        #expect(reopenedContainer.pageLabel.stringValue == "2 / 3")
        #expect(reopenedContainer.canvas.regionsBinding?().count == 1)
        let imageWorkspace = try reopenedImageProject.workspace(relativeTo: imageProjectURL)
        let imageResult = dir.appendingPathComponent("image-result.pdf")
        try imageWorkspace.exportPDF(to: imageResult)
        #expect(PDFDocument(url: imageResult)?.pageCount == 3)
        let imageFolder = try #require(try imageWorkspace.exportImageFiles(near: imageResult))
        #expect(try FileManager.default.contentsOfDirectory(atPath: imageFolder.path).count == 3)
    }

    @MainActor
    private func captureWindow(_ window: NSWindow?, name: String) {
        guard let destination = ProcessInfo.processInfo.environment["BLURACTION_GUI_CAPTURE_DIR"],
              let view = window?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.displayIfNeeded()
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        let output = URL(fileURLWithPath: destination, isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString).png")
        try? data.write(to: output)
    }
}
