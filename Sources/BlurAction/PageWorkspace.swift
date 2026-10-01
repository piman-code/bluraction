import AppKit
import CoreImage
import ImageIO
import PDFKit
import Darwin
import CryptoKit

/// A PDF or an ordered set of images, with independent normalized edits per page.
/// Source files are referenced and never modified.
struct PageWorkspace {
    enum Source {
        case pdf(URL, Int)
        case image(URL)

        var url: URL {
            switch self { case .pdf(let url, _), .image(let url): return url }
        }
    }

    struct Page {
        var source: Source
        var regions: [ProjectFile.Region] = []
        var drawings: [DrawingAnnotation] = []
        var undo: [Edit] = []
        var redo: [Edit] = []
    }

    struct Edit {
        var regions: [ProjectFile.Region]
        var drawings: [DrawingAnnotation]
    }

    enum WorkspaceError: LocalizedError {
        case invalidInput, tooManyPages, unreadablePDF, oversizedPage, exportFailed, destinationExists, cancelled, resourceLimit, sourceChanged, legacyPDFEditsNeedReview

        var errorDescription: String? {
            switch self {
            case .invalidInput: return "PDF 또는 읽을 수 있는 이미지 파일을 선택하세요."
            case .tooManyPages: return "한 번에 열 수 있는 페이지는 최대 200장입니다."
            case .unreadablePDF: return "PDF를 읽을 수 없습니다. 암호화되었거나 손상되었는지 확인하세요."
            case .oversizedPage: return "페이지가 너무 큽니다. 렌더링 한도는 24MP입니다."
            case .exportFailed: return "문서 내보내기에 실패했습니다. 원본은 변경되지 않았습니다."
            case .destinationExists: return "원본이나 기존 파일을 덮어쓸 수 없습니다. 새 이름을 선택하세요."
            case .cancelled: return "문서 내보내기를 취소했습니다."
            case .resourceLimit: return "문서가 처리 한도를 넘습니다. 입력은 PDF당 512MB, 이미지당 128MB, 출력은 총 5억 화소 이하여야 합니다."
            case .sourceChanged: return "원본 파일이 작업 중 변경됐습니다. 파일을 다시 열고 각 페이지의 가림 위치를 확인하세요."
            case .legacyPDFEditsNeedReview: return "이전 버전에서 저장한 PDF의 가림 위치를 다시 확인해야 합니다. 페이지 원점 또는 회전 처리 방식이 바뀌었습니다. 원본 PDF를 새로 열어 가림과 그림을 확인한 뒤 새 프로젝트로 저장하세요. 기존 프로젝트와 원본은 변경되지 않았습니다."
            }
        }
    }

    var pages: [Page]
    var currentIndex = 0
    var title: String
    var sourceDigests: [URL: String] = [:]
    var sourceIdentities: [URL: URL] = [:]
    static let maximumPages = 200
    static let maximumPDFBytes = 512 * 1024 * 1024
    static let maximumImageBytes = 128 * 1024 * 1024
    static let maximumSourceBytes = 1024 * 1024 * 1024
    static let maximumExportPixels = 500_000_000
    static let maximumOutputBytes = 1024 * 1024 * 1024

    static func open(_ urls: [URL]) throws -> PageWorkspace {
        guard !urls.isEmpty, urls.count <= maximumPages else { throw WorkspaceError.tooManyPages }
        var pages: [Page] = []
        var sourceDigests: [URL: String] = [:]
        var sourceIdentities: [URL: URL] = [:]
        var sourceBytes = 0
        for url in urls {
            guard url.isFileURL,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  FileManager.default.isReadableFile(atPath: url.path),
                  let bytes = values.fileSize, bytes > 0 else { throw WorkspaceError.invalidInput }
            let sourceKey = url.standardizedFileURL
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            if url.pathExtension.lowercased() == "pdf" {
                guard bytes <= maximumPDFBytes else { throw WorkspaceError.resourceLimit }
                guard sourceBytes <= maximumSourceBytes - bytes else { throw WorkspaceError.resourceLimit }
                sourceBytes += bytes
                if sourceDigests[sourceKey] == nil {
                    sourceDigests[sourceKey] = try Self.digest(of: url)
                    sourceIdentities[sourceKey] = canonical
                }
                guard let document = PDFDocument(url: url), !document.isLocked,
                      document.pageCount > 0 else { throw WorkspaceError.unreadablePDF }
                guard pages.count + document.pageCount <= maximumPages else { throw WorkspaceError.tooManyPages }
                for index in 0..<document.pageCount { pages.append(Page(source: .pdf(url, index))) }
            } else if DocumentModel.isImage(url: url) {
                guard pages.count < maximumPages else { throw WorkspaceError.tooManyPages }
                guard bytes <= maximumImageBytes else { throw WorkspaceError.resourceLimit }
                guard sourceBytes <= maximumSourceBytes - bytes else { throw WorkspaceError.resourceLimit }
                sourceBytes += bytes
                if sourceDigests[sourceKey] == nil {
                    sourceDigests[sourceKey] = try Self.digest(of: url)
                    sourceIdentities[sourceKey] = canonical
                }
                pages.append(Page(source: .image(url)))
            } else { throw WorkspaceError.invalidInput }
        }
        let workspace = PageWorkspace(pages: pages,
                                      title: urls.count == 1
                                          ? String(urls[0].lastPathComponent.prefix(MultiPageProjectFile.maximumTitleLength))
                                          : "이미지 \(urls.count)장",
                                      sourceDigests: sourceDigests, sourceIdentities: sourceIdentities)
        try workspace.validateSourcesUnchanged()
        return workspace
    }

    static func digest(of url: URL) throws -> String {
        var status = stat()
        guard lstat(url.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
            throw WorkspaceError.sourceChanged
        }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch { throw WorkspaceError.sourceChanged }
    }

    func validateSourcesUnchanged() throws {
        for (url, expected) in sourceDigests {
            guard sourceIdentities[url] == url.resolvingSymlinksInPath().standardizedFileURL else {
                throw WorkspaceError.sourceChanged
            }
            guard try Self.digest(of: url) == expected else { throw WorkspaceError.sourceChanged }
        }
    }

    func image(at index: Int) throws -> CGImage {
        var cache: [URL: PDFDocument] = [:]
        return try image(at: index, pdfCache: &cache)
    }

    private func image(at index: Int, pdfCache: inout [URL: PDFDocument]) throws -> CGImage {
        guard pages.indices.contains(index) else { throw WorkspaceError.invalidInput }
        switch pages[index].source {
        case .image(let url): return try DocumentModel.decodeImage(url: url)
        case .pdf(let url, let pageIndex):
            if pdfCache[url] == nil { pdfCache[url] = PDFDocument(url: url) }
            guard let document = pdfCache[url], !document.isLocked,
                  let page = document.page(at: pageIndex) else { throw WorkspaceError.unreadablePDF }
            let bounds = Self.displayedPDFBounds(page)
            guard bounds.width.isFinite, bounds.height.isFinite,
                  bounds.width > 0, bounds.height > 0,
                  bounds.width * bounds.height <= 24_000_000 else { throw WorkspaceError.oversizedPage }
            let scale = min(3, 16_384 / max(bounds.width, bounds.height),
                            sqrt(24_000_000 / (bounds.width * bounds.height)))
            let width = Int(floor(bounds.width * scale))
            let height = Int(floor(bounds.height * scale))
            guard width > 0, height > 0 else { throw WorkspaceError.oversizedPage }
            try DocumentModel.validateImageDimensions(width: width, height: height)
            guard let color = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: 0, space: color,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw WorkspaceError.unreadablePDF
            }
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
            // PDFKit draws the crop box at the context origin and applies /Rotate
            // itself, including PDF annotations. An extra crop-origin translation
            // would shift the page twice and clip its edges.
            page.draw(with: .cropBox, to: context)
            guard let image = context.makeImage() else { throw WorkspaceError.unreadablePDF }
            return image
        }
    }

    /// PDF box bounds are unrotated. PDFKit's display transform maps the selected
    /// crop to an origin-relative, rotated rectangle, matching PDFPage.draw.
    private static func displayedPDFBounds(_ page: PDFPage) -> CGRect {
        page.bounds(for: .cropBox).applying(page.transform(for: .cropBox))
    }

    /// Old sessions normalized edits against an unrotated bitmap and applied the
    /// crop origin twice. Only refuse edited legacy pages whose canvas changes;
    /// ordinary pages, 180° pages and square 90° pages retain the same mapping.
    static func legacyPDFEditGeometryChanged(_ page: PDFPage) -> Bool {
        let crop = page.bounds(for: .cropBox)
        let displayed = displayedPDFBounds(page)
        let epsilon: CGFloat = 0.000001
        return abs(crop.minX) > epsilon || abs(crop.minY) > epsilon ||
            abs(crop.width - displayed.width) > epsilon ||
            abs(crop.height - displayed.height) > epsilon
    }

    private func outputPageSize(at index: Int, image: CGImage,
                                pdfCache: [URL: PDFDocument]) -> CGSize {
        if case .pdf(let url, let pageIndex) = pages[index].source,
           let page = pdfCache[url]?.page(at: pageIndex) {
            return Self.displayedPDFBounds(page).size
        }
        // Images become pages at 144 dpi while retaining their aspect ratio.
        return CGSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
    }

    func renderedImage(at index: Int, context: CIContext) throws -> CGImage {
        var cache: [URL: PDFDocument] = [:]
        return try renderedImage(at: index, context: context, pdfCache: &cache)
    }

    private func renderedImage(at index: Int, context: CIContext,
                               pdfCache: inout [URL: PDFDocument]) throws -> CGImage {
        let source = try image(at: index, pdfCache: &pdfCache)
        let size = CGSize(width: source.width, height: source.height)
        let pairs = RegionEditing.scaled(pages[index].regions.map { ($0.shape, $0.effect) },
                                         from: CGSize(width: 1, height: 1), to: size)
        let drawings = pages[index].drawings.map { $0.scaled(from: CGSize(width: 1, height: 1), to: size) }
        let rendered = try BlurRenderer.render(image: CIImage(cgImage: source), pairs: pairs,
                                               canvasSize: size, time: nil, annotations: drawings)
        guard let result = context.createCGImage(rendered, from: rendered.extent) else {
            throw WorkspaceError.exportFailed
        }
        return result
    }

    /// Rasterizing each page removes underlying PDF text and graphics that a visual blur
    /// would otherwise leave extractable in the output file.
    func exportPDF(to destination: URL, progress: ((Int, Int) -> Void)? = nil,
                   isCancelled: (() -> Bool)? = nil) throws {
        try validateSourcesUnchanged()
        guard destination.isFileURL, destination.pathExtension.lowercased() == "pdf" else {
            throw WorkspaceError.invalidInput
        }
        let output = destination.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(destination.lastPathComponent)
        var status = stat()
        guard lstat(output.path, &status) != 0 else { throw WorkspaceError.destinationExists }
        guard errno == ENOENT else { throw WorkspaceError.exportFailed }
        let sources = Set(pages.map { $0.source.url.resolvingSymlinksInPath().standardizedFileURL })
        guard !sources.contains(output.standardizedFileURL) else { throw WorkspaceError.destinationExists }

        var template = Array(output.deletingLastPathComponent()
            .appendingPathComponent(".blur-action-pdf-XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw WorkspaceError.exportFailed }
        close(descriptor)
        let temporary = URL(fileURLWithPath: String(cString: template))
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let consumer = CGDataConsumer(url: temporary as CFURL),
              let pdf = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw WorkspaceError.exportFailed
        }
        let context = CIContext()
        var pdfCache: [URL: PDFDocument] = [:]
        var totalPixels = 0
        do {
            for index in pages.indices {
                if isCancelled?() == true { throw WorkspaceError.cancelled }
                let image = try renderedImage(at: index, context: context, pdfCache: &pdfCache)
                totalPixels += image.width * image.height
                guard totalPixels <= Self.maximumExportPixels else { throw WorkspaceError.resourceLimit }
                let size = outputPageSize(at: index, image: image, pdfCache: pdfCache)
                var mediaBox = CGRect(origin: .zero, size: size)
                pdf.beginPage(mediaBox: &mediaBox)
                pdf.draw(image, in: mediaBox)
                pdf.endPage()
                pdf.flush()
                if let bytes = try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   bytes > Self.maximumOutputBytes { throw WorkspaceError.resourceLimit }
                progress?(index + 1, pages.count)
            }
            pdf.closePDF()
        } catch {
            pdf.closePDF()
            throw error
        }
        guard let bytes = try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              bytes <= Self.maximumOutputBytes else { throw WorkspaceError.resourceLimit }
        if isCancelled?() == true { throw WorkspaceError.cancelled }
        try validateSourcesUnchanged()
        guard renamex_np(temporary.path, output.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw WorkspaceError.destinationExists }
            throw WorkspaceError.exportFailed
        }
    }

    var hasImageSources: Bool {
        pages.contains { if case .image = $0.source { return true }; return false }
    }

    /// Creates a new sibling folder; every source image receives a separate lossless PNG.
    /// Existing files and folders are never reused or overwritten.
    func exportImageFiles(near pdfURL: URL, isCancelled: (() -> Bool)? = nil) throws -> URL? {
        guard hasImageSources else { return nil }
        try validateSourcesUnchanged()
        let parent = pdfURL.deletingLastPathComponent().resolvingSymlinksInPath()
        let stem = pdfURL.deletingPathExtension().lastPathComponent
        var folder: URL?
        for suffix in 0...999 {
            let ending = "_images" + (suffix == 0 ? "" : "(\(suffix))")
            let name = ImageSavePanel.boundedName(stem: stem, ending: ending)
            let candidate = parent.appendingPathComponent(name, isDirectory: true)
            var status = stat()
            if lstat(candidate.path, &status) == 0 { continue }
            let code = errno
            if code == ENOENT {
                folder = candidate
                break
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        guard let folder else { throw WorkspaceError.destinationExists }
        let staging = parent.appendingPathComponent(".blur-action-images-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        var totalPixels = 0
        var totalBytes = 0
        for index in pages.indices {
            if isCancelled?() == true { throw WorkspaceError.cancelled }
            guard case .image(let sourceURL) = pages[index].source else { continue }
            let source = try image(at: index)
            totalPixels += source.width * source.height
            guard totalPixels <= Self.maximumExportPixels else { throw WorkspaceError.resourceLimit }
            let size = CGSize(width: source.width, height: source.height)
            let pairs = RegionEditing.scaled(pages[index].regions.map { ($0.shape, $0.effect) },
                                             from: CGSize(width: 1, height: 1), to: size)
            let drawings = pages[index].drawings.map { $0.scaled(from: CGSize(width: 1, height: 1), to: size) }
            let number = String(format: "%03d", index + 1)
            let shortName = String(sourceURL.deletingPathExtension().lastPathComponent.prefix(80))
            let name = ImageSavePanel.boundedName(stem: "\(number)_\(shortName)", ending: "_blurred.png")
            let output = staging.appendingPathComponent(name)
            try BlurredImageExporter.export(source: source, pairs: pairs, canvasSize: size,
                                            inputURL: sourceURL, outputURL: output,
                                            type: .png, quality: 1, annotations: drawings)
            guard let bytes = try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  totalBytes <= Self.maximumOutputBytes - bytes else {
                throw WorkspaceError.resourceLimit
            }
            totalBytes += bytes
        }
        try validateSourcesUnchanged()
        guard renamex_np(staging.path, folder.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw WorkspaceError.destinationExists }
            throw WorkspaceError.exportFailed
        }
        return folder
    }
}
