import AppKit
import CryptoKit
import Foundation
import Testing
@testable import BlurAction

/// Deliberately outside verify_mac's *Tests.swift inventory. The separate
/// required three-stage driver rejects missing configuration/completion.
@Suite(.serialized)
@MainActor
struct VideoProjectCrossPlatformRoundTripTests {
    private let kinds = ["nonzero-origin", "video-negative-twelfth-audio-negative-quarter"]
    private let hashes = [
        "797a1f51c464b0ef5bce39f2a14114c16327100eb3cc8446af5050c130dc8acd",
        "386afa793fc353bba01ded7954490cbc2c08e9582e114f519fd47f361fc2ad79"]
    private let manifestSHA = "f1779cbc24d9f7a0451b182e028f587db1113f5f605ae80f22b6efa0d5a45f0f"
    private let editedName = "Windows에서 명시 변경"
    private struct Row: Codable {
        var kind: String
        var sourceSHA256: String
        var macProjectSHA256: String
        var windowsProjectSHA256: String?
        var macReturnProjectSHA256: String?
    }
    private struct Packet: Codable {
        var schemaVersion = 1
        var stage: String
        var host: String
        var status = "completed"
        var cases: [Row]
    }
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func sha(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func ownedDirectory(_ key: String, empty: Bool) throws -> URL {
        let path = try #require(ProcessInfo.processInfo.environment[key])
        let url = URL(fileURLWithPath: path)
        let canonical = try VideoProjectSourceBinding.Source.resolved(url)
        let build = try VideoProjectSourceBinding.Source.resolved(root.appendingPathComponent(".build"))
        guard canonical.path.hasPrefix(build.path + "/"),
              (try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).isDirectory == true,
              (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw ProjectFile.ProjectError.invalidContent }
        if empty {
            let contents = try FileManager.default.contentsOfDirectory(atPath: url.path)
            try #require(contents.isEmpty)
        }
        return canonical
    }
    private func fixture(_ index: Int) throws -> (URL, Data) {
        let folder = root.appendingPathComponent("shared/fixtures/video-timelines")
        let manifest = try VideoProjectFile.read(at: folder.appendingPathComponent("manifest.json"))
        try #require(sha(manifest) == manifestSHA, "Only the committed synthetic fixture manifest is permitted")
        let url = folder.appendingPathComponent(kinds[index] + ".mov")
        let bytes = try VideoProjectFile.read(at: url)
        try #require(sha(bytes) == hashes[index], "Unapproved media must not reach native decoding")
        return (url, bytes)
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(15))
        while !predicate(), ContinuousClock.now < end { try await Task.sleep(nanoseconds: 5_000_000) }
        try #require(predicate(), "Owned native controller stage timed out")
    }
    private func rich(_ binding: VideoProjectSourceBinding) throws -> VideoProjectFile {
        let group = UUID(uuidString: "00000000-0000-0000-0000-000000000777")!
        var regions: [ProjectFile.Region] = []
        for index in 0..<3 {
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
            let shape: RegionShape
            switch index {
            case 0: shape = .rectangle(id: id, origin: .init(x: 0.125, y: 0.125), size: .init(width: 0.5, height: 0.5))
            case 1: shape = .ellipse(id: id, origin: .init(x: 0.25, y: 0.25), size: .init(width: 0.5, height: 0.5))
            default: shape = .polygon(id: id, points: [.init(x: 0.125, y: 0.125), .init(x: 0.75, y: 0.625), .init(x: 0.25, y: 0.75)])
            }
            var effect = RegionEffect.alwaysOn()
            effect.name = "region-\(index)"; effect.groupID = group
            effect.style = [.solid, .blur, .mosaic][index]
            effect.blurRadius = 12.5; effect.featherRadius = 0.03125
            effect.timeRange = index == 2 ? 4...6 : 0...0
            effect.keyframes = [.init(time: 2, rect: CGRect(x: 0.125, y: 0.125, width: 0.5, height: 0.5)),
                .init(time: 1, rect: CGRect(x: 0.25, y: 0.125, width: 0.5, height: 0.5)),
                .init(time: 1, rect: CGRect(x: 0.125, y: 0.125, width: 0.5, height: 0.5))]
            effect.erasures = [.init(points: [.init(x: 0.1875, y: 0.1875)], width: 0.03125, from: nil),
                .init(points: [.init(x: 0.375, y: 0.375)], width: 0.03125, from: 0.625)]
            regions.append(.init(shape: shape, effect: effect))
        }
        let kinds: [DrawingAnnotation.Kind] = [.rectangle, .ellipse, .line, .freehand, .arrow, .text]
        let drawings = kinds.enumerated().map { index, kind in
            var item = DrawingAnnotation(kind: kind, points: [.init(x: 0.125, y: 0.1875), .init(x: 0.625, y: 0.6875)],
                color: NSColor(srgbRed: 0.25, green: 0.5, blue: 0.75, alpha: 0.5), lineWidth: 0.015625, fillOpacity: 0.375)
            item.id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 100))!
            item.name = "drawing-\(index)"; item.groupID = group; item.bold = false
            item.text = "공통 첫 줄\n둘째 줄"; item.timeRange = index == 5 ? 4...6 : 0...0
            item.keyframes = regions[0].effect.keyframes; item.erasures = regions[0].effect.erasures
            return item
        }
        let project = try VideoProjectFile.make(mediaPath: binding.source.url.lastPathComponent, binding: binding,
            producerVersion: "test.cross-platform.mac", regions: regions, drawings: drawings)
        var text = String(decoding: try project.encoded(), as: UTF8.self)
        try #require(text.contains("\"blurRadius\":12.5"))
        text = text.replacingOccurrences(of: "\"blurRadius\":12.5", with: "\"blurRadius\":1.2500e+1")
        try #require(text.contains("\"color\":{\"alpha\":1,\"blue\":0,\"green\":0,\"red\":0}"))
        text = text.replacingOccurrences(of: "\"color\":{\"alpha\":1,\"blue\":0,\"green\":0,\"red\":0}", with: "\"color\":null")
        try #require(text.contains("\"name\":\"drawing-0\""))
        text = text.replacingOccurrences(of: "\"name\":\"drawing-0\"", with: "\"name\":\"drawing-0\",\"fontName\":null,\"textBackground\":null")
        return try VideoProjectFile.decode(Data(text.utf8))
    }
    private func nativeSave(_ project: VideoProjectFile, source: URL, output: URL) async throws -> Data {
        var errors: [String] = []
        let controller = MainWindowController(loadErrorPresenter: { errors.append($0) })
        defer { controller.cancelCurrentOperation(); controller.cancelPendingMediaLoad(); controller.close() }
        controller.openVideoProject(project, media: source)
        try await wait { !controller.mediaLoadSessionDiagnostics.pending }
        #expect(errors.isEmpty)
        let projected = try VideoProjectFile.decode(controller.projectData(producerVersion: "test.cross-platform.mac"))
        #expect(projected.payload.regions == project.payload.regions)
        #expect(projected.payload.drawings == project.payload.drawings)
        #expect(projected.timeline == project.timeline)
        try controller.saveVideoProject(to: output, producerVersion: "test.cross-platform.mac")
        try await wait { !controller.projectSaveInProgress }
        #expect(errors.isEmpty)
        return try VideoProjectFile.read(at: output)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BLURACTION_V3_ROUNDTRIP_STAGE"] != nil,
        "Separate required three-stage driver; a disabled native test is not roundtrip evidence"))
    func actualNativeCrossPlatformStage() async throws {
        _ = NSApplication.shared
        let stage = try #require(ProcessInfo.processInfo.environment["BLURACTION_V3_ROUNDTRIP_STAGE"])
        let output = try ownedDirectory("BLURACTION_V3_ROUNDTRIP_OUTPUT", empty: true)
        let input: URL?
        if stage == "verify" { input = try ownedDirectory("BLURACTION_V3_ROUNDTRIP_INPUT", empty: false) }
        else { input = nil }
        var incoming: Packet?
        if let input {
            incoming = try JSONDecoder().decode(Packet.self, from: VideoProjectFile.read(at: input.appendingPathComponent("packet.json")))
            try #require(incoming?.schemaVersion == 1 && incoming?.stage == "windows-edit"
                && incoming?.host == "windows" && incoming?.status == "completed")
            try #require(incoming?.cases.map(\.kind) == kinds)
        } else { try #require(stage == "emit") }
        var rows: [Row] = []
        for index in kinds.indices {
            let (original, originalBytes) = try fixture(index)
            let kind = kinds[index]
            if stage == "emit" {
                let source = output.appendingPathComponent(kind + ".mov")
                try originalBytes.write(to: source, options: .withoutOverwriting)
                let binding = try await VideoProjectSourceBinding.observe(url: source)
                let project = try rich(binding)
                let bytes = try await nativeSave(project, source: source, output: output.appendingPathComponent(kind + ".mac.bluraction"))
                let raw = String(decoding: bytes, as: UTF8.self)
                #expect(raw.contains("1.2500e+1") && raw.contains("\"fontName\":null") && raw.contains("\"color\":null"))
                rows.append(Row(kind: kind, sourceSHA256: hashes[index], macProjectSHA256: sha(bytes)))
            } else {
                let input = try #require(input), row = try #require(incoming?.cases[index])
                let source = input.appendingPathComponent(kind + ".mov")
                let sourceBytes = try VideoProjectFile.read(at: source)
                try #require(sourceBytes == originalBytes && row.sourceSHA256 == hashes[index])
                let macBytes = try VideoProjectFile.read(at: input.appendingPathComponent(kind + ".mac.bluraction"))
                let winBytes = try VideoProjectFile.read(at: input.appendingPathComponent(kind + ".windows.bluraction"))
                try #require(sha(macBytes) == row.macProjectSHA256 && sha(winBytes) == row.windowsProjectSHA256)
                let mac = try VideoProjectFile.decode(macBytes), windows = try VideoProjectFile.decode(winBytes)
                var expected = mac.payload.drawings; expected[0].name = editedName
                #expect(windows.payload.producer.platform == "windows")
                #expect(windows.timeline == mac.timeline && windows.sourceSHA256 == mac.sourceSHA256)
                #expect(windows.payload.regions == mac.payload.regions && windows.payload.drawings == expected)
                // Keep returned project references portable and avoid publishing
                // the private incoming attempt's absolute local path.
                let returnedSource = output.appendingPathComponent(kind + ".mov")
                try sourceBytes.write(to: returnedSource, options: .withoutOverwriting)
                let bytes = try await nativeSave(windows, source: returnedSource, output: output.appendingPathComponent(kind + ".mac-return.bluraction"))
                let reopened = try VideoProjectFile.decode(bytes)
                #expect(reopened.mediaPath == kind + ".mov")
                #expect(reopened.payload.regions == windows.payload.regions && reopened.payload.drawings == windows.payload.drawings)
                #expect(reopened.timeline == windows.timeline)
                #expect(String(decoding: bytes, as: UTF8.self).contains("\"fontName\":null"))
                let afterInput = try VideoProjectFile.read(at: source); #expect(afterInput == sourceBytes)
                let afterReturned = try VideoProjectFile.read(at: returnedSource); #expect(afterReturned == sourceBytes)
                rows.append(Row(kind: kind, sourceSHA256: hashes[index], macProjectSHA256: row.macProjectSHA256,
                    windowsProjectSHA256: row.windowsProjectSHA256, macReturnProjectSHA256: sha(bytes)))
            }
            let after = try VideoProjectFile.read(at: original); #expect(after == originalBytes)
        }
        let packet = Packet(stage: stage == "emit" ? "mac-emit" : "mac-verify", host: "macos", cases: rows)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(packet).write(to: output.appendingPathComponent("packet.json"), options: .withoutOverwriting)
    }
}
