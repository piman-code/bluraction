import AppKit
import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import BlurAction

/// Reverse cover: the shape stays visible and everything else in the frame is covered.
@Suite(.serialized)
struct ReverseCoverTests {
    /// 64×32 image: red left half, blue right half.
    private func splitImage() throws -> CIImage {
        let context = try #require(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); context.fill(CGRect(x: 32, y: 0, width: 32, height: 32))
        return CIImage(cgImage: try #require(context.makeImage()))
    }

    /// RGB of one pixel (x from the left, y from the bottom, like the canvas).
    private func pixel(_ image: CIImage, x: Int, y: Int) throws -> (Int, Int, Int) {
        let cg = try #require(CIContext().createCGImage(image, from: image.extent))
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: -x, y: -(cg.height - 1 - y), width: cg.width, height: cg.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    private func solidEffect(inverted: Bool) -> RegionEffect {
        var effect = RegionEffect(blurRadius: 0, featherRadius: 0)
        effect.style = .solid
        effect.color = RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)
        effect.inverted = inverted
        return effect
    }

    @Test
    func reverseCoverKeepsTheShapeAndCoversEverythingElse() throws {
        let image = try splitImage()
        // Keep the left half (red); the blue half must be covered.
        let keep = RegionShape.rectangle(id: UUID(), origin: .zero, size: CGSize(width: 32, height: 32))
        let out = try BlurRenderer.render(image: image, pairs: [(keep, solidEffect(inverted: true))],
                                          canvasSize: CGSize(width: 64, height: 32), time: nil)
        let kept = try pixel(out, x: 8, y: 16), covered = try pixel(out, x: 52, y: 16)
        #expect(kept.0 > 200 && kept.2 < 40, "The kept half keeps its picture: \(kept)")
        #expect(covered.0 < 20 && covered.1 < 20 && covered.2 < 20, "Everything outside is covered: \(covered)")
    }

    @Test
    func ordinaryCoverIsUnchangedAndStillCoversItsShape() throws {
        let image = try splitImage()
        let shape = RegionShape.rectangle(id: UUID(), origin: .zero, size: CGSize(width: 32, height: 32))
        let out = try BlurRenderer.render(image: image, pairs: [(shape, solidEffect(inverted: false))],
                                          canvasSize: CGSize(width: 64, height: 32), time: nil)
        let covered = try pixel(out, x: 8, y: 16), kept = try pixel(out, x: 52, y: 16)
        #expect(covered.0 < 20 && covered.2 < 20)
        #expect(kept.2 > 200)
    }

    @Test
    func reverseCoverWithRubbedOutPartsIsRefused() throws {
        var effect = solidEffect(inverted: true)
        effect.erasures = [EraseStroke(points: [.init(x: 4, y: 4), .init(x: 8, y: 8)], width: 2, from: nil)]
        let shape = RegionShape.rectangle(id: UUID(), origin: .zero, size: CGSize(width: 32, height: 32))
        #expect(throws: BlurRenderer.RenderError.invalidEffect) {
            try BlurRenderer.render(image: try splitImage(), pairs: [(shape, effect)],
                                    canvasSize: CGSize(width: 64, height: 32), time: nil)
        }
    }

    @Test
    func theFlagIsWrittenOnlyWhenSet() throws {
        let plain = try JSONEncoder().encode(solidEffect(inverted: false))
        #expect(!String(decoding: plain, as: UTF8.self).contains("inverted"), "Ordinary effects keep their old bytes")
        let reverse = try JSONEncoder().encode(solidEffect(inverted: true))
        #expect(String(decoding: reverse, as: UTF8.self).contains("\"inverted\":true"))
        #expect(try JSONDecoder().decode(RegionEffect.self, from: reverse).inverted)
        #expect(try !JSONDecoder().decode(RegionEffect.self, from: plain).inverted)
    }

    @Test
    func imageProjectsRefuseAReverseCover() throws {
        let shape = RegionShape.rectangle(id: UUID(), origin: .zero, size: CGSize(width: 0.5, height: 0.5))
        let project = ProjectFile(mediaPath: "photo.png", regions: [.init(shape: shape, effect: solidEffect(inverted: true))], drawings: [])
        let data = try project.encoded()
        #expect(throws: ProjectFile.ProjectError.unsupportedVersion) { try ProjectFile.decode(data) }
        #expect(try ProjectFile.decode(data, allowsReverse: true).regions.count == 1)
    }

    @MainActor
    @Test
    func videoProjectsUseVersionFourOnlyForReverseCovers() async throws {
        let directory = try VideoExportTests().directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("reverse.mp4")
        try VideoExportTests().ffmpeg(["-f", "lavfi", "-i", "color=c=red:size=160x120:rate=10:duration=1",
                                       "-c:v", "libx264", "-pix_fmt", "yuv420p", source.path])
        let binding = try await VideoProjectSourceBinding.observe(url: source)
        let shape = RegionShape.rectangle(id: UUID(), origin: .init(x: 0.1, y: 0.1), size: CGSize(width: 0.5, height: 0.5))

        // Ordinary projects keep format 3, so older apps and the Windows reader still open them.
        let ordinary = try VideoProjectFile.make(mediaPath: source.lastPathComponent, binding: binding, producerVersion: "test.reverse",
            regions: [.init(shape: shape, effect: solidEffect(inverted: false))], drawings: [])
        #expect(ordinary.payload.version == 3)
        #expect(!String(decoding: try ordinary.encoded(), as: UTF8.self).contains("inverted"))

        let reverse = try VideoProjectFile.make(mediaPath: source.lastPathComponent, binding: binding, producerVersion: "test.reverse",
            regions: [.init(shape: shape, effect: solidEffect(inverted: true))], drawings: [])
        #expect(reverse.payload.version == 4)
        #expect(try VideoProjectFile.decode(reverse.encoded()).payload.regions.first?.effect.inverted == true)

        // A version 4 label without a reverse cover, or a reverse cover labelled version 3, is refused.
        let text = String(decoding: try reverse.encoded(), as: UTF8.self)
        let relabelled = Data(text.replacingOccurrences(of: #""version" : 4"#, with: #""version" : 3"#)
            .replacingOccurrences(of: #""version":4"#, with: #""version":3"#).utf8)
        #expect(throws: ProjectFile.ProjectError.self) { try VideoProjectFile.decode(relabelled) }
    }

    @MainActor
    @Test
    func theEditorTurnsAVideoCoverIntoAReverseCoverAndSavesVersionFour() async throws {
        let session = try await VideoSession.open()
        defer { session.close() }
        session.controller.perform(NSSelectorFromString("addRegionTapped"))
        let id = try #require(session.canvas.regionsBinding?().first?.id)
        session.controller.setLayerReversed(id, true)
        let saved = try session.controller.projectData(producerVersion: "test.reverse")
        #expect(try VideoProjectFile.decode(saved).payload.version == 4)
        #expect(try VideoProjectFile.decode(saved).payload.regions.first?.effect.inverted == true)
        // Turning it back off returns the ordinary format.
        session.controller.setLayerReversed(id, false)
        let plain = try session.controller.projectData(producerVersion: "test.reverse")
        #expect(try VideoProjectFile.decode(plain).payload.version == 3)
        #expect(!String(decoding: plain, as: UTF8.self).contains("inverted"))
    }
}
