import Foundation
import Testing
@testable import BlurAction

/// Exact metadata/JSON boundaries only; these tests do not establish a decoder
/// clock, native playback, project source identity, or cross-platform parity.
@Suite(.serialized)
struct VideoTimelineTests {
    private typealias R = VideoTimeline.Rational
    private typealias S = VideoTimeline.Segment
    private typealias T = VideoTimeline.Track

    private func leadingTimeline() throws -> VideoTimeline {
        try VideoTimeline(assetDuration: R(39, 20), tracks: [
            T(id: 1, kind: "video", mediaTimescale: 12288, segments: [
                S(assetStart: R(0), assetDuration: R(1, 2), mediaStart: nil, rate: R(1)),
                S(assetStart: R(1, 2), assetDuration: R(13, 12), mediaStart: R(0), rate: R(1))]),
            T(id: 2, kind: "audio", mediaTimescale: 8000, segments: [
                S(assetStart: R(0), assetDuration: R(3, 4), mediaStart: nil, rate: R(1)),
                S(assetStart: R(3, 4), assetDuration: R(6, 5), mediaStart: R(0), rate: R(1))])])
    }

    private func encoded(_ timeline: VideoTimeline) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(timeline)
    }

    private func replacing(_ data: Data, _ old: String, _ new: String) throws -> Data {
        var text = try #require(String(data: data, encoding: .utf8))
        let range = try #require(text.range(of: old))
        text.replaceSubrange(range, with: new)
        return Data(text.utf8)
    }

    private func project(_ timeline: Data, version: String = "3") -> Data {
        var result = Data(("{\"version\":" + version + ",\"regions\":[{\"x\":0.125,\"y\":-1.25e-2}],\"drawings\":[{\"fillOpacity\":5e-1}],\"timeline\":").utf8)
        result.append(timeline)
        result.append(Data("}".utf8))
        return result
    }

    @Test
    func explicitGapAndAudioSuffixRoundTripWithoutChangingFractions() throws {
        let original = try leadingTimeline()
        let bytes = try encoded(original)
        let restored = try VideoTimeline.decode(bytes)
        #expect(restored == original)
        #expect(try encoded(restored) == bytes)
        let expectedAssetDuration = try R(39, 20)
        #expect(restored.assetDuration == expectedAssetDuration)
        #expect(restored.tracks[0].segments[0].mediaStart == nil)
        let expectedVideoStart = try R(1, 2)
        #expect(restored.tracks[0].segments[1].assetStart == expectedVideoStart)
        let expectedAudioStart = try R(3, 4)
        #expect(restored.tracks[1].segments[1].assetStart == expectedAudioStart)
        let expectedVideoDuration = try R(13, 12)
        #expect(restored.tracks[0].segments[1].assetDuration == expectedVideoDuration)
    }

    @Test(arguments: [Int64.min, Int64(-1), Int64(0), Int64(1), Int64.max])
    func canonicalRationalPreservesFullSignedInt64(numerator: Int64) throws {
        let value = try R(numerator)
        let data = try JSONEncoder().encode(value)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object["numerator"] == String(numerator))
        #expect(object["denominator"] == "1")
        #expect(try JSONDecoder().decode(R.self, from: data) == value)
    }

    @Test(arguments: ["01", "+1", "-0", "1e0", " 1", "9223372036854775808", "-9223372036854775809"])
    func noncanonicalOrOverflowingRationalStringsAreRejected(numerator: String) {
        let data = Data(("{\"numerator\":\"" + numerator + "\",\"denominator\":\"1\"}").utf8)
        #expect(throws: VideoTimeline.ValidationError.self) { try JSONDecoder().decode(R.self, from: data) }
    }

    @Test
    func nonpositiveAndNonreducedDenominatorsAndNumericRationalsAreRejected() throws {
        for data in [#"{"numerator":"1","denominator":"0"}"#,
                     #"{"numerator":"1","denominator":"-1"}"#,
                     #"{"numerator":"2","denominator":"4"}"#,
                     #"{"numerator":"0","denominator":"2"}"#,
                     #"{"numerator":"1","denominator":"9223372036854775808"}"#] {
            #expect(throws: VideoTimeline.ValidationError.self) { try JSONDecoder().decode(R.self, from: Data(data.utf8)) }
        }
        let raw = try encoded(leadingTimeline())
        let numeric = try replacing(raw, "\"numerator\":\"39\"", "\"numerator\":39")
        #expect(throws: DecodingError.self) { try VideoTimeline.decode(numeric) }
    }

    @Test
    func mandatoryNullableAndUnknownNestedKeysAreStrict() throws {
        let raw = try encoded(leadingTimeline())
        let missingNull = try replacing(raw, "\"mediaStart\":null,", "")
        #expect(throws: VideoTimeline.ValidationError.self) { try VideoTimeline.decode(missingNull) }
        for (old, new) in [
            ("\"basis\":\"asset-presentation\"", "\"basis\":\"asset-presentation\",\"rawOrigin\":0"),
            ("\"id\":1", "\"id\":1,\"nativeClock\":0"),
            ("\"mediaStart\":null", "\"mediaStart\":null,\"pts\":0"),
            ("\"numerator\":\"39\"", "\"numerator\":\"39\",\"epoch\":\"0\"")
        ] {
            let altered = try replacing(raw, old, new)
            #expect(throws: VideoTimeline.ValidationError.self) { try VideoTimeline.decode(altered) }
        }
        let wrongBasis = try replacing(raw, "asset-presentation", "qt-origin")
        #expect(throws: VideoTimeline.ValidationError.self) { try VideoTimeline.decode(wrongBasis) }
    }

    @Test
    func strictTimelineEntryRejectsDecimalsExponentsAndBooleanIntegerFields() throws {
        let raw = try encoded(leadingTimeline())
        for (old, new) in [
            ("\"version\":1", "\"version\":1.0"),
            ("\"version\":1", "\"version\":1e0"),
            ("\"id\":1", "\"id\":1.0"),
            ("\"id\":1", "\"id\":1e0"),
            ("\"mediaTimescale\":12288", "\"mediaTimescale\":12288.0"),
            ("\"mediaTimescale\":12288", "\"mediaTimescale\":12288e0")
        ] {
            let altered = try replacing(raw, old, new)
            #expect(throws: VideoTimeline.ValidationError.self) { try VideoTimeline.decode(altered) }
            #expect(throws: ProjectJSONTokens.ValidationError.invalidTimeline) { try ProjectJSONTokens.inspect(project(altered)) }
        }
        let boolean = try replacing(raw, "\"id\":1", "\"id\":true")
        #expect(throws: DecodingError.self) { try VideoTimeline.decode(boolean) }
        #expect(throws: ProjectJSONTokens.ValidationError.invalidTimeline) { try ProjectJSONTokens.inspect(project(boolean)) }
    }

    @Test
    func standaloneTimelineRejectsDuplicateEscapedKeysBeforeCodableCollapsesThem() throws {
        let original = try leadingTimeline()
        let raw = try encoded(original)
        #expect(try VideoTimeline.decode(raw) == original)
        for (old, new) in [
            ("\"version\":1", "\"version\":1,\"\\u0076ersion\":1"),
            ("\"id\":1", "\"id\":1,\"\\u0069d\":1"),
            ("\"numerator\":\"39\"", "\"numerator\":\"39\",\"\\u006eumerator\":\"39\"")
        ] {
            let duplicate = try replacing(raw, old, new)
            #expect(throws: ProjectJSONTokens.ValidationError.invalidJSON) { try VideoTimeline.decode(duplicate) }
        }
    }

    @Test
    func genericObjectGateRequiresNoVersionAndNeverCallsTimelineDecoders() throws {
        let noVersion = Data(#"{"edits":[{"timeline":{"version":1.0},"x":0.125}]}"#.utf8)
        try ProjectJSONTokens.validateObject(noVersion)
        #expect(throws: ProjectJSONTokens.ValidationError.invalidVersion) { try ProjectJSONTokens.inspect(noVersion) }
        let invalidTimeline = Data(#"{"version":3,"timeline":[],"x":0.1}"#.utf8)
        try ProjectJSONTokens.validateObject(invalidTimeline)
        #expect(throws: ProjectJSONTokens.ValidationError.invalidTimeline) { try ProjectJSONTokens.inspect(invalidTimeline) }
        let decimalVersion = Data(#"{"version":3.0,"timeline":null}"#.utf8)
        try ProjectJSONTokens.validateObject(decimalVersion)
        #expect(throws: ProjectJSONTokens.ValidationError.invalidVersion) { try ProjectJSONTokens.inspect(decimalVersion) }
        var limits = ProjectJSONTokens.Limits()
        limits.maxBytes = 2
        try ProjectJSONTokens.validateObject(Data("{}".utf8), limits: limits)
        #expect(throws: ProjectJSONTokens.ValidationError.resourceLimit) {
            try ProjectJSONTokens.validateObject(Data("{} ".utf8), limits: limits)
        }
        #expect(throws: ProjectJSONTokens.ValidationError.invalidJSON) {
            try ProjectJSONTokens.validateObject(Data(#"{"x":1,"\u0078":1}"#.utf8))
        }
    }

    @Test
    func invalidTracksEmptyRatesAndPositiveMetadataRateHaveSeparateMeanings() throws {
        let base = try leadingTimeline()
        #expect(throws: VideoTimeline.ValidationError.self) {
            try VideoTimeline(assetDuration: base.assetDuration, tracks: Array(base.tracks.reversed()))
        }
        #expect(throws: VideoTimeline.ValidationError.self) {
            try VideoTimeline(assetDuration: base.assetDuration, tracks: [base.tracks[0], base.tracks[0]])
        }
        #expect(throws: VideoTimeline.ValidationError.self) {
            try T(id: 0, kind: "video", mediaTimescale: 1, segments: base.tracks[0].segments)
        }
        #expect(throws: VideoTimeline.ValidationError.self) {
            try S(assetStart: R(0), assetDuration: R(1), mediaStart: nil, rate: R(2))
        }
        #expect(throws: VideoTimeline.ValidationError.self) {
            try S(assetStart: R(0), assetDuration: R(1), mediaStart: R(-1), rate: R(1))
        }
        // A positive rate is metadata. Acceptance does not claim runtime mapping support.
        let segment = try S(assetStart: R(0), assetDuration: R(1), mediaStart: R(0), rate: R(2))
        let rateMetadata = try VideoTimeline(assetDuration: R(1), tracks: [T(id: 1, kind: "video", mediaTimescale: 1, segments: [segment])])
        #expect(try VideoTimeline.decode(encoded(rateMetadata)) == rateMetadata)
    }

    @Test
    func descriptorResourceLimitsRejectWholeTracksWithoutTruncation() throws {
        let base = try leadingTimeline()
        #expect(throws: VideoTimeline.ValidationError.self) {
            try VideoTimeline(assetDuration: base.assetDuration, tracks: Array(repeating: base.tracks[0], count: 18))
        }
        #expect(throws: VideoTimeline.ValidationError.self) {
            try T(id: 1, kind: "video", mediaTimescale: 12288,
                  segments: Array(repeating: base.tracks[0].segments[1], count: 4097))
        }
        #expect(base.tracks.count == 2)
        #expect(base.tracks[0].segments.count == 2)
    }

    @Test
    func exactContiguityAtInt64MaxRejectsSubDoubleULPOverlapAndOverrun() throws {
        let maximum = Int64.max
        let segments = try [
            S(assetStart: R(0), assetDuration: R(maximum - 2, maximum), mediaStart: nil, rate: R(1)),
            S(assetStart: R(maximum - 2, maximum), assetDuration: R(1, maximum), mediaStart: R(0), rate: R(1)),
            S(assetStart: R(maximum - 1, maximum), assetDuration: R(1, maximum), mediaStart: R(1, maximum), rate: R(1))]
        let track = try T(id: maximum, kind: "video", mediaTimescale: maximum, segments: segments)
        let valid = try VideoTimeline(assetDuration: R(1), tracks: [track])
        #expect(try VideoTimeline.decode(encoded(valid)) == valid)
        var overlapping = segments
        overlapping[2] = try S(assetStart: R(maximum - 2, maximum), assetDuration: R(1, maximum), mediaStart: R(1, maximum), rate: R(1))
        #expect(throws: VideoTimeline.ValidationError.self) {
            try VideoTimeline(assetDuration: R(1), tracks: [T(id: maximum, kind: "video", mediaTimescale: maximum, segments: overlapping)])
        }
        var overrun = segments
        overrun[2] = try S(assetStart: R(maximum - 1, maximum), assetDuration: R(2, maximum), mediaStart: R(1, maximum), rate: R(1))
        #expect(throws: VideoTimeline.ValidationError.self) {
            try VideoTimeline(assetDuration: R(1), tracks: [T(id: maximum, kind: "video", mediaTimescale: maximum, segments: overrun)])
        }
    }

    @Test
    func mixedNearInt64DenominatorsRequire189BitBoundsWithoutOverflow() throws {
        let maximum = Int64.max
        let track = try T(id: 1, kind: "video", mediaTimescale: maximum, segments: [
            S(assetStart: R(0), assetDuration: R(1, maximum), mediaStart: nil, rate: R(1)),
            S(assetStart: R(1, maximum), assetDuration: R(maximum - 2, maximum - 1), mediaStart: R(0), rate: R(1))])
        let valid = try VideoTimeline(assetDuration: R(maximum - 1, maximum - 2), tracks: [track])
        #expect(try VideoTimeline.decode(encoded(valid)) == valid)
        #expect(throws: VideoTimeline.ValidationError.self) {
            try VideoTimeline(assetDuration: R(maximum - 1, maximum), tracks: [track])
        }
    }

    @Test
    func projectGatePreservesRawTimelineAndAllowsOrdinaryEditedDecimals() throws {
        let timeline = try encoded(leadingTimeline())
        let input = project(timeline)
        let result = try ProjectJSONTokens.inspect(input)
        #expect(result.version == 3)
        #expect(result.rawTimeline == timeline)
        let range = try #require(result.timelineRange)
        #expect(Data(input[range]) == timeline)
        #expect(Data(input[result.versionRange]) == Data("3".utf8))
        let decoy = try ProjectJSONTokens.inspect(Data(#"{"version":1,"edits":[{"timeline":{"version":1.0}},{"arrays":[[0.1,1e0,true,null]]}]}"#.utf8))
        #expect(decoy.timelineRange == nil)
        #expect(decoy.rawTimeline == nil)
    }

    @Test(arguments: ["3.0", "3e0", "3E+0", "true", "null", "\"3\"", "[]", "9223372036854775808"])
    func projectVersionCannotBeCoercedBeforeChoosingTheDecoder(token: String) throws {
        let timeline = try encoded(leadingTimeline())
        #expect(throws: ProjectJSONTokens.ValidationError.invalidVersion) { try ProjectJSONTokens.inspect(project(timeline, version: token)) }
    }

    @Test(arguments: [
        #"{"version":1,"\u0076ersion":1}"#,
        #"{"version":1,"edits":[{"x":0.1,"\u0078":0.2}]}"#,
        #"{"version":1,"edits":[[{"가":1,"\uac00":2}]]}"#,
        #"{"version":1,"edits":{"😀":1,"\uD83D\uDE00":2}}"#])
    func duplicateDecodedKeysAtAnyDepthAreRejected(input: String) {
        #expect(throws: ProjectJSONTokens.ValidationError.invalidJSON) { try ProjectJSONTokens.inspect(Data(input.utf8)) }
    }

    @Test
    func escapedRootKeysSelectOnlyTheActualRootSubtreeAndDuplicatesFail() throws {
        let timeline = try encoded(leadingTimeline())
        var input = Data(#"{"\u0076ersion":3,"edits":[{"timeline":{"version":1.0},"text":"quoted \" timeline { \\"}],"\u0074imeline":"#.utf8)
        input.append(timeline); input.append(Data("}".utf8))
        #expect(try ProjectJSONTokens.inspect(input).rawTimeline == timeline)
        var duplicate = project(timeline)
        duplicate.removeLast()
        duplicate.append(Data(",\"\\u0074imeline\":".utf8)); duplicate.append(timeline); duplicate.append(Data("}".utf8))
        #expect(throws: ProjectJSONTokens.ValidationError.invalidJSON) { try ProjectJSONTokens.inspect(duplicate) }
    }

    @Test(arguments: ["01", "-01", "1.", "1e", "1e+", "+1", ".1", "NaN", "Infinity", "--1", "truefalse"])
    func malformedJSONNumberGrammarIsRejected(token: String) {
        let input = Data(("{\"version\":1,\"edits\":" + token + "}").utf8)
        #expect(throws: ProjectJSONTokens.ValidationError.invalidJSON) { try ProjectJSONTokens.inspect(input) }
    }

    @Test
    func unicodeGrammarAndTrailingGarbageAreCheckedWithoutNormalizingKeys() throws {
        let distinct = Data(#"{"version":1,"\u00e9":1,"e\u0301":2,"text":"한글 😀 \uD83D\uDE00 \u0000 \/"}"#.utf8)
        #expect(try ProjectJSONTokens.inspect(distinct).version == 1)
        for input in [#"{"version":1,"text":"\uD800"}"#, #"{"version":1,"text":"\uDC00"}"#,
                      #"{"version":1,"text":"\uD800\u0041"}"#, #"{"version":1,"text":"\q"}"#,
                      #"{"version":1} true"#, #"{"version":1,"edits":[0,]}"#] {
            #expect(throws: ProjectJSONTokens.ValidationError.invalidJSON) { try ProjectJSONTokens.inspect(Data(input.utf8)) }
        }
        var invalidUTF8 = Data("{\"version\":1,\"text\":\"".utf8)
        invalidUTF8.append(contentsOf: [0xC0, 0xAF]); invalidUTF8.append(Data("\"}".utf8))
        #expect(throws: ProjectJSONTokens.ValidationError.invalidJSON) { try ProjectJSONTokens.inspect(invalidUTF8) }
    }

    @Test
    func parserDepthByteItemAndDecodedKeyLimitsFailClosed() throws {
        let deepest = "{\"version\":1,\"edits\":" + String(repeating: "[", count: 63) + "0" + String(repeating: "]", count: 63) + "}"
        #expect(try ProjectJSONTokens.inspect(Data(deepest.utf8)).version == 1)
        let tooDeep = "{\"version\":1,\"edits\":" + String(repeating: "[", count: 64) + "0" + String(repeating: "]", count: 64) + "}"
        #expect(throws: ProjectJSONTokens.ValidationError.resourceLimit) { try ProjectJSONTokens.inspect(Data(tooDeep.utf8)) }
        var limits = ProjectJSONTokens.Limits()
        limits.maxBytes = 12
        #expect(throws: ProjectJSONTokens.ValidationError.resourceLimit) { try ProjectJSONTokens.inspect(Data(#"{"version":1}"#.utf8), limits: limits) }
        limits = .init(); limits.maxValues = 3
        #expect(throws: ProjectJSONTokens.ValidationError.resourceLimit) { try ProjectJSONTokens.inspect(Data(#"{"version":1,"edits":[0,1]}"#.utf8), limits: limits) }
        limits = .init(); limits.maxMembers = 2
        #expect(throws: ProjectJSONTokens.ValidationError.resourceLimit) { try ProjectJSONTokens.inspect(Data(#"{"version":1,"edits":{"x":1}}"#.utf8), limits: limits) }
        limits = .init(); limits.maxKeyUTF8Bytes = 7
        #expect(try ProjectJSONTokens.inspect(Data(#"{"version":1,"\u0061\u0062\u0063\u0064\u0065\u0066\u0067":0}"#.utf8), limits: limits).version == 1)
        #expect(throws: ProjectJSONTokens.ValidationError.resourceLimit) { try ProjectJSONTokens.inspect(Data(#"{"version":1,"abcdefgh":0}"#.utf8), limits: limits) }
    }
}
