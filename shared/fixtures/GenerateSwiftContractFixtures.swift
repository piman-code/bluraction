import AppKit
import Foundation

/// Generates JSON with the actual Mac Codable implementation; no media is opened.
/// Parent runs this in its serial compiler slot. Outputs are new files only.
@main
struct GenerateSwiftContractFixtures {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Expected fixture destination folder") }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let group = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        var effect = RegionEffect(blurRadius: 25, featherRadius: 12, timeRange: 2...5)
        effect.style = .solid; effect.color = RGBAColor(red: 0, green: 0.2, blue: 0.4, alpha: 0.8)
        effect.keyframes = [RegionKeyframe(time: 2, rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))]
        effect.erasures = [EraseStroke(points: [CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.4, y: 0.5)], width: 0.02, from: 3)]
        effect.groupID = group; effect.name = "가림"; effect.locked = true
        let shapes: [RegionShape] = [
            .rectangle(id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, origin: CGPoint(x: 0.1, y: 0.2), size: CGSize(width: 0.3, height: 0.4)),
            .ellipse(id: UUID(uuidString: "11111111-1111-4111-8111-111111111112")!, origin: CGPoint(x: 0.5, y: 0.2), size: CGSize(width: 0.2, height: 0.4)),
            .polygon(id: UUID(uuidString: "11111111-1111-4111-8111-111111111113")!, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.4, y: 0.1), CGPoint(x: 0.2, y: 0.4)])]
        let kinds: [DrawingAnnotation.Kind] = [.rectangle, .ellipse, .line, .freehand, .arrow, .text]
        let drawings = kinds.enumerated().map { index, kind -> DrawingAnnotation in
            var drawing = DrawingAnnotation(id: UUID(uuidString: String(format: "22222222-2222-4222-8222-%012d", index + 1))!,
                kind: kind, points: [CGPoint(x: 0.3, y: 0.4), CGPoint(x: 0.5, y: 0.6)],
                color: NSColor(srgbRed: 1, green: 0.4, blue: 0.3, alpha: 0.7), lineWidth: 0.01, fillOpacity: 0.35)
            drawing.timeRange = 1...5
            drawing.keyframes = [RegionKeyframe(time: 0, rect: CGRect(x: 0.2, y: 0.4, width: 0.1, height: 0.2))]
            drawing.text = "교사 검토\n합성 자료"; drawing.groupID = group
            drawing.erasures = [EraseStroke(points: [CGPoint(x: 0.3, y: 0.5)], width: 0.03, from: nil)]
            drawing.name = "그림"; drawing.hidden = true; drawing.locked = false
            drawing.fontName = "Helvetica"; drawing.bold = false
            drawing.textBackground = RGBAColor(red: 1, green: 1, blue: 1, alpha: 0.8)
            return drawing
        }
        let regions = shapes.map { ProjectFile.Region(shape: $0, effect: effect) }
        let v1 = ProjectFile(mediaPath: "synthetic.png", regions: regions, drawings: drawings)
        let v2 = MultiPageProjectFile(title: "합성 묶음", currentIndex: 1, pages: [
            .init(mediaPath: "synthetic.png", regions: regions, drawings: drawings),
            .init(mediaPath: "synthetic.pdf", pdfPageIndex: 0, sourceSHA256: String(repeating: "a", count: 64),
                  pdfGeometryVersion: 1, regions: regions, drawings: drawings)])
        for (name, data) in [("swift-v1-rich.bluraction", try v1.encoded()), ("swift-v2-rich.bluraction", try v2.encoded())] {
            let destination = folder.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: destination.path) else { fatalError("Refusing to replace fixture") }
            try data.write(to: destination, options: .withoutOverwriting)
            print(name)
        }
    }
}
