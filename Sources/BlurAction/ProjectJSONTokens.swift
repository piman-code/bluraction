import Foundation

/// Validate original project JSON before Codable can coerce numeric tokens or
/// collapse duplicate keys. This does not validate edits or approve a source.
enum ProjectJSONTokens {
    enum ValidationError: Error, Equatable {
        case invalidJSON, invalidVersion, invalidTimeline, resourceLimit
    }

    struct Limits {
        var maxBytes = 20 * 1024 * 1024
        var maxDepth = 64
        var maxValues = 2_000_000
        var maxMembers = 1_000_000
        var maxKeyUTF8Bytes = 4096
    }

    struct Inspection {
        let version: Int64
        /// Zero-based byte offsets into the original input, including the token.
        let versionRange: Range<Int>
        let timelineRange: Range<Int>?
        /// An unchanged copy of the original timeline bytes, never NSNumber JSON.
        let rawTimeline: Data?
    }

    /// Generic bounded object grammar/duplicate-key boundary. This entrypoint
    /// neither requires a version nor calls a project/timeline decoder.
    static func validateObject(_ data: Data, limits: Limits = Limits()) throws {
        var parser = try makeParser(data, limits: limits)
        try parser.parseRoot(captureRootFields: false)
    }

    private static func makeParser(_ data: Data, limits: Limits) throws -> Parser {
        guard limits.maxBytes > 0, limits.maxBytes <= 20 * 1024 * 1024,
              limits.maxDepth > 0, limits.maxDepth <= 64,
              limits.maxValues > 0, limits.maxValues <= 2_000_000,
              limits.maxMembers > 0, limits.maxMembers <= 1_000_000,
              limits.maxKeyUTF8Bytes > 0, limits.maxKeyUTF8Bytes <= 4096,
              data.count <= limits.maxBytes else { throw ValidationError.resourceLimit }
        guard String(data: data, encoding: .utf8) != nil else { throw ValidationError.invalidJSON }
        return Parser(bytes: Array(data), limits: limits)
    }

    static func inspect(_ data: Data, limits: Limits = Limits()) throws -> Inspection {
        var parser = try makeParser(data, limits: limits)
        try parser.parseRoot(captureRootFields: true)
        guard let versionRange = parser.versionRange else { throw ValidationError.invalidVersion }
        let versionBytes = parser.bytes[versionRange]
        // Syntax was already checked. Only an integer token, without decimal or
        // exponent spelling, may select a project decoder.
        guard !versionBytes.contains(46), !versionBytes.contains(69), !versionBytes.contains(101),
              let versionText = String(bytes: versionBytes, encoding: .utf8),
              let version = Int64(versionText) else { throw ValidationError.invalidVersion }
        let rawTimeline = parser.timelineRange.map { Data(parser.bytes[$0]) }
        if version == 3 {
            guard let rawTimeline else { throw ValidationError.invalidTimeline }
            do { _ = try VideoTimeline.decode(rawTimeline) }
            catch { throw ValidationError.invalidTimeline }
        }
        return Inspection(version: version, versionRange: versionRange,
                          timelineRange: parser.timelineRange, rawTimeline: rawTimeline)
    }

    private struct Parser {
        let bytes: [UInt8]
        let limits: Limits
        var index = 0
        var values = 0
        var members = 0
        var versionRange: Range<Int>?
        var timelineRange: Range<Int>?

        mutating func whitespace() {
            while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }

        mutating func parseRoot(captureRootFields: Bool) throws {
            whitespace()
            guard index < bytes.count, bytes[index] == 123 else { throw ValidationError.invalidJSON }
            _ = try value(depth: 0, root: captureRootFields)
            whitespace()
            guard index == bytes.count else { throw ValidationError.invalidJSON }
        }

        mutating func value(depth: Int, root: Bool = false) throws -> Range<Int> {
            whitespace()
            guard index < bytes.count else { throw ValidationError.invalidJSON }
            values += 1
            guard values <= limits.maxValues else { throw ValidationError.resourceLimit }
            let start = index
            switch bytes[index] {
            case 123: try object(depth: depth, root: root)
            case 91: try array(depth: depth)
            case 34: _ = try string(key: false)
            case 116: try literal([116, 114, 117, 101])
            case 102: try literal([102, 97, 108, 115, 101])
            case 110: try literal([110, 117, 108, 108])
            case 45, 48...57: try number()
            default: throw ValidationError.invalidJSON
            }
            return start..<index
        }

        mutating func object(depth: Int, root: Bool) throws {
            guard depth < limits.maxDepth else { throw ValidationError.resourceLimit }
            index += 1
            whitespace()
            if consume(125) { return }
            // UTF8 bytes preserve distinct Unicode spellings while escaped forms
            // of the same decoded key compare identically.
            var keys = Set<Data>()
            while true {
                whitespace()
                guard index < bytes.count, bytes[index] == 34 else { throw ValidationError.invalidJSON }
                let keyRange = try string(key: true)
                let decoded: String
                do { decoded = try JSONDecoder().decode(String.self, from: Data(bytes[keyRange])) }
                catch { throw ValidationError.invalidJSON }
                let key = Data(decoded.utf8)
                guard key.count <= limits.maxKeyUTF8Bytes else { throw ValidationError.resourceLimit }
                guard keys.insert(key).inserted else { throw ValidationError.invalidJSON }
                members += 1
                guard members <= limits.maxMembers else { throw ValidationError.resourceLimit }
                whitespace()
                guard consume(58) else { throw ValidationError.invalidJSON }
                let range = try value(depth: depth + 1)
                if root {
                    if key == Data("version".utf8) { versionRange = range }
                    if key == Data("timeline".utf8) { timelineRange = range }
                }
                whitespace()
                if consume(125) { return }
                guard consume(44) else { throw ValidationError.invalidJSON }
            }
        }

        mutating func array(depth: Int) throws {
            guard depth < limits.maxDepth else { throw ValidationError.resourceLimit }
            index += 1
            whitespace()
            if consume(93) { return }
            while true {
                _ = try value(depth: depth + 1)
                whitespace()
                if consume(93) { return }
                guard consume(44) else { throw ValidationError.invalidJSON }
            }
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        mutating func literal(_ spelling: [UInt8]) throws {
            guard bytes.count - index >= spelling.count else { throw ValidationError.invalidJSON }
            for byte in spelling {
                guard consume(byte) else { throw ValidationError.invalidJSON }
            }
        }

        mutating func number() throws {
            _ = consume(45)
            guard index < bytes.count else { throw ValidationError.invalidJSON }
            if consume(48) {
                if index < bytes.count, (48...57).contains(bytes[index]) { throw ValidationError.invalidJSON }
            } else {
                guard (49...57).contains(bytes[index]) else { throw ValidationError.invalidJSON }
                digits()
            }
            if consume(46) {
                guard index < bytes.count, (48...57).contains(bytes[index]) else { throw ValidationError.invalidJSON }
                digits()
            }
            if consume(69) || consume(101) {
                if !consume(43) { _ = consume(45) }
                guard index < bytes.count, (48...57).contains(bytes[index]) else { throw ValidationError.invalidJSON }
                digits()
            }
        }

        mutating func digits() {
            while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
        }

        mutating func string(key: Bool) throws -> Range<Int> {
            let start = index
            guard consume(34) else { throw ValidationError.invalidJSON }
            while index < bytes.count {
                if key, index - start > limits.maxKeyUTF8Bytes * 6 + 2 { throw ValidationError.resourceLimit }
                let byte = bytes[index]
                index += 1
                if byte == 34 { return start..<index }
                guard byte >= 32 else { throw ValidationError.invalidJSON }
                if byte != 92 { continue }
                guard index < bytes.count else { throw ValidationError.invalidJSON }
                let escape = bytes[index]
                index += 1
                if [34, 92, 47, 98, 102, 110, 114, 116].contains(escape) { continue }
                guard escape == 117 else { throw ValidationError.invalidJSON }
                let code = try hex4()
                if (0xD800...0xDBFF).contains(code) {
                    guard consume(92), consume(117) else { throw ValidationError.invalidJSON }
                    let low = try hex4()
                    guard (0xDC00...0xDFFF).contains(low) else { throw ValidationError.invalidJSON }
                } else if (0xDC00...0xDFFF).contains(code) {
                    throw ValidationError.invalidJSON
                }
            }
            throw ValidationError.invalidJSON
        }

        mutating func hex4() throws -> UInt16 {
            guard bytes.count - index >= 4 else { throw ValidationError.invalidJSON }
            var code: UInt16 = 0
            for _ in 0..<4 {
                let byte = bytes[index]
                let digit: UInt16
                switch byte {
                case 48...57: digit = UInt16(byte - 48)
                case 65...70: digit = UInt16(byte - 65 + 10)
                case 97...102: digit = UInt16(byte - 97 + 10)
                default: throw ValidationError.invalidJSON
                }
                code = code * 16 + digit
                index += 1
            }
            return code
        }
    }
}
