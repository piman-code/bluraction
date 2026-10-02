import Foundation
import CoreGraphics
import CryptoKit
import Darwin
import AppKit

/// Video v3 is separate from image v1/PDF workspace v2. Original tokens are the
/// save baseline; Codable models are only an editable/renderable projection.
struct VideoProjectFile {
    struct Producer: Codable, Equatable {
        var name = "BlurAction"
        var platform = "macos"
        var version: String
    }
    struct Review: LocalizedError {
        let reason: String
        let originalData: Data
        var errorDescription: String? { "프로젝트 호환 검토가 필요합니다. 기존 작업은 유지됩니다.\n" + reason }
    }
    struct Payload: Codable {
        var version = 3
        var mediaKind = "video"
        var mediaPath: String
        var sourceSHA256: String
        var producer: Producer
        var timeline: VideoTimeline
        var regions: [ProjectFile.Region]
        var drawings: [DrawingAnnotation]
    }
    private var tree: Node
    let payload: Payload
    var mediaPath: String { payload.mediaPath }
    var sourceSHA256: String { payload.sourceSHA256 }
    var timeline: VideoTimeline { payload.timeline }
    var edits: ProjectFile {
        ProjectFile(mediaPath: mediaPath, regions: payload.regions, drawings: payload.drawings,
                    sourceSHA256: sourceSHA256)
    }

    static func decode(_ data: Data) throws -> VideoProjectFile {
        guard data.count <= ProjectFile.maximumBytes else { throw ProjectFile.ProjectError.tooLarge }
        let inspection = try ProjectJSONTokens.inspect(data)
        guard inspection.version == 3, let rawTimeline = inspection.rawTimeline else {
            throw ProjectFile.ProjectError.unsupportedVersion
        }
        let tree = try Node.parse(data)
        func fields(_ node: Node, _ required: Set<String>, _ allowed: Set<String>, _ path: String) throws {
            guard case .object(let values) = node else { throw ProjectFile.ProjectError.invalidContent }
            let keys = Set(values.keys)
            guard required.isSubset(of: keys) else { throw ProjectFile.ProjectError.invalidContent }
            if !keys.isSubset(of: allowed) {
                throw Review(reason: path + ": 지원하지 않는 필드 " + keys.subtracting(allowed).sorted().joined(separator: ", "), originalData: data)
            }
        }
        let root: Set<String> = ["version", "mediaKind", "mediaPath", "sourceSHA256", "producer", "timeline", "regions", "drawings"]
        try fields(tree, root, root, "project")
        try fields(try tree.value("producer"), ["name", "platform", "version"], ["name", "platform", "version"], "producer")
        try validateKnownEdits(tree, original: data)
        // NSNumber cannot preserve arbitrary original integers. Keep tokens and
        // refuse known model values outside the exact integer Double domain.
        try tree.rejectInexactModelIntegers(excluding: ["timeline"], original: data)
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.version == 3, payload.mediaKind == "video",
              payload.producer.name == "BlurAction", ["macos", "windows"].contains(payload.producer.platform),
              validProducerVersion(payload.producer.version),
              payload.timeline == (try VideoTimeline.decode(rawTimeline)) else { throw ProjectFile.ProjectError.invalidContent }
        _ = try ProjectFile.decode(ProjectFile(mediaPath: payload.mediaPath, regions: payload.regions,
            drawings: payload.drawings, sourceSHA256: payload.sourceSHA256).encoded())
        guard payload.sourceSHA256.count == 64 else { throw ProjectFile.ProjectError.invalidContent }
        return VideoProjectFile(tree: tree, payload: payload)
    }

    /// A legacy file with unknown semantics must not be projected through
    /// Codable and then promoted to v3 after those original fields disappeared.
    static func decodeLegacy(_ data: Data) throws -> ProjectFile {
        guard data.count <= ProjectFile.maximumBytes else { throw ProjectFile.ProjectError.tooLarge }
        guard try version(of: data) == 1 else { throw ProjectFile.ProjectError.unsupportedVersion }
        let tree = try Node.parse(data)
        guard case .object(let root) = tree else { throw ProjectFile.ProjectError.invalidContent }
        let allowed: Set<String> = ["version", "mediaPath", "sourceSHA256", "regions", "drawings"]
        guard Set(root.keys).isSubset(of: allowed) else {
            throw Review(reason: "기존 프로젝트의 지원하지 않는 필드는 자동 변환하지 않습니다.", originalData: data)
        }
        try validateKnownEdits(tree, original: data)
        try tree.rejectInexactModelIntegers(original: data)
        return try ProjectFile.decode(data)
    }

    private static func validateKnownEdits(_ tree: Node, original data: Data) throws {
        func fields(_ node: Node, _ required: Set<String>, _ allowed: Set<String>, _ path: String) throws {
            guard case .object(let values) = node else { throw ProjectFile.ProjectError.invalidContent }
            let keys = Set(values.keys)
            guard required.isSubset(of: keys) else { throw ProjectFile.ProjectError.invalidContent }
            guard keys.isSubset(of: allowed) else {
                throw Review(reason: path + ": 지원하지 않는 필드 " + keys.subtracting(allowed).sorted().joined(separator: ", "), originalData: data)
            }
        }
        func color(_ node: Node, _ path: String) throws {
            try fields(node, ["red", "green", "blue", "alpha"], ["red", "green", "blue", "alpha"], path)
        }
        func temporal(_ node: Node, _ path: String) throws {
            if let frames = node.optional("keyframes"), !frames.isNull {
                for frame in try frames.arrayValues() {
                    try fields(frame, ["time", "rect"], ["time", "rect"], path + ".keyframe")
                }
            }
            if let strokes = node.optional("erasures"), !strokes.isNull {
                for stroke in try strokes.arrayValues() {
                    try fields(stroke, ["points", "width"], ["points", "width", "from"], path + ".erasure")
                }
            }
        }
        for region in try tree.value("regions").arrayValues() {
            try fields(region, ["shape", "effect"], ["shape", "effect"], "region")
            let shape = try region.value("shape")
            guard case .object(let variants) = shape, variants.count == 1, let kind = variants.keys.first else {
                throw ProjectFile.ProjectError.invalidContent
            }
            let required: Set<String>
            switch kind {
            case "rectangle", "ellipse": required = ["id", "origin", "size"]
            case "polygon": required = ["id", "points"]
            default: throw Review(reason: "지원하지 않는 영역 종류", originalData: data)
            }
            try fields(try shape.value(kind), required, required, "shape." + kind)
            let effect = try region.value("effect")
            let requiredEffect: Set<String> = ["blurRadius", "featherRadius", "timeRange", "enabled", "keyframes"]
            try fields(effect, requiredEffect, requiredEffect.union(["style", "color", "groupID", "erasures", "name", "locked"]), "effect")
            if let c = effect.optional("color"), !c.isNull { try color(c, "effect.color") }
            try temporal(effect, "effect")
        }
        for drawing in try tree.value("drawings").arrayValues() {
            let required: Set<String> = ["id", "kind", "points", "red", "green", "blue", "alpha", "lineWidth"]
            try fields(drawing, required, required.union(["fillOpacity", "timeRange", "keyframes", "text", "groupID", "erasures", "name", "hidden", "locked", "fontName", "bold", "textBackground"]), "drawing")
            if let c = drawing.optional("textBackground"), !c.isNull { try color(c, "drawing.textBackground") }
            try temporal(drawing, "drawing")
        }
    }

    static func validProducerVersion(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [43, 46, 95, 45].contains($0)
        }
    }

    static func make(mediaPath: String, binding: VideoProjectSourceBinding, producerVersion: String,
                     regions: [ProjectFile.Region], drawings: [DrawingAnnotation]) throws -> VideoProjectFile {
        guard validProducerVersion(producerVersion) else { throw ProjectFile.ProjectError.invalidContent }
        let payload = Payload(mediaPath: mediaPath, sourceSHA256: binding.source.sha256,
            producer: Producer(version: producerVersion), timeline: binding.timeline, regions: regions, drawings: drawings)
        return try decode(JSONEncoder().encode(payload))
    }

    func verify(binding: VideoProjectSourceBinding) throws {
        guard sourceSHA256 == binding.source.sha256, timeline == binding.timeline else {
            throw PageWorkspace.WorkspaceError.sourceChanged
        }
    }

    /// Three-way patch: compare native baseline/current, but write normalized
    /// new values. Untouched leaves retain original tokens/null/omitted fields.
    func updated(mediaPath: String, binding: VideoProjectSourceBinding, producerVersion: String,
                 baseline: ProjectFile, current: ProjectFile, normalized: ProjectFile) throws -> VideoProjectFile {
        try verify(binding: binding)
        guard Self.validProducerVersion(producerVersion) else { throw ProjectFile.ProjectError.invalidContent }
        var result = tree
        result.set("mediaPath", .string(mediaPath))
        result.set("producer", try Node.encoded(Producer(version: producerVersion)))
        func patchItems<T: Encodable>(_ original: Node, _ old: [T], _ now: [T], _ replacement: [T], ids: (T) -> UUID) throws -> Node {
            let raw = try original.arrayValues()
            var lookup: [UUID: (Node, Node)] = [:]
            for (index, item) in old.enumerated() {
                guard index < raw.count else { throw ProjectFile.ProjectError.invalidContent }
                lookup[ids(item)] = (raw[index], try Node.encoded(item))
            }
            guard now.count == replacement.count else { throw ProjectFile.ProjectError.invalidContent }
            return .array(try now.enumerated().map { index, item in
                let next = try Node.encoded(replacement[index])
                guard let previous = lookup[ids(item)] else { return next }
                return Node.patch(previous.0, before: previous.1, after: try Node.encoded(item), replacement: next)
            })
        }
        result.set("regions", try patchItems(tree.value("regions"), baseline.regions, current.regions, normalized.regions, ids: { $0.shape.id }))
        result.set("drawings", try patchItems(tree.value("drawings"), baseline.drawings, current.drawings, normalized.drawings, ids: { $0.id }))
        return try Self.decode(result.data())
    }

    func encoded() throws -> Data { try tree.data() }
    func relinked(to mediaPath: String) throws -> VideoProjectFile {
        var result = tree; result.set("mediaPath", .string(mediaPath)); return try Self.decode(result.data())
    }

    @MainActor
    static func requireAvailableFonts(_ drawings: [DrawingAnnotation]) throws {
        let missing = Set(drawings.filter { $0.kind == .text && !$0.hidden }.compactMap { item -> String? in
            guard let name = item.fontName else { return nil }
            if NSFont(name: name, size: 12) != nil || NSFontManager.shared.availableMembers(ofFontFamily: name) != nil { return nil }
            return name
        })
        if !missing.isEmpty { throw Review(reason: "이 Mac에 없는 글꼴: " + missing.sorted().joined(separator: ", ") + ". 설치된 글꼴로 명시 변경한 프로젝트가 필요합니다.", originalData: Data()) }
    }

    static func read(at url: URL, maximumBytes: Int = MultiPageProjectFile.maximumBytes) throws -> Data {
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_size > 0, status.st_size <= maximumBytes else { throw ProjectFile.ProjectError.tooLarge }
        let snapshot = try VideoProjectSourceBinding.Source.capture(url)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ProjectFile.ProjectError.invalidContent }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            var opened = stat(); guard fstat(descriptor, &opened) == 0, VideoProjectSourceBinding.Source.state(opened) == snapshot.metadata else { throw PageWorkspace.WorkspaceError.sourceChanged }
            var result = Data(); var left = status.st_size
            while left > 0 {
                let bytes = try handle.read(upToCount: Int(min(left, 1_048_576))) ?? Data()
                guard !bytes.isEmpty else { throw ProjectFile.ProjectError.invalidContent }
                result.append(bytes); left -= Int64(bytes.count)
            }
            guard (try handle.read(upToCount: 1) ?? Data()).isEmpty else { throw PageWorkspace.WorkspaceError.sourceChanged }
            try handle.close(); try snapshot.validate()
            return result
        } catch {
            let primary = error
            do { try handle.close() } catch { throw VideoProjectSourceBinding.SourceReadFailure(primary: primary, cleanup: error, retained: handle) }
            throw primary
        }
    }

    /// Decoder selection must not collapse duplicate keys or coerce 3.0 to 3.
    /// Legacy v2 retains its 50 MiB boundary; v3 decode still enforces 20 MiB.
    static func version(of data: Data) throws -> Int {
        var parser = try DispatchParser(data)
        return try parser.version()
    }

    /// Token-only grammar boundary for legacy dispatch. It builds no edit tree
    /// and never converts a timeline/geometry number through NSNumber or Double.
    private struct DispatchParser {
        let bytes: [UInt8]
        var index = 0, values = 0, members = 0
        var rootVersion: Range<Int>?
        init(_ data: Data) throws {
            guard !data.isEmpty, data.count <= MultiPageProjectFile.maximumBytes else { throw ProjectFile.ProjectError.tooLarge }
            guard String(data: data, encoding: .utf8) != nil else { throw ProjectFile.ProjectError.invalidContent }
            bytes = Array(data)
        }
        mutating func whitespace() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1; return true
        }
        mutating func version() throws -> Int {
            whitespace()
            guard index < bytes.count, bytes[index] == 123 else { throw ProjectFile.ProjectError.invalidContent }
            _ = try value(depth: 0, root: true); whitespace()
            guard index == bytes.count, let range = rootVersion else { throw ProjectFile.ProjectError.invalidContent }
            let token = bytes[range]
            guard !token.contains(46), !token.contains(69), !token.contains(101),
                  let text = String(bytes: token, encoding: .utf8), let version = Int(text) else { throw ProjectFile.ProjectError.invalidContent }
            return version
        }
        mutating func value(depth: Int, root: Bool = false) throws -> Range<Int> {
            whitespace(); values += 1
            guard values <= 2_000_000, index < bytes.count else { throw ProjectFile.ProjectError.invalidContent }
            let start = index
            switch bytes[index] {
            case 123:
                guard depth < 64 else { throw ProjectFile.ProjectError.invalidContent }
                index += 1; whitespace(); var keys = Set<Data>()
                if !consume(125) {
                    while true {
                        let key = try string(key: true)
                        guard keys.insert(Data(key.utf8)).inserted else { throw ProjectFile.ProjectError.invalidContent }
                        members += 1; guard members <= 1_000_000 else { throw ProjectFile.ProjectError.invalidContent }
                        whitespace(); guard consume(58) else { throw ProjectFile.ProjectError.invalidContent }
                        let field = try value(depth: depth + 1)
                        if root && key == "version" { rootVersion = field }
                        whitespace(); if consume(125) { break }
                        guard consume(44) else { throw ProjectFile.ProjectError.invalidContent }
                    }
                }
            case 91:
                guard depth < 64 else { throw ProjectFile.ProjectError.invalidContent }
                index += 1; whitespace()
                if !consume(93) {
                    while true {
                        _ = try value(depth: depth + 1); whitespace()
                        if consume(93) { break }
                        guard consume(44) else { throw ProjectFile.ProjectError.invalidContent }
                    }
                }
            case 34: _ = try string(key: false)
            case 116: try literal([116, 114, 117, 101])
            case 102: try literal([102, 97, 108, 115, 101])
            case 110: try literal([110, 117, 108, 108])
            case 45, 48...57: try number()
            default: throw ProjectFile.ProjectError.invalidContent
            }
            return start..<index
        }
        mutating func string(key: Bool) throws -> String {
            whitespace(); let start = index
            guard consume(34) else { throw ProjectFile.ProjectError.invalidContent }
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 {
                    let raw = bytes[start..<index]
                    if key && raw.count > 4096 { throw ProjectFile.ProjectError.invalidContent }
                    return try JSONDecoder().decode(String.self, from: Data(raw))
                }
                guard byte >= 32 else { throw ProjectFile.ProjectError.invalidContent }
                if byte == 92 {
                    guard index < bytes.count else { throw ProjectFile.ProjectError.invalidContent }
                    let escaped = bytes[index]; index += 1
                    if escaped == 117 {
                        guard bytes.count - index >= 4 else { throw ProjectFile.ProjectError.invalidContent }
                        for digit in bytes[index..<index + 4] {
                            guard (48...57).contains(digit) || (65...70).contains(digit) || (97...102).contains(digit) else { throw ProjectFile.ProjectError.invalidContent }
                        }
                        index += 4
                    } else if ![34, 92, 47, 98, 102, 110, 114, 116].contains(escaped) { throw ProjectFile.ProjectError.invalidContent }
                }
            }
            throw ProjectFile.ProjectError.invalidContent
        }
        mutating func literal(_ literal: [UInt8]) throws {
            guard bytes.count - index >= literal.count,
                  Array(bytes[index..<index + literal.count]) == literal else { throw ProjectFile.ProjectError.invalidContent }
            index += literal.count
        }
        mutating func number() throws {
            _ = consume(45)
            guard index < bytes.count else { throw ProjectFile.ProjectError.invalidContent }
            if consume(48) {
                if index < bytes.count && (48...57).contains(bytes[index]) { throw ProjectFile.ProjectError.invalidContent }
            } else {
                guard (49...57).contains(bytes[index]) else { throw ProjectFile.ProjectError.invalidContent }
                while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
            }
            if consume(46) { try digits() }
            if consume(69) || consume(101) {
                if !consume(43) { _ = consume(45) }; try digits()
            }
        }
        mutating func digits() throws {
            let start = index
            while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
            guard index > start else { throw ProjectFile.ProjectError.invalidContent }
        }
    }

    // Internal byte-token tree. Generic grammar/duplicates/resource limits are
    // checked BEFORE this parser; it never uses NSNumber or executes payloads.
    private indirect enum Node {
        case object([String: Node]), array([Node]), string(String), number(Data), bool(Bool), null
        var isNull: Bool { if case .null = self { return true }; return false }
        func optional(_ key: String) -> Node? { if case .object(let v) = self { return v[key] }; return nil }
        func value(_ key: String) throws -> Node { guard let v = optional(key) else { throw ProjectFile.ProjectError.invalidContent }; return v }
        func arrayValues() throws -> [Node] { guard case .array(let v) = self else { throw ProjectFile.ProjectError.invalidContent }; return v }
        mutating func set(_ key: String, _ value: Node) { if case .object(var v) = self { v[key] = value; self = .object(v) } }
        static func encoded<T: Encodable>(_ v: T) throws -> Node { try parse(JSONEncoder().encode(v)) }
        static func parse(_ data: Data) throws -> Node {
            try ProjectJSONTokens.validateObjectOrValueForVideoProject(data)
            var parser = Parser(bytes: Array(data)); return try parser.value()
        }
        func data() throws -> Data {
            var output = Data()
            func append(_ node: Node) throws {
                switch node {
                case .object(let values):
                    output.append(123)
                    for (i, key) in values.keys.sorted().enumerated() {
                        if i > 0 { output.append(44) }
                        output.append(try JSONEncoder().encode(key)); output.append(58); try append(values[key]!)
                    }
                    output.append(125)
                case .array(let values):
                    output.append(91); for (i, v) in values.enumerated() { if i > 0 { output.append(44) }; try append(v) }; output.append(93)
                case .string(let value): output.append(try JSONEncoder().encode(value))
                case .number(let token): output.append(token)
                case .bool(let value): output.append(contentsOf: (value ? "true" : "false").utf8)
                case .null: output.append(contentsOf: "null".utf8)
                }
                guard output.count <= ProjectFile.maximumBytes else { throw ProjectFile.ProjectError.tooLarge }
            }
            try append(self); return output
        }
        func rejectInexactModelIntegers(excluding: Set<String> = [], original: Data) throws {
            switch self {
            case .number(let raw):
                let text = String(decoding: raw, as: UTF8.self)
                let magnitude = text.hasPrefix("-") ? String(text.dropFirst()) : text
                if !text.contains("."), !text.contains("e"), !text.contains("E"),
                   (magnitude.count > 16 || (magnitude.count == 16 && magnitude > "9007199254740992")) {
                    throw Review(reason: "현재 편집 모델로 정확히 표현할 수 없는 정수입니다. 원래 숫자는 변경하지 않았습니다.", originalData: original)
                }
            case .object(let values): for (key, value) in values where !excluding.contains(key) { try value.rejectInexactModelIntegers(original: original) }
            case .array(let values): for value in values { try value.rejectInexactModelIntegers(original: original) }
            default: break
            }
        }
        static func same(_ a: Node, _ b: Node) -> Bool {
            switch (a, b) {
            case (.string(let x), .string(let y)): return x == y
            case (.number(let x), .number(let y)): return x == y || Double(String(decoding: x, as: UTF8.self)) == Double(String(decoding: y, as: UTF8.self))
            case (.bool(let x), .bool(let y)): return x == y
            case (.null, .null): return true
            case (.array(let x), .array(let y)): return x.count == y.count && zip(x, y).allSatisfy { same($0, $1) }
            case (.object(let x), .object(let y)): return x.keys.count == y.keys.count && x.allSatisfy { key, value in y[key].map { same(value, $0) } ?? false }
            default: return false
            }
        }
        static func patch(_ raw: Node, before: Node, after: Node, replacement: Node) -> Node {
            if same(before, after) { return raw }
            if case .object(let old) = before, case .object(let now) = after,
               case .object(let new) = replacement, case .object(var output) = raw {
                for key in Set(old.keys).union(now.keys) {
                    if let a = old[key], let b = now[key], same(a, b) { continue }
                    guard let b = now[key], let c = new[key] else { output.removeValue(forKey: key); continue }
                    if let a = old[key], let original = output[key] { output[key] = patch(original, before: a, after: b, replacement: c) }
                    else { output[key] = c }
                }
                return .object(output)
            }
            if case .array(let old) = before, case .array(let now) = after,
               case .array(let new) = replacement, case .array(let original) = raw,
               old.count == now.count, old.count == new.count, old.count == original.count {
                return .array(old.indices.map { patch(original[$0], before: old[$0], after: now[$0], replacement: new[$0]) })
            }
            return replacement
        }
        private struct Parser {
            let bytes: [UInt8]; var index = 0
            mutating func whitespace() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
            mutating func value() throws -> Node {
                whitespace(); guard index < bytes.count else { throw ProjectFile.ProjectError.invalidContent }
                switch bytes[index] {
                case 123:
                    index += 1; whitespace(); var values: [String: Node] = [:]
                    if bytes[index] == 125 { index += 1; return .object(values) }
                    while true {
                        let key = try string(); whitespace(); index += 1; values[key] = try value(); whitespace()
                        if bytes[index] == 125 { index += 1; return .object(values) }; index += 1
                    }
                case 91:
                    index += 1; whitespace(); var values: [Node] = []
                    if bytes[index] == 93 { index += 1; return .array(values) }
                    while true { values.append(try value()); whitespace(); if bytes[index] == 93 { index += 1; return .array(values) }; index += 1 }
                case 34: return .string(try string())
                case 116: index += 4; return .bool(true)
                case 102: index += 5; return .bool(false)
                case 110: index += 4; return .null
                default:
                    let start = index
                    while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
                    return .number(Data(bytes[start..<index]))
                }
            }
            mutating func string() throws -> String {
                whitespace(); let start = index; index += 1
                while index < bytes.count {
                    let byte = bytes[index]; index += 1
                    if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                    if byte == 92 { index += 1 }
                }
                throw ProjectFile.ProjectError.invalidContent
            }
        }
    }
}

/// The token grammar accepts an object root only. Wrapping a typed array/scalar
/// lets internal raw-tree nodes use the same bounds without modifying the parser.
private extension ProjectJSONTokens {
    static func validateObjectOrValueForVideoProject(_ data: Data) throws {
        if data.first == 123 { try validateObject(data); return }
        var wrapped = Data("{\"value\":".utf8); wrapped.append(data); wrapped.append(125)
        try validateObject(wrapped)
    }
}

struct VideoProjectSourceBinding: @unchecked Sendable {
    struct Source: Equatable, Sendable {
        let url: URL
        let canonical: URL
        let metadata: [Int64]
        let parents: [[Int64]]
        let aliasParents: [[Int64]]
        let sha256: String
        static func parentStates(_ url: URL, allowingAliases: Bool = false) throws -> [[Int64]] {
            var path = (url.path as NSString).deletingLastPathComponent, result: [[Int64]] = []
            // NSString's path operation and explicit root termination avoid
            // URL.deletingLastPathComponent producing /.., /../.. indefinitely.
            for _ in 0..<1024 {
                var value = stat()
                guard lstat(path, &value) == 0 else { throw PageWorkspace.WorkspaceError.sourceChanged }
                let kind = value.st_mode & S_IFMT
                guard kind == S_IFDIR || (allowingAliases && kind == S_IFLNK) else { throw PageWorkspace.WorkspaceError.sourceChanged }
                // Directory content changes are legitimate. A parent symlink's
                // full metadata instead binds the original alias route.
                result.append(kind == S_IFLNK ? [Int64(kind)] + state(value) : [Int64(kind), Int64(value.st_dev), Int64(value.st_ino)])
                if path == "/" { return result }
                let next = (path as NSString).deletingLastPathComponent
                guard !next.isEmpty, next != path else { throw PageWorkspace.WorkspaceError.sourceChanged }
                path = next
            }
            throw PageWorkspace.WorkspaceError.sourceChanged
        }
        static func resolved(_ url: URL) throws -> URL {
            guard let bytes = realpath(url.path, nil) else { throw PageWorkspace.WorkspaceError.sourceChanged }
            defer { free(bytes) }
            return URL(fileURLWithPath: String(cString: bytes))
        }
        static func state(_ value: stat) -> [Int64] {
            [Int64(value.st_dev), Int64(value.st_ino), Int64(value.st_size),
             Int64(value.st_mtimespec.tv_sec), Int64(value.st_mtimespec.tv_nsec),
             Int64(value.st_ctimespec.tv_sec), Int64(value.st_ctimespec.tv_nsec)]
        }
        static func capture(_ url: URL, cancel: () throws -> Void = {}) throws -> Source {
            try cancel()
            // Foundation standardization can rewrite real filesystem aliases.
            // Check lexical traversal here; POSIX resolution + both route and
            // canonical identity checks below are the filesystem boundary.
            let components = url.path.split(separator: "/", omittingEmptySubsequences: false)
            guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0),
                  !components.contains(where: { $0 == "." || $0 == ".." }) else { throw PageWorkspace.WorkspaceError.sourceChanged }
            var status = stat()
            guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_size > 0 else { throw PageWorkspace.WorkspaceError.sourceChanged }
            let expected = state(status)
            let canonical = try resolved(url)
            let parents = try parentStates(canonical)
            let aliases = try parentStates(url, allowingAliases: true)
            let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { throw PageWorkspace.WorkspaceError.sourceChanged }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                var opened = stat(); guard fstat(fd, &opened) == 0, state(opened) == expected else { throw PageWorkspace.WorkspaceError.sourceChanged }
                var hash = SHA256(); var left = status.st_size
                while left > 0 {
                    try cancel()
                    let bytes = try handle.read(upToCount: Int(min(left, 1_048_576))) ?? Data()
                    guard !bytes.isEmpty else { throw PageWorkspace.WorkspaceError.sourceChanged }
                    left -= Int64(bytes.count); hash.update(data: bytes)
                }
                guard (try handle.read(upToCount: 1) ?? Data()).isEmpty else { throw PageWorkspace.WorkspaceError.sourceChanged }
                var after = stat(); var path = stat()
                guard fstat(fd, &after) == 0, lstat(url.path, &path) == 0,
                      state(after) == expected, state(path) == expected,
                      try parentStates(canonical) == parents,
                      try parentStates(url, allowingAliases: true) == aliases,
                      try resolved(url).path == canonical.path else { throw PageWorkspace.WorkspaceError.sourceChanged }
                try cancel(); try handle.close()
                return Source(url: url, canonical: canonical, metadata: expected, parents: parents, aliasParents: aliases,
                    sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
            } catch {
                let primary = error
                do { try handle.close() } catch { throw SourceReadFailure(primary: primary, cleanup: error, retained: handle) }
                throw primary
            }
        }
        func validateIdentity() throws {
            var status = stat()
            guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
                  Self.state(status) == metadata, try Self.parentStates(canonical) == parents,
                  try Self.parentStates(url, allowingAliases: true) == aliasParents,
                  try Self.resolved(url).path == canonical.path else {
                throw PageWorkspace.WorkspaceError.sourceChanged
            }
        }
        func validate(cancel: () throws -> Void = {}) throws {
            guard try Self.capture(url, cancel: cancel) == self else { throw PageWorkspace.WorkspaceError.sourceChanged }
        }
    }
    struct SourceReadFailure: LocalizedError {
        let primary: Error; let cleanup: Error; let retained: FileHandle
        var errorDescription: String? { primary.localizedDescription + "\n원본 읽기 핸들 정리 실패: " + cleanup.localizedDescription }
        func retryCleanup() throws { try retained.close() }
    }
    let source: Source
    let timeline: VideoTimeline
    // Exact immutable DTO contains value types; it is not a native AVAsset.
    init(source: Source, timeline: VideoTimeline) { self.source = source; self.timeline = timeline }
    static func observe(url: URL) async throws -> VideoProjectSourceBinding {
        let before = try await capture(url)
        let timeline = try await VideoAssetTimeline.read(url: url)
        try Task.checkCancellation()
        let after = try await capture(url)
        guard before == after else { throw PageWorkspace.WorkspaceError.sourceChanged }
        return .init(source: before, timeline: timeline)
    }
    static func capture(_ url: URL) async throws -> Source {
        let task = Task.detached { try Source.capture(url) { try Task.checkCancellation() } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    func revalidated() async throws -> VideoProjectSourceBinding {
        let next = try await Self.observe(url: source.url)
        guard next.source == source, next.timeline == timeline else { throw PageWorkspace.WorkspaceError.sourceChanged }
        return next
    }
}

enum VideoProjectPublication {
    final class CleanupFailure: LocalizedError, @unchecked Sendable {
        let primary: Error
        private var cleanupError: Error
        var cleanup: Error { lock.lock(); defer { lock.unlock() }; return cleanupError }
        let temporary: URL
        private var retainedHandle: FileHandle?
        private var identity: [Int64]
        private let identityReader: (Int32) throws -> [Int64]
        private let lock = NSLock()
        init(primary: Error, cleanup: Error, retainedHandle: FileHandle?, temporary: URL,
             identity: [Int64], identityReader: ((Int32) throws -> [Int64])? = nil) {
            self.primary = primary; self.cleanupError = cleanup; self.retainedHandle = retainedHandle
            self.temporary = temporary; self.identity = identity; self.identityReader = identityReader ?? VideoProjectPublication.fileIdentity
        }
        var errorDescription: String? { primary.localizedDescription + "\n임시 프로젝트 정리 실패: " + cleanup.localizedDescription }
        func retryCleanup() throws {
            lock.lock(); defer { lock.unlock() }
            if identity.isEmpty {
                guard let retainedHandle else { throw PageWorkspace.WorkspaceError.exportFailed }
                // The original owned FD, not a later pathname, supplies the
                // identity after a transient first fstat failure.
                identity = try identityReader(retainedHandle.fileDescriptor)
            }
            if let retainedHandle {
                try retainedHandle.close()
                self.retainedHandle = nil
            }
            try VideoProjectPublication.removeOwnedTemporary(temporary, identity: identity)
        }
        func recordCleanup(_ error: Error) { lock.lock(); defer { lock.unlock() }; cleanupError = error }
    }
    private static func fileIdentity(_ descriptor: Int32) throws -> [Int64] {
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
        }
        return [Int64(value.st_dev), Int64(value.st_ino)]
    }
    private static func removeOwnedTemporary(_ url: URL, identity: [Int64]) throws {
        var status = stat()
        if lstat(url.path, &status) != 0 {
            if errno == ENOENT { return }
            throw PageWorkspace.WorkspaceError.exportFailed
        }
        guard status.st_mode & S_IFMT == S_IFREG,
              [Int64(status.st_dev), Int64(status.st_ino)] == identity else { throw PageWorkspace.WorkspaceError.exportFailed }
        try FileManager.default.removeItem(at: url)
    }
    static func write(_ data: Data, to destination: URL, source: VideoProjectSourceBinding.Source,
                      cancel: () throws -> Void = {},
                      _temporaryIdentity: ((Int32) throws -> [Int64])? = nil) throws {
        try cancel(); try source.validate(cancel: cancel)
        guard destination.isFileURL, !destination.path.utf8.contains(0), destination.standardizedFileURL != source.url else { throw PageWorkspace.WorkspaceError.destinationExists }
        var status = stat()
        guard lstat(destination.path, &status) != 0, errno == ENOENT else { throw PageWorkspace.WorkspaceError.destinationExists }
        var template = Array(destination.deletingLastPathComponent().appendingPathComponent(".blur-action-v3-XXXXXX").path.utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw PageWorkspace.WorkspaceError.exportFailed }
        let temporary = URL(fileURLWithPath: String(cString: template))
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let identityReader = _temporaryIdentity ?? fileIdentity
        let identity: [Int64]
        do { identity = try identityReader(fd) }
        catch {
            let primary = error
            let owner = CleanupFailure(primary: primary, cleanup: primary, retainedHandle: handle,
                temporary: temporary, identity: [], identityReader: identityReader)
            do { try owner.retryCleanup() }
            catch { owner.recordCleanup(error); throw owner }
            throw primary
        }
        var open = true, published = false
        do {
            for offset in stride(from: 0, to: data.count, by: 65_536) {
                try cancel(); try handle.write(contentsOf: data[offset..<min(offset + 65_536, data.count)])
            }
            try handle.close(); open = false
            try source.validate(cancel: cancel); try cancel()
            guard renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw PageWorkspace.WorkspaceError.destinationExists }
                throw PageWorkspace.WorkspaceError.exportFailed
            }
            published = true
        } catch {
            let primary = error
            do {
                if open { try handle.close(); open = false }
                if !published { try removeOwnedTemporary(temporary, identity: identity) }
            } catch { throw CleanupFailure(primary: primary, cleanup: error, retainedHandle: open ? handle : nil, temporary: temporary, identity: identity) }
            throw primary
        }
    }
}
