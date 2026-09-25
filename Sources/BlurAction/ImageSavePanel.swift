import AppKit
import UniformTypeIdentifiers

@MainActor
enum ImageSavePanel {
    static func make(original: URL, type: UTType) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.title = "블러 이미지 저장"
        panel.allowedContentTypes = [type]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        let directory = original.deletingLastPathComponent()
        panel.directoryURL = directory
        panel.nameFieldStringValue = suggestedURL(original: original, type: type).lastPathComponent
        return panel
    }

    static func suggestedURL(original: URL, type: UTType) -> URL {
        let directory = original.deletingLastPathComponent()
        let ext = type.preferredFilenameExtension ?? "png"
        let stem = original.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping
        var filename = filename(stem: stem, extension: ext)
        var suffix = 1
        while (try? directory.appendingPathComponent(filename).resourceValues(forKeys: [.isSymbolicLinkKey])) != nil {
            filename = self.filename(stem: stem, extension: ext, collision: suffix)
            suffix += 1
        }
        return directory.appendingPathComponent(filename)
    }

    /// Reserve room for the suffix and extension before truncating at a grapheme boundary.
    /// Check both Unicode representations because Finder can supply decomposed Korean names.
    static func filename(stem: String, extension ext: String, collision: Int = 0) -> String {
        let ending = "_blurred" + (collision == 0 ? "" : "(\(collision))") + "." + ext
        let normalized = stem.precomposedStringWithCanonicalMapping
        var prefix = ""
        for character in normalized {
            let candidate = prefix + String(character) + ending
            guard candidate.utf8.count <= 255,
                  candidate.decomposedStringWithCanonicalMapping.utf8.count <= 255 else { break }
            prefix.append(character)
        }
        if prefix.isEmpty { prefix = "Image" }
        return prefix + ending
    }
}
