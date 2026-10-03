import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import PDFKit

/// Public synthetic PDFs only. Does not load product code or existing media.
/// The parent compiles/runs this in its serial verification slot.
@main
struct GeneratePDFGeometry {
    struct Fixture {
        let family: String
        let media: CGRect
        let crop: CGRect
        let rotation: Int
        var name: String { "\(family)-r\(rotation)" }
        var displaySize: CGSize {
            rotation % 180 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width)
        }
        var macLegacyEditedRequiresReview: Bool {
            abs(crop.minX) > 1e-6 || abs(crop.minY) > 1e-6 ||
            abs(crop.width - displaySize.width) > 1e-6 || abs(crop.height - displaySize.height) > 1e-6
        }
    }

    enum Failure: Error {
        case usage, destinationExists, pdfCreation, pdfReopen, pdfWrite
    }

    static func box(_ rect: CGRect) -> [Double] {
        [rect.minX, rect.minY, rect.width, rect.height].map(Double.init)
    }

    static func display(_ point: CGPoint, fixture: Fixture) -> CGPoint {
        // Crop-relative, bottom-left coordinates. Matches the independently
        // checked Mac PageWorkspaceTests, not a decoder-derived expectation.
        switch fixture.rotation {
        case 90: return CGPoint(x: point.y, y: fixture.crop.width - point.x)
        case 180: return CGPoint(x: fixture.crop.width - point.x, y: fixture.crop.height - point.y)
        case 270: return CGPoint(x: fixture.crop.height - point.y, y: point.x)
        default: return point
        }
    }

    static func marker(_ name: String, point: CGPoint, rgb: [Int], fixture: Fixture) -> [String: Any] {
        let shown = display(point, fixture: fixture)
        return ["name": name, "cropPoint": [Double(point.x), Double(point.y)],
                "displayPoint": [Double(shown.x), Double(shown.y)], "rgb": rgb]
    }

    static func generate(_ fixture: Fixture, at url: URL) throws -> [String: Any] {
        // The enclosing fresh directory is owned by this invocation. PDFKit
        // finalizes only the newly created synthetic file, never an input PDF.
        var media = fixture.media
        guard let context = CGContext(url as CFURL, mediaBox: &media, nil) else { throw Failure.pdfCreation }
        context.beginPage(mediaBox: &media)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(media)
        let crop = fixture.crop
        let gray = NSColor(srgbRed: 90.0 / 255.0, green: 90.0 / 255.0, blue: 90.0 / 255.0, alpha: 1)
        context.setStrokeColor(gray.cgColor)
        context.setLineWidth(2)
        context.stroke(crop.insetBy(dx: 1, dy: 1))
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
            context.setFillColor(color.cgColor)
            context.fill(square)
        }
        context.endPage()
        context.closePDF()
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { throw Failure.pdfReopen }
        page.setBounds(crop, for: .cropBox)
        page.rotation = fixture.rotation
        let annotation = PDFAnnotation(bounds: CGRect(x: crop.midX - 6, y: crop.midY - 6, width: 12, height: 12),
                                       forType: .square, withProperties: nil)
        annotation.color = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        annotation.interiorColor = annotation.color
        page.addAnnotation(annotation)
        guard document.write(to: url) else { throw Failure.pdfWrite }
        let points = [CGPoint(x: 8, y: 8), CGPoint(x: crop.width - 8, y: 8),
                      CGPoint(x: 8, y: crop.height - 8), CGPoint(x: crop.width - 8, y: crop.height - 8)]
        let names = ["source-bottom-left", "source-bottom-right", "source-top-left", "source-top-right"]
        let rgb = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0]]
        let markers = (0..<4).map { marker(names[$0], point: points[$0], rgb: rgb[$0], fixture: fixture) }
        let borders = [CGPoint(x: crop.width / 2, y: 1), CGPoint(x: crop.width / 2, y: crop.height - 1),
                       CGPoint(x: 1, y: crop.height / 2), CGPoint(x: crop.width - 1, y: crop.height / 2)]
        let bytes = try Data(contentsOf: url)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return ["id": fixture.name, "file": url.lastPathComponent, "rotation": fixture.rotation,
                "mediaBox": box(media), "cropBox": box(crop),
                "displayPointSize": [Double(fixture.displaySize.width), Double(fixture.displaySize.height)],
                "expectedPixelSize144dpi": [Int(fixture.displaySize.width * 2), Int(fixture.displaySize.height * 2)],
                "sourceSHA256": digest, "corners": markers,
                "annotation": marker("pdf-square-annotation", point: CGPoint(x: crop.width / 2, y: crop.height / 2),
                                     rgb: [255, 0, 255], fixture: fixture),
                "borders": borders.enumerated().map { marker("crop-border-\($0.offset)", point: $0.element, rgb: [90, 90, 90], fixture: fixture) },
                "macLegacyEditedRequiresReview": fixture.macLegacyEditedRequiresReview,
                "portableCurrentLegacyEditedRequiresReview": true]
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw Failure.usage }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw Failure.destinationExists }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let definitions = [
            ("zero", CGRect(x: 0, y: 0, width: 100, height: 160), CGRect(x: 0, y: 0, width: 100, height: 160)),
            ("inset", CGRect(x: 0, y: 0, width: 120, height: 180), CGRect(x: 10, y: 20, width: 100, height: 140)),
            ("nonzero", CGRect(x: 30, y: 40, width: 120, height: 180), CGRect(x: 40, y: 60, width: 100, height: 140))
        ]
        var cases = [[String: Any]]()
        for (family, media, crop) in definitions {
            for rotation in [0, 90, 180, 270] {
                let fixture = Fixture(family: family, media: media, crop: crop, rotation: rotation)
                cases.append(try generate(fixture, at: folder.appendingPathComponent(fixture.name + ".pdf")))
            }
        }
        let manifest: [String: Any] = ["schemaVersion": 1, "generator": "BlurAction public synthetic PDF geometry fixtures",
            "coordinateSystem": "crop-relative displayed points, bottom-left origin; image sampling must invert Y",
            "renderDpi": 144, "cases": cases,
            "legacyPolicyNote": "Mac allows unchanged legacy geometry, including zero-origin rotation 0/180. The current portable loader conservatively blocks every edited legacy PDF pending host geometry review. This fixture suite records that limitation, not full legacy parity."]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
        print("Generated \(cases.count) public synthetic PDFs and manifest: \(folder.path)")
    }
}
