import Foundation

/// Exact v3 video metadata boundary. This does not choose a decoder origin or
/// approve a source. No ProjectFile/AVFoundation integration is present yet.
/// Standalone builds must also compile ProjectJSONTokens.swift.
struct VideoTimeline: Codable, Equatable {
    enum ValidationError: Error { case invalid(String) }
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    private static func keys(_ decoder: Decoder, _ expected: [String]) throws -> KeyedDecodingContainer<Key> {
        let values = try decoder.container(keyedBy: Key.self)
        guard Set(values.allKeys.map(\.stringValue)) == Set(expected) else {
            throw ValidationError.invalid("Missing or unsupported video timeline fields")
        }
        return values
    }

    struct Rational: Codable, Equatable {
        let numerator: Int64
        let denominator: Int64
        init(_ numerator: Int64, _ denominator: Int64 = 1) throws {
            guard denominator > 0 else { throw ValidationError.invalid("Nonpositive denominator") }
            var a = numerator.magnitude, b = UInt64(denominator)
            while b != 0 { let remainder = a % b; a = b; b = remainder }
            guard a == 1 else { throw ValidationError.invalid("Rational must be reduced") }
            self.numerator = numerator; self.denominator = denominator
        }
        private static func integer(_ text: String) throws -> Int64 {
            let bytes = Array(text.utf8)
            guard !bytes.isEmpty && bytes.count <= 20 else { throw ValidationError.invalid("Int64 decimal string required") }
            if text != "0" {
                let offset = bytes[0] == 45 ? 1 : 0
                guard offset < bytes.count, (49...57).contains(bytes[offset]),
                      bytes.dropFirst(offset + 1).allSatisfy({ (48...57).contains($0) }) else {
                    throw ValidationError.invalid("Noncanonical decimal string")
                }
            }
            guard let number = Int64(text) else { throw ValidationError.invalid("Decimal outside Int64") }
            return number
        }
        init(from decoder: Decoder) throws {
            let fields = try VideoTimeline.keys(decoder, ["numerator", "denominator"])
            try self.init(Self.integer(fields.decode(String.self, forKey: Key("numerator"))),
                          Self.integer(fields.decode(String.self, forKey: Key("denominator"))))
        }
        func encode(to encoder: Encoder) throws {
            var fields = encoder.container(keyedBy: Key.self)
            try fields.encode(String(numerator), forKey: Key("numerator"))
            try fields.encode(String(denominator), forKey: Key("denominator"))
        }
    }

    struct Segment: Codable, Equatable {
        let assetStart: Rational
        let assetDuration: Rational
        let mediaStart: Rational?
        let rate: Rational
        init(assetStart: Rational, assetDuration: Rational, mediaStart: Rational?, rate: Rational) throws {
            guard assetStart.numerator >= 0, assetDuration.numerator > 0, rate.numerator > 0,
                  mediaStart.map({ $0.numerator >= 0 }) ?? true else { throw ValidationError.invalid("Invalid segment value") }
            guard mediaStart != nil || (rate.numerator == 1 && rate.denominator == 1) else {
                throw ValidationError.invalid("Empty segment rate must be one")
            }
            self.assetStart = assetStart; self.assetDuration = assetDuration; self.mediaStart = mediaStart; self.rate = rate
        }
        init(from decoder: Decoder) throws {
            let fields = try VideoTimeline.keys(decoder, ["assetStart", "assetDuration", "mediaStart", "rate"])
            try self.init(assetStart: fields.decode(Rational.self, forKey: Key("assetStart")),
                          assetDuration: fields.decode(Rational.self, forKey: Key("assetDuration")),
                          mediaStart: fields.decodeIfPresent(Rational.self, forKey: Key("mediaStart")),
                          rate: fields.decode(Rational.self, forKey: Key("rate")))
        }
        func encode(to encoder: Encoder) throws {
            var fields = encoder.container(keyedBy: Key.self)
            try fields.encode(assetStart, forKey: Key("assetStart")); try fields.encode(assetDuration, forKey: Key("assetDuration"))
            // Required nullable key: encode(null), never encodeIfPresent omission.
            try fields.encode(mediaStart, forKey: Key("mediaStart")); try fields.encode(rate, forKey: Key("rate"))
        }
    }

    struct Track: Codable, Equatable {
        let id: Int64
        let kind: String
        let mediaTimescale: Int64
        let segments: [Segment]
        init(id: Int64, kind: String, mediaTimescale: Int64, segments: [Segment]) throws {
            guard id > 0, mediaTimescale > 0, ["video", "audio"].contains(kind),
                  (1...4096).contains(segments.count), segments.contains(where: { $0.mediaStart != nil }) else {
                throw ValidationError.invalid("Invalid video track")
            }
            self.id = id; self.kind = kind; self.mediaTimescale = mediaTimescale; self.segments = segments
        }
        init(from decoder: Decoder) throws {
            let fields = try VideoTimeline.keys(decoder, ["id", "kind", "mediaTimescale", "segments"])
            try self.init(id: fields.decode(Int64.self, forKey: Key("id")),
                          kind: fields.decode(String.self, forKey: Key("kind")),
                          mediaTimescale: fields.decode(Int64.self, forKey: Key("mediaTimescale")),
                          segments: fields.decode([Segment].self, forKey: Key("segments")))
        }
        func encode(to encoder: Encoder) throws {
            var fields = encoder.container(keyedBy: Key.self)
            try fields.encode(id, forKey: Key("id")); try fields.encode(kind, forKey: Key("kind"))
            try fields.encode(mediaTimescale, forKey: Key("mediaTimescale")); try fields.encode(segments, forKey: Key("segments"))
        }
    }

    let version: Int64
    let basis: String
    let assetDuration: Rational
    let tracks: [Track]
    init(version: Int64 = 1, basis: String = "asset-presentation", assetDuration: Rational, tracks: [Track]) throws {
        guard version == 1, basis == "asset-presentation", assetDuration.numerator > 0,
              (1...17).contains(tracks.count), tracks.filter({ $0.kind == "video" }).count == 1 else {
            throw ValidationError.invalid("Invalid asset timeline")
        }
        var previousID: Int64 = 0
        for track in tracks {
            guard track.id > previousID else { throw ValidationError.invalid("Tracks must ascend by container ID") }
            previousID = track.id
            var previous: Segment?
            for segment in track.segments {
                if let previous {
                    guard try Self.equalSum(segment.assetStart, previous.assetStart, previous.assetDuration) else {
                        throw ValidationError.invalid("Segment discontinuity; encode gaps explicitly")
                    }
                } else if segment.assetStart.numerator != 0 { throw ValidationError.invalid("Track must start at zero") }
                guard try Self.sumWithin(segment.assetStart, segment.assetDuration, assetDuration) else {
                    throw ValidationError.invalid("Segment exceeds asset duration")
                }
                previous = segment
            }
        }
        self.version = version; self.basis = basis; self.assetDuration = assetDuration; self.tracks = tracks
    }
    init(from decoder: Decoder) throws {
        let fields = try Self.keys(decoder, ["version", "basis", "assetDuration", "tracks"])
        try self.init(version: fields.decode(Int64.self, forKey: Key("version")),
                      basis: fields.decode(String.self, forKey: Key("basis")),
                      assetDuration: fields.decode(Rational.self, forKey: Key("assetDuration")),
                      tracks: fields.decode([Track].self, forKey: Key("tracks")))
    }
    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: Key.self)
        try fields.encode(version, forKey: Key("version")); try fields.encode(basis, forKey: Key("basis"))
        try fields.encode(assetDuration, forKey: Key("assetDuration")); try fields.encode(tracks, forKey: Key("tracks"))
    }

    /// Standalone timeline JSON entrypoint. All numeric fields here are strict
    /// integers; duplicate keys and decimal/exponent tokens are rejected before
    /// JSONDecoder can coerce 1.0 into Int64. A nested v3 integration must retain
    /// this raw-token check for its timeline subtree; Codable alone is insufficient.
    static func decode(_ data: Data) throws -> VideoTimeline {
        // The generic object validator has no decoder callbacks. Thus project
        // inspect -> timeline decode -> object validate cannot recurse.
        try ProjectJSONTokens.validateObject(data)
        let bytes = Array(data)
        var index = 0, inString = false, escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
                index += 1; continue
            }
            if byte == 34 { inString = true; index += 1; continue }
            if byte == 45 || (48...57).contains(byte) {
                let first = index
                while index < bytes.count && ![9, 10, 13, 32, 44, 58, 91, 93, 123, 125].contains(bytes[index]) { index += 1 }
                let token = bytes[first..<index]
                if token.contains(46) || token.contains(69) || token.contains(101) {
                    throw ValidationError.invalid("Timeline integer encoded as JSON decimal/exponent")
                }
                continue
            }
            index += 1
        }
        return try JSONDecoder().decode(VideoTimeline.self, from: data)
    }

    // Int128 requires newer macOS. Each operand <= Int64.max, so three-factor
    // products occupy at most189 bits, sums at most190; four UInt64 limbs suffice.
    private struct UInt256: Comparable {
        var limbs: [UInt64] // little-endian, exactly four
        init(_ value: UInt64) { limbs = [value, 0, 0, 0] }
        func multiplied(by value: UInt64) throws -> UInt256 {
            var result = UInt256(0), carry: UInt64 = 0
            for index in 0..<4 {
                let product = limbs[index].multipliedFullWidth(by: value)
                let low = product.low.addingReportingOverflow(carry)
                let high = product.high.addingReportingOverflow(low.overflow ? 1 : 0)
                guard !high.overflow else { throw ValidationError.invalid("Exact arithmetic overflow") }
                result.limbs[index] = low.partialValue; carry = high.partialValue
            }
            guard carry == 0 else { throw ValidationError.invalid("Exact arithmetic overflow") }
            return result
        }
        func added(_ other: UInt256) throws -> UInt256 {
            var result = UInt256(0), carry: UInt64 = 0
            for index in 0..<4 {
                let sum = limbs[index].addingReportingOverflow(other.limbs[index])
                let extra = sum.partialValue.addingReportingOverflow(carry)
                result.limbs[index] = extra.partialValue
                carry = (sum.overflow || extra.overflow) ? 1 : 0
            }
            guard carry == 0 else { throw ValidationError.invalid("Exact arithmetic overflow") }
            return result
        }
        static func < (lhs: UInt256, rhs: UInt256) -> Bool {
            for index in (0..<4).reversed() {
                if lhs.limbs[index] != rhs.limbs[index] { return lhs.limbs[index] < rhs.limbs[index] }
            }
            return false
        }
    }
    private static func product(_ a: Int64, _ b: Int64, _ c: Int64) throws -> UInt256 {
        guard a >= 0, b > 0, c > 0 else { throw ValidationError.invalid("Invalid exact arithmetic operand") }
        return try UInt256(UInt64(a)).multiplied(by: UInt64(b)).multiplied(by: UInt64(c))
    }
    private static func equalSum(_ current: Rational, _ start: Rational, _ length: Rational) throws -> Bool {
        let left = try product(current.numerator, start.denominator, length.denominator)
        let first = try product(start.numerator, current.denominator, length.denominator)
        let second = try product(length.numerator, current.denominator, start.denominator)
        return try left == first.added(second)
    }
    private static func sumWithin(_ start: Rational, _ length: Rational, _ bound: Rational) throws -> Bool {
        let first = try product(start.numerator, length.denominator, bound.denominator)
        let second = try product(length.numerator, start.denominator, bound.denominator)
        let right = try product(bound.numerator, start.denominator, length.denominator)
        return try first.added(second) <= right
    }
}
