import AppKit
import CoreGraphics
import Foundation

/// A label belongs to its cover, so timing, motion, deletion and undo cannot drift apart.
/// Relative sizing also makes the label independent of canvas and export resolution.
struct CoverDecoration: Codable, Equatable {
    var text: String
    var scale: CGFloat = 0.8
    var color: RGBAColor = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)

    var isValid: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 1_000 &&
        !text.contains("\0") && scale.isFinite && (0.1...1).contains(scale) && color.isValid
    }

    /// Fit both dimensions with one scale, preserving emoji and letter proportions.
    func annotation(in rect: CGRect) -> DrawingAnnotation? {
        guard isValid, [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
              rect.width > 0, rect.height > 0 else { return nil }
        var drawing = DrawingAnnotation.text(text, at: .zero, fontSize: 100,
            color: NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha))
        let natural = drawing.bounds.size
        guard natural.width > 0, natural.height > 0 else { return nil }
        let ratio = min(rect.width / natural.width, rect.height / natural.height) * scale
        let size = CGSize(width: natural.width * ratio, height: natural.height * ratio)
        let box = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                         width: size.width, height: size.height)
        drawing.points = [box.origin, CGPoint(x: box.maxX, y: box.maxY)]
        return drawing
    }

    func render(in context: CGContext, rect: CGRect) {
        annotation(in: rect)?.render(in: context, time: nil)
    }

    private enum CodingKeys: String, CodingKey { case text, scale, color }
    init(text: String, scale: CGFloat = 0.8,
         color: RGBAColor = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)) {
        self.text = text; self.scale = scale; self.color = color
    }
    init(from decoder: Decoder) throws {
        try MacEditField.validate(decoder, allowed: ["text", "scale", "color"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        scale = try container.decode(CGFloat.self, forKey: .scale)
        color = try container.decode(RGBAColor.self, forKey: .color)
        guard isValid else { throw ProjectFile.ProjectError.invalidContent }
    }
}

/// New Mac fields are checked before projection, so future semantics cannot silently disappear.
enum MacEditField {
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    static func validate(_ decoder: Decoder, allowed: Set<String>) throws {
        let container = try decoder.container(keyedBy: Key.self)
        guard Set(container.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
            throw ProjectFile.ProjectError.unsupportedVersion
        }
    }
}
