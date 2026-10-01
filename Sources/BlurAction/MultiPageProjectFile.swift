import Foundation
import PDFKit

/// Version 2 of a .bluraction session. Version 1 remains the single-media format.
struct MultiPageProjectFile: Codable {
    struct Page: Codable {
        var mediaPath: String
        var pdfPageIndex: Int?
        var sourceSHA256: String?
        /// nil = legacy canvas geometry; 1 = rotated, crop-origin-relative PDF geometry.
        var pdfGeometryVersion: Int? = nil
        var regions: [ProjectFile.Region]
        var drawings: [DrawingAnnotation]
    }

    var version = 2
    var title: String
    var currentIndex: Int
    var pages: [Page]

    static let maximumBytes = 50 * 1024 * 1024
    /// Filesystem-valid source names and already-saved 251...255-character titles.
    static let maximumTitleLength = 255

    static func from(_ workspace: PageWorkspace, projectURL: URL) throws -> MultiPageProjectFile {
        try workspace.validateSourcesUnchanged()
        let pages = try workspace.pages.map { page throws -> Page in
            let index: Int?
            switch page.source { case .pdf(_, let value): index = value; case .image: index = nil }
            let sourceKey = page.source.url.standardizedFileURL
            guard let digest = workspace.sourceDigests[sourceKey] else {
                throw ProjectFile.ProjectError.invalidContent
            }
            return Page(mediaPath: ProjectFile.mediaReference(for: page.source.url, projectURL: projectURL),
                        pdfPageIndex: index, sourceSHA256: digest,
                        pdfGeometryVersion: index == nil ? nil : 1,
                        regions: page.regions, drawings: page.drawings)
        }
        return MultiPageProjectFile(title: workspace.title, currentIndex: workspace.currentIndex, pages: pages)
    }

    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw ProjectFile.ProjectError.tooLarge }
        return data
    }

    static func decode(_ data: Data) throws -> MultiPageProjectFile {
        guard data.count <= maximumBytes else { throw ProjectFile.ProjectError.tooLarge }
        guard let project = try? JSONDecoder().decode(Self.self, from: data) else {
            throw ProjectFile.ProjectError.invalidContent
        }
        try project.validate()
        return project
    }

    /// Encoding and decoding use the same contract so successful saves can reopen.
    private func validate() throws {
        guard version == 2,
              !title.isEmpty, title.count <= Self.maximumTitleLength,
              (1...PageWorkspace.maximumPages).contains(pages.count),
              pages.indices.contains(currentIndex) else {
            throw ProjectFile.ProjectError.invalidContent
        }
        for page in pages {
            guard !page.mediaPath.isEmpty, page.mediaPath.count <= 4096,
                  !page.mediaPath.contains("\0"),
                  page.pdfPageIndex.map({ (0..<PageWorkspace.maximumPages).contains($0) }) ?? true,
                  page.pdfGeometryVersion.map({ $0 == 1 && page.pdfPageIndex != nil }) ?? true,
                  page.sourceSHA256.map({ $0.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }) ?? true else {
                throw ProjectFile.ProjectError.invalidContent
            }
            let single = ProjectFile(mediaPath: page.mediaPath,
                                     regions: page.regions, drawings: page.drawings)
            _ = try ProjectFile.decode(single.encoded())
        }
    }

    func workspace(relativeTo projectURL: URL) throws -> PageWorkspace {
        var pdfCache: [URL: PDFDocument] = [:]
        var checkedSources: Set<URL> = []
        var sourceDigests: [URL: String] = [:]
        var sourceIdentities: [URL: URL] = [:]
        var totalBytes = 0
        let resolved = try pages.map { page -> PageWorkspace.Page in
            let reference = ProjectFile(mediaPath: page.mediaPath, regions: [], drawings: [])
            let url = reference.mediaURL(relativeTo: projectURL)
            guard url.isFileURL,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  FileManager.default.isReadableFile(atPath: url.path),
                  let bytes = values.fileSize, bytes > 0 else {
                throw PageWorkspace.WorkspaceError.invalidInput
            }
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            let sourceKey = url.standardizedFileURL
            if checkedSources.insert(canonical).inserted {
                guard bytes <= PageWorkspace.maximumSourceBytes,
                      totalBytes <= PageWorkspace.maximumSourceBytes - bytes else {
                    throw PageWorkspace.WorkspaceError.resourceLimit
                }
                totalBytes += bytes
            }
            if sourceDigests[sourceKey] == nil {
                sourceDigests[sourceKey] = try PageWorkspace.digest(of: url)
                sourceIdentities[sourceKey] = canonical
            }
            if let expected = page.sourceSHA256, sourceDigests[sourceKey] != expected {
                throw PageWorkspace.WorkspaceError.sourceChanged
            }
            let source: PageWorkspace.Source
            if let index = page.pdfPageIndex {
                guard url.pathExtension.lowercased() == "pdf" else {
                    throw ProjectFile.ProjectError.invalidContent
                }
                guard bytes <= PageWorkspace.maximumPDFBytes else {
                    throw PageWorkspace.WorkspaceError.resourceLimit
                }
                if pdfCache[canonical] == nil { pdfCache[canonical] = PDFDocument(url: url) }
                guard let pdf = pdfCache[canonical], !pdf.isLocked,
                      index < pdf.pageCount else { throw PageWorkspace.WorkspaceError.unreadablePDF }
                if page.pdfGeometryVersion == nil,
                   !page.regions.isEmpty || !page.drawings.isEmpty,
                   let pdfPage = pdf.page(at: index),
                   PageWorkspace.legacyPDFEditGeometryChanged(pdfPage) {
                    throw PageWorkspace.WorkspaceError.legacyPDFEditsNeedReview
                }
                source = .pdf(url, index)
            } else {
                guard bytes <= PageWorkspace.maximumImageBytes else {
                    throw PageWorkspace.WorkspaceError.resourceLimit
                }
                guard DocumentModel.isImage(url: url) else {
                    throw ProjectFile.ProjectError.invalidContent
                }
                source = .image(url)
            }
            return PageWorkspace.Page(source: source, regions: page.regions, drawings: page.drawings)
        }
        let workspace = PageWorkspace(pages: resolved, currentIndex: currentIndex, title: title,
                                      sourceDigests: sourceDigests, sourceIdentities: sourceIdentities)
        try workspace.validateSourcesUnchanged()
        _ = try workspace.image(at: currentIndex)
        return workspace
    }
}
