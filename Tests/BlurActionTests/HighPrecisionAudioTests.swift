import Testing
import Foundation
import AVFoundation
import AudioToolbox
import CryptoKit
@testable import BlurAction

/// Native full-file checks of independently authored, nonperiodic high precision
/// audio. A 16-bit decode cannot establish these sample preservation properties.
@Suite(.serialized)
final class HighPrecisionAudioTests {
    private enum Encoding: String { case pcm24, pcm32, float32, alac24 }
    private struct Span { var start: CMTime; var end: CMTime }
    private struct Marker {
        let pts: CMTime
        let outputPTS: CMTime
        let duration: CMTime
        let outputDuration: CMTime
        let attachments: [String: String]
    }
    private struct Scan {
        let sha: String
        let bytes: Int
        let samples: Int
        let spans: [Span]
        let markers: [Marker]
    }
    private struct Format {
        let codec: AudioFormatID
        let rate: Double
        let channels: UInt32
        let bits: UInt32
        let flags: AudioFormatFlags
        let bytesPerFrame: UInt32
        let framesPerPacket: UInt32
        let layout: Data?
        let cookie: Data?
    }
    private let rate = 48_000
    private let channels = 2
    private let frames = 48_000

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func finite(_ time: CMTime) -> Bool {
        time.isValid && time.isNumeric && time.timescale > 0 && time.seconds.isFinite
    }
    private func sameTime(_ a: CMTime, _ b: CMTime) -> Bool {
        if finite(a) && finite(b) { return CMTimeCompare(a, b) == 0 }
        return a.value == b.value && a.timescale == b.timescale &&
            a.epoch == b.epoch && a.flags == b.flags
    }
    private func add(_ span: Span, to spans: inout [Span]) throws {
        try #require(finite(span.start))
        try #require(finite(span.end))
        try #require(CMTimeCompare(span.end, span.start) >= 0)
        if CMTimeCompare(span.end, span.start) == 0 { return }
        if let last = spans.last {
            try #require(CMTimeCompare(span.start, last.end) >= 0)
            if CMTimeCompare(span.start, last.end) == 0 {
                spans[spans.count - 1].end = span.end
                return
            }
        }
        spans.append(span)
    }
    private func equalSpans(_ a: [Span], _ b: [Span], label: String) throws {
        try #require(a.count == b.count, "Complete native interval inventory: \(label)")
        for (before, after) in zip(a, b) {
            #expect(CMTimeCompare(before.start, after.start) == 0, "Exact interval start: \(label)")
            #expect(CMTimeCompare(before.end, after.end) == 0, "Exact interval end: \(label)")
        }
    }
    private func attachments(_ sample: CMSampleBuffer) -> [String: String] {
        let keys: [(String, CFString)] = [
            ("trimStart", kCMSampleBufferAttachmentKey_TrimDurationAtStart),
            ("trimEnd", kCMSampleBufferAttachmentKey_TrimDurationAtEnd),
            ("emptyMedia", kCMSampleBufferAttachmentKey_EmptyMedia),
            ("speedMultiplier", kCMSampleBufferAttachmentKey_SpeedMultiplier),
            ("resetDecoder", kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding),
            ("endsPreviousDuration", kCMSampleBufferAttachmentKey_EndsPreviousSampleDuration),
            ("drainAfterDecoding", kCMSampleBufferAttachmentKey_DrainAfterDecoding),
        ]
        return Dictionary(uniqueKeysWithValues: keys.map { name, key in
            let value = CMGetAttachment(sample, key: key, attachmentModeOut: nil)
            return (name, value.map { String(describing: $0) } ?? "absent")
        })
    }
    private func equalMarkers(_ a: [Marker], _ b: [Marker], label: String) throws {
        try #require(a.count == b.count, "Complete marker inventory: \(label)")
        for (before, after) in zip(a, b) {
            #expect(sameTime(before.pts, after.pts), "Marker PTS/state: \(label)")
            #expect(sameTime(before.outputPTS, after.outputPTS), "Marker output PTS/state: \(label)")
            #expect(sameTime(before.duration, after.duration), "Marker duration/state: \(label)")
            #expect(sameTime(before.outputDuration, after.outputDuration), "Marker output duration/state: \(label)")
            #expect(before.attachments == after.attachments, "Marker attachments: \(label)")
        }
    }
    /// AVAudioFormat.isEqual documents standard mono/stereo layout tags as
    /// functionally equivalent to nil. Admit only the exact canonical two-
    /// channel stereo header here; custom tags, bitmaps and descriptions retain
    /// their byte equality requirement. Independent per-channel waveform truth
    /// still requires original L/R sample order throughout the entire file.
    private func sameLayout(_ a: Data?, _ b: Data?, channelCount: UInt32) -> Bool {
        if a == b { return true }
        guard channelCount == 2 else { return false }
        var canonical = Data()
        for word in [UInt32(kAudioChannelLayoutTag_Stereo), UInt32(0), UInt32(0)] {
            var little = word.littleEndian
            withUnsafeBytes(of: &little) { canonical.append(contentsOf: $0) }
        }
        return (a == nil && b == canonical) || (a == canonical && b == nil)
    }
    private func format(_ track: AVAssetTrack) async throws -> Format {
        let descriptions = try await track.load(.formatDescriptions)
        try #require(descriptions.count == 1, "These authored sources have exactly one audio format")
        let description = try #require(descriptions.first)
        try #require(CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio)
        let basic = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)).pointee
        var layoutSize = 0, cookieSize = 0
        let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &layoutSize)
        let cookie = CMAudioFormatDescriptionGetMagicCookie(description, sizeOut: &cookieSize)
        return Format(codec: basic.mFormatID, rate: basic.mSampleRate, channels: basic.mChannelsPerFrame,
                      bits: basic.mBitsPerChannel, flags: basic.mFormatFlags,
                      bytesPerFrame: basic.mBytesPerFrame, framesPerPacket: basic.mFramesPerPacket,
                      layout: layout.map { Data(bytes: $0, count: layoutSize) },
                      cookie: cookie.map { Data(bytes: $0, count: cookieSize) })
    }

    /// nil settings scan original PCM bytes/ALAC packets. Non-nil settings demand
    /// native interleaved little endian Int32 or Float32 and scan through EOF.
    private func scan(_ asset: AVAsset, track: AVAssetTrack, decoded: Bool,
                      floating: Bool, label: String) throws -> Scan {
        let reader = try AVAssetReader(asset: asset)
        defer { if reader.status == .reading { reader.cancelReading() } }
        let settings: [String: Any]? = decoded ? [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: floating, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false] : nil
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        try #require(reader.canAdd(output), "Native reader can add: \(label)")
        reader.add(output)
        try #require(reader.startReading(), "Native reader starts: \(label)")
        var hash = SHA256(), bytes = 0, samples = 0
        var spans: [Span] = [], markers: [Marker] = []
        for _ in 0..<30_000 {
            guard let sample = output.copyNextSampleBuffer() else { break }
            let count = CMSampleBufferGetNumSamples(sample)
            try #require(count >= 0, "Nonnegative native sample count: \(label)")
            let start = CMSampleBufferGetOutputPresentationTimeStamp(sample)
            let duration = CMSampleBufferGetOutputDuration(sample)
            if count == 0 {
                let payload = CMSampleBufferGetDataBuffer(sample).map { CMBlockBufferGetDataLength($0) } ?? 0
                try #require(payload == 0, "Zero sample markers contain no payload: \(label)")
                markers.append(Marker(pts: CMSampleBufferGetPresentationTimeStamp(sample), outputPTS: start,
                                      duration: CMSampleBufferGetDuration(sample), outputDuration: duration,
                                      attachments: attachments(sample)))
                if decoded {
                    try #require(finite(start), "Decoded marker start is finite: \(label)")
                    try #require(finite(duration), "Decoded marker duration is finite: \(label)")
                    try add(Span(start: start, end: CMTimeAdd(start, duration)), to: &spans)
                }
                continue
            }
            try #require(finite(start), "Native media start is finite: \(label)")
            try #require(finite(duration), "Native media duration is finite: \(label)")
            try #require(CMTimeCompare(duration, .zero) > 0, "Positive media duration: \(label)")
            if decoded { try add(Span(start: start, end: CMTimeAdd(start, duration)), to: &spans) }
            let block = try #require(CMSampleBufferGetDataBuffer(sample), "Native audio data: \(label)")
            let size = CMBlockBufferGetDataLength(block)
            try #require(size > 0 && size <= 16 * 1024 * 1024)
            try #require(bytes <= 64 * 1024 * 1024 - size, "Bounded entire file scan: \(label)")
            var data = Data(count: size)
            let status = data.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!)
            }
            try #require(status == noErr)
            if decoded {
                let description = try #require(CMSampleBufferGetFormatDescription(sample))
                let basic = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)).pointee
                try #require(basic.mFormatID == kAudioFormatLinearPCM)
                try #require(basic.mSampleRate == Double(rate))
                try #require(basic.mChannelsPerFrame == UInt32(channels))
                try #require(basic.mBitsPerChannel == 32)
                try #require(basic.mBytesPerFrame == UInt32(channels * 4))
                try #require(basic.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0)
                try #require(basic.mFormatFlags & kAudioFormatFlagIsBigEndian == 0)
                let isFloat = basic.mFormatFlags & kAudioFormatFlagIsFloat != 0
                try #require(isFloat == floating, "Actual native Float32/Int32 format: \(label)")
                if !floating { try #require(basic.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0) }
                try #require(size == count * Int(basic.mBytesPerFrame), "Every channel of every decoded frame: \(label)")
            }
            hash.update(data: data); bytes += size; samples += count
        }
        try #require(reader.status == .completed, "Complete native EOF is mandatory: \(label)")
        try #require(samples > 0 && bytes > 0)
        return Scan(sha: hash.finalize().map { String(format: "%02x", $0) }.joined(),
                    bytes: bytes, samples: samples, spans: spans, markers: markers)
    }

    private func emptyIntervals(_ track: AVAssetTrack) async throws -> [Span] {
        var result: [Span] = []
        for segment in try await track.load(.segments) where segment.isEmpty {
            let target = segment.timeMapping.target
            try add(Span(start: target.start, end: CMTimeRangeGetEnd(target)), to: &result)
        }
        return result
    }

    /// Authored signed 24-bit samples use nonzero low 8 bits; signed 32-bit
    /// samples use nonzero low 16 bits. Original raw PCM32 must remain exact;
    /// its native converted-readback oracle separately predicts the observed
    /// Float32 normalization round trip without using any decoded source data.
    /// Float32 bit patterns vary their lowest mantissa bits, so narrowing the
    /// original payload or the other decoded precision oracles is detectable.
    private func authored(_ encoding: Encoding) -> (raw: Data, decoded: Data, format: String, codec: String) {
        var raw = Data(), expected = Data()
        for frame in 0..<frames {
            for channel in 0..<channels {
                if encoding == .float32 {
                    let magnitude = UInt32(0x3E800001) + UInt32(frame * 13 + channel * 7)
                    var bits = (channel == 0 ? magnitude : magnitude | 0x80000000).littleEndian
                    withUnsafeBytes(of: &bits) { raw.append(contentsOf: $0); expected.append(contentsOf: $0) }
                } else if encoding == .pcm32 {
                    let value = Int32(-900_000_001 + frame * 37_011 + channel * 97)
                    var original = value.littleEndian
                    withUnsafeBytes(of: &original) { raw.append(contentsOf: $0) }
                    // Actual native source readback exposed this conversion
                    // boundary before export. Keep all original 32 bits as a
                    // separate raw SHA oracle; do not call these converted
                    // samples evidence of 32-bit payload precision.
                    let normalized = Float(value) / Float(2_147_483_648.0)
                    var converted = Int32(normalized * Float(2_147_483_648.0)).littleEndian
                    withUnsafeBytes(of: &converted) { expected.append(contentsOf: $0) }
                } else {
                    let value = Int32(-4_000_001 + frame * 97 + channel * 11)
                    let packed = UInt32(bitPattern: value)
                    raw.append(UInt8(truncatingIfNeeded: packed))
                    raw.append(UInt8(truncatingIfNeeded: packed >> 8))
                    raw.append(UInt8(truncatingIfNeeded: packed >> 16))
                    var decoded = (value << 8).littleEndian
                    withUnsafeBytes(of: &decoded) { expected.append(contentsOf: $0) }
                }
            }
        }
        switch encoding {
        case .pcm24: return (raw, expected, "s24le", "pcm_s24le")
        case .pcm32: return (raw, expected, "s32le", "pcm_s32le")
        case .float32: return (raw, expected, "f32le", "pcm_f32le")
        case .alac24: return (raw, expected, "s24le", "alac")
        }
    }

    @MainActor
    private func compare(_ encoding: Encoding, ext: String) async throws {
        let folder = try VideoExportTests().directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let label = "\(encoding.rawValue).\(ext)"
        let truth = authored(encoding)
        let rawURL = folder.appendingPathComponent("authored.raw")
        try truth.raw.write(to: rawURL, options: .withoutOverwriting)
        let rawSHA = digest(truth.raw), expectedSHA = digest(truth.decoded)
        let manifest: [String: Any] = [
            "syntheticOnly": true, "case": label, "frames": frames, "channels": channels, "rate": rate,
            "rawFormat": truth.format, "codec": truth.codec, "rawSHA256": rawSHA,
            "decodedFormat": encoding == .float32 ? "interleaved-float32le" : "interleaved-signed-int32le",
            "expectedDecodedSHA256": expectedSHA, "expectedDecodedBytes": truth.decoded.count,
            "originalPrecisionOracleSHA256": rawSHA,
            "decodedOracle": encoding == .pcm32 ? "independent authored Int32 -> Float32(value/2^31) -> Int32(*2^31); original raw remains exact Int32" : "independent full authored precision",
            "source24Formula": "-4000001 + frame*97 + channel*11; decoded Int32 = source24 << 8",
            "source32Formula": "-900000001 + frame*37011 + channel*97",
            "floatBitsFormula": "0x3E800001 + frame*13 + channel*7; channel 1 adds sign bit",
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try manifestData.write(to: folder.appendingPathComponent("generation-manifest.json"), options: .withoutOverwriting)
        let input = folder.appendingPathComponent(label)
        var arguments = ["-f", "lavfi", "-i", "testsrc2=size=96x64:rate=12:duration=1",
                         "-f", truth.format, "-ar", String(rate), "-ac", String(channels), "-i", rawURL.path,
                         "-map", "0:v:0", "-map", "1:a:0", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                         "-c:a", truth.codec]
        if encoding == .alac24 { arguments += ["-sample_fmt", "s32p", "-bits_per_raw_sample", "24"] }
        arguments.append(input.path)
        print("HIGH-PRECISION-AUTHOR \(label) rawSHA=\(rawSHA) expectedDecodedSHA=\(expectedSHA) manifestSHA=\(digest(manifestData)) frames=\(frames) channels=\(channels)")
        try VideoExportTests().ffmpeg(arguments)
        try #require(try PageWorkspace.digest(of: rawURL) == rawSHA, "Authored raw source is immutable: \(label)")
        let originalSHA = try PageWorkspace.digest(of: input)
        let source = VideoAssetPolicy.asset(url: input)
        let sourceAudio = try await source.loadTracks(withMediaType: .audio)
        try #require(sourceAudio.count == 1, "Authored audio track count: \(label)")
        let track = try #require(sourceAudio.first)
        let beforeFormat = try await format(track)
        try #require(beforeFormat.rate == Double(rate), "Authored source rate: \(label)")
        try #require(beforeFormat.channels == UInt32(channels), "Authored source channels: \(label)")
        if encoding == .alac24 {
            try #require(beforeFormat.codec == kAudioFormatAppleLossless, "Actual ALAC source: \(label)")
            try #require(beforeFormat.flags == kAppleLosslessFormatFlag_24BitSourceData, "Actual ALAC 24-bit source flag: \(label)")
        } else {
            try #require(beforeFormat.codec == kAudioFormatLinearPCM, "Actual PCM source: \(label)")
            try #require(beforeFormat.bits == (encoding == .pcm24 ? 24 : 32), "Actual authored precision: \(label)")
            let sourceIsFloat = beforeFormat.flags & kAudioFormatFlagIsFloat != 0
            try #require(sourceIsFloat == (encoding == .float32), "Actual authored integer/float format: \(label)")
        }
        let beforeRaw = try scan(source, track: track, decoded: false, floating: false, label: "\(label)/source-original")
        print("HIGH-PRECISION-SOURCE \(label) codec=\(beforeFormat.codec) bits=\(beforeFormat.bits) flags=\(beforeFormat.flags) rawSHA=\(beforeRaw.sha) authoredRawSHA=\(rawSHA) rawBytes=\(beforeRaw.bytes) rawSamples=\(beforeRaw.samples)")
        if encoding != .alac24 {
            try #require(beforeRaw.sha == rawSHA, "Native source original PCM equals every authored low bit: \(label)")
            try #require(beforeRaw.bytes == truth.raw.count, "Every authored original PCM byte: \(label)")
            try #require(beforeRaw.samples == frames, "Every authored original PCM frame: \(label)")
        }
        let beforeDecoded = try scan(source, track: track, decoded: true, floating: encoding == .float32, label: "\(label)/source-decoded")
        try #require(beforeDecoded.sha == expectedSHA, "Native source decode must match the independent declared decode oracle: \(label)")
        try #require(beforeDecoded.bytes == truth.decoded.count, "Every authored decoded byte: \(label)")
        try #require(beforeDecoded.samples == frames, "Every authored stereo frame: \(label)")
        let expectedEnd = CMTime(value: Int64(frames), timescale: Int32(rate))
        let sourceEnd = try await source.load(.duration)
        try #require(CMTimeCompare(sourceEnd, expectedEnd) == 0, "Independently authored source endpoint: \(label)")
        try #require(beforeDecoded.spans.count == 1, "Entire authored waveform is one exact interval: \(label)")
        try #require(CMTimeCompare(beforeDecoded.spans[0].start, .zero) == 0)
        try #require(CMTimeCompare(beforeDecoded.spans[0].end, expectedEnd) == 0)
        let video = try #require(try await source.loadTracks(withMediaType: .video).first)
        let size = try await video.load(.naturalSize)
        let exporter = BlurredVideoExporter()
        await exporter.export(input: input, pairs: [], quality: .original, canvasBounds: size,
                              expectedSourceSHA256: originalSHA)
        try #require(!exporter.wasCancelled, "\(label): \(exporter.statusText)")
        let output = try #require(exporter.lastOutputURL, "\(label): \(exporter.statusText)")
        let result = VideoAssetPolicy.asset(url: output)
        let resultAudio = try await result.loadTracks(withMediaType: .audio)
        try #require(resultAudio.count == 1, "Every source audio track survives: \(label)")
        let afterTrack = try #require(resultAudio.first)
        let afterFormat = try await format(afterTrack)
        #expect(afterFormat.codec == beforeFormat.codec, "Original audio codec: \(label)")
        #expect(afterFormat.rate == beforeFormat.rate, "Original audio rate: \(label)")
        #expect(afterFormat.channels == beforeFormat.channels, "Every original channel: \(label)")
        #expect(afterFormat.bits == beforeFormat.bits, "Original audio bit depth: \(label)")
        #expect(afterFormat.flags == beforeFormat.flags, "Original audio flags: \(label)")
        #expect(afterFormat.bytesPerFrame == beforeFormat.bytesPerFrame, "Original bytes per frame: \(label)")
        #expect(afterFormat.framesPerPacket == beforeFormat.framesPerPacket, "Original frames per packet: \(label)")
        #expect(sameLayout(afterFormat.layout, beforeFormat.layout, channelCount: beforeFormat.channels),
                "Original channel layout semantics; only canonical 2ch stereo/nil equivalence: \(label)")
        #expect(afterFormat.cookie == beforeFormat.cookie, "Original codec cookie bytes: \(label)")
        let resultEnd = try await result.load(.duration)
        #expect(CMTimeCompare(resultEnd, expectedEnd) == 0, "Exact asset endpoint: \(label)")
        let beforeRange = try await track.load(.timeRange), afterRange = try await afterTrack.load(.timeRange)
        #expect(CMTimeCompare(beforeRange.start, afterRange.start) == 0, "Audio track start: \(label)")
        #expect(CMTimeCompare(CMTimeRangeGetEnd(beforeRange), CMTimeRangeGetEnd(afterRange)) == 0, "Audio track end: \(label)")
        let afterDecoded = try scan(result, track: afterTrack, decoded: true, floating: encoding == .float32, label: "\(label)/output-decoded")
        #expect(afterDecoded.sha == expectedSHA, "Output native decode equals the independent declared decode oracle: \(label)")
        #expect(afterDecoded.bytes == truth.decoded.count, "All output decoded bytes: \(label)")
        #expect(afterDecoded.samples == frames, "All output decoded frames: \(label)")
        try equalSpans(beforeDecoded.spans, afterDecoded.spans, label: label)
        try equalMarkers(beforeDecoded.markers, afterDecoded.markers, label: "\(label)/decoded")
        let beforeEmpty = try await emptyIntervals(track), afterEmpty = try await emptyIntervals(afterTrack)
        try equalSpans(beforeEmpty, afterEmpty, label: "\(label)/empty edits")
        let afterRaw = try scan(result, track: afterTrack, decoded: false, floating: false, label: "\(label)/output-original")
        if encoding != .alac24 {
            try #require(afterRaw.sha == rawSHA, "Every output original PCM low bit equals independent authored truth: \(label)")
            try #require(afterRaw.bytes == truth.raw.count, "Every authored original PCM output byte: \(label)")
            try #require(afterRaw.samples == frames, "Every authored original PCM output frame: \(label)")
        }
        #expect(beforeRaw.sha == afterRaw.sha, "Every original PCM byte/ALAC packet preserved without re-encode: \(label)")
        #expect(beforeRaw.bytes == afterRaw.bytes, "All original audio payload bytes: \(label)")
        #expect(beforeRaw.samples == afterRaw.samples, "All original audio samples/packets: \(label)")
        try equalMarkers(beforeRaw.markers, afterRaw.markers, label: "\(label)/original")
        #expect(try PageWorkspace.digest(of: input) == originalSHA, "Source media survives export: \(label)")
        #expect(try PageWorkspace.digest(of: rawURL) == rawSHA, "Independent authored bytes survive export: \(label)")
        print("HIGH-PRECISION-PRESERVATION \(label) sourceSHA=\(originalSHA) codec=\(beforeFormat.codec) bits=\(beforeFormat.bits) flags=\(beforeFormat.flags) rate=\(beforeFormat.rate) channels=\(beforeFormat.channels) decodedSHA=\(beforeDecoded.sha)/\(afterDecoded.sha) expectedSHA=\(expectedSHA) decodedBytes=\(beforeDecoded.bytes)/\(afterDecoded.bytes) decodedFrames=\(beforeDecoded.samples)/\(afterDecoded.samples) rawSHA=\(beforeRaw.sha)/\(afterRaw.sha) rawBytes=\(beforeRaw.bytes)/\(afterRaw.bytes) rawSamples=\(beforeRaw.samples)/\(afterRaw.samples) rawMarkers=\(beforeRaw.markers.count)/\(afterRaw.markers.count)")
    }

    @MainActor @Test func testPCM24MOVPreservesEveryAuthoredLowBit() async throws { try await compare(.pcm24, ext: "mov") }
    @MainActor @Test func testPCM32MOVPreservesEveryAuthoredLowBit() async throws { try await compare(.pcm32, ext: "mov") }
    @MainActor @Test func testFloat32MOVPreservesEveryAuthoredMantissaBit() async throws { try await compare(.float32, ext: "mov") }
    @MainActor @Test func testALAC24MOVPreservesAuthoredPCM32AndAllPackets() async throws { try await compare(.alac24, ext: "mov") }
    @MainActor @Test func testALAC24MP4PreservesAuthoredPCM32AndAllPackets() async throws { try await compare(.alac24, ext: "mp4") }
}
