import Testing
import Foundation
import AVFoundation
import AudioToolbox
import CryptoKit
@testable import BlurAction

/// Entire native reads of synthetic media; no Finder, OS input or installation.
@Suite(.serialized)
final class AudioPreservationTests {
    private struct Span {
        var start: CMTime
        var end: CMTime
    }
    private struct Scan {
        let sha: String
        let bytes: Int
        let samples: Int
        let markers: Int
        let spans: [Span]
        let rawMarkers: [RawMarker]
    }
    private struct RawMarker {
        let pts: CMTime
        let outputPTS: CMTime
        let duration: CMTime
        let outputDuration: CMTime
        let attachments: [String: String]
    }
    private struct Format {
        let id: AudioFormatID
        let rate: Double
        let channels: UInt32
        let bits: UInt32
        let flags: AudioFormatFlags
        let bytesPerFrame: UInt32
        let framesPerPacket: UInt32
        let layout: Data?
        let cookie: Data?
    }
    private struct Manifest: Decodable {
        struct Case: Decodable { let file: String; let sourceSHA256: String }
        let syntheticOnly: Bool
        let cases: [Case]
    }

    private func finite(_ time: CMTime) -> Bool {
        time.isValid && time.isNumeric && time.timescale > 0 && time.seconds.isFinite
    }

    private func markerAttachments(_ sample: CMSampleBuffer) -> [String: String] {
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

    private func sameMarkerTime(_ a: CMTime, _ b: CMTime) -> Bool {
        if finite(a) && finite(b) { return CMTimeCompare(a, b) == 0 }
        // Marker clocks may be invalid. Preserve their actual state instead of
        // manufacturing a timestamp or accepting an invalid media-sample clock.
        return a.value == b.value && a.timescale == b.timescale &&
            a.epoch == b.epoch && a.flags == b.flags
    }

    private func equalRawMarkers(_ before: [RawMarker], _ after: [RawMarker], label: String) throws {
        try #require(before.count == after.count, "All raw AAC marker inventory: \(label)")
        for (a, b) in zip(before, after) {
            #expect(sameMarkerTime(a.pts, b.pts), "Raw marker PTS/state: \(label)")
            #expect(sameMarkerTime(a.outputPTS, b.outputPTS), "Raw marker output PTS/state: \(label)")
            #expect(sameMarkerTime(a.duration, b.duration), "Raw marker duration/state: \(label)")
            #expect(sameMarkerTime(a.outputDuration, b.outputDuration), "Raw marker output duration/state: \(label)")
            #expect(a.attachments == b.attachments, "Raw marker attachments: \(label)")
        }
    }

    /// Normalize adjacent intervals only; neither epsilon nor nominal FPS is used.
    private func add(_ span: Span, to result: inout [Span]) throws {
        try #require(finite(span.start) && finite(span.end) && CMTimeCompare(span.end, span.start) >= 0)
        if CMTimeCompare(span.end, span.start) == 0 { return }
        if let last = result.last {
            try #require(CMTimeCompare(span.start, last.end) >= 0, "Unexpected overlapping/backward native PCM timing")
            if CMTimeCompare(span.start, last.end) == 0 {
                result[result.count - 1].end = span.end
                return
            }
        }
        result.append(span)
    }

    private func equalSpans(_ before: [Span], _ after: [Span], label: String) throws {
        try #require(before.count == after.count, "Exact interval inventory: \(label)")
        for (a, b) in zip(before, after) {
            #expect(CMTimeCompare(a.start, b.start) == 0, "Exact interval start: \(label)")
            #expect(CMTimeCompare(a.end, b.end) == 0, "Exact interval end: \(label)")
        }
    }

    private func format(_ track: AVAssetTrack) async throws -> Format {
        let descriptions = try await track.load(.formatDescriptions)
        let description = try #require(descriptions.first)
        try #require(CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio)
        let basic = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)).pointee
        try #require(basic.mSampleRate.isFinite && basic.mSampleRate > 0 && basic.mChannelsPerFrame > 0)
        var layoutSize = 0, cookieSize = 0
        let layoutPointer = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &layoutSize)
        let cookiePointer = CMAudioFormatDescriptionGetMagicCookie(description, sizeOut: &cookieSize)
        return Format(id: basic.mFormatID, rate: basic.mSampleRate, channels: basic.mChannelsPerFrame,
                      bits: basic.mBitsPerChannel, flags: basic.mFormatFlags,
                      bytesPerFrame: basic.mBytesPerFrame, framesPerPacket: basic.mFramesPerPacket,
                      layout: layoutPointer.map { Data(bytes: $0, count: layoutSize) },
                      cookie: cookiePointer.map { Data(bytes: $0, count: cookieSize) })
    }

    private func scan(_ asset: AVAsset, track: AVAssetTrack, pcm: Bool, label: String) throws -> Scan {
        let reader = try AVAssetReader(asset: asset)
        defer { if reader.status == .reading { reader.cancelReading() } }
        let settings: [String: Any]? = pcm ? [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false] : nil
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        try #require(reader.canAdd(output)); reader.add(output)
        try #require(reader.startReading())
        var hash = SHA256(), bytes = 0, samples = 0, markers = 0, spans: [Span] = []
        var rawMarkers: [RawMarker] = []
        // All fixtures are short. A bound hit is an incomplete scan, not success.
        for _ in 0..<30_000 {
            guard let sample = output.copyNextSampleBuffer() else { break }
            let count = CMSampleBufferGetNumSamples(sample)
            try #require(count >= 0)
            let start = CMSampleBufferGetOutputPresentationTimeStamp(sample)
            let duration = CMSampleBufferGetOutputDuration(sample)
            if !pcm && count == 0 {
                // The SDK permits nil-reader marker-only buffers. An actual
                // AAC EOF marker had invalid PTS and valid zero duration; it
                // carries no encoded data and is not a media sample clock.
                let payloadBytes = CMSampleBufferGetDataBuffer(sample).map { CMBlockBufferGetDataLength($0) } ?? 0
                try #require(payloadBytes == 0, "A raw zero-sample marker must contain no media bytes: \(label)")
                rawMarkers.append(RawMarker(pts: CMSampleBufferGetPresentationTimeStamp(sample), outputPTS: start,
                                            duration: CMSampleBufferGetDuration(sample), outputDuration: duration,
                                            attachments: markerAttachments(sample)))
                markers += 1
                continue
            }
            let validTiming = finite(start) && finite(duration) && CMTimeCompare(duration, .zero) >= 0
            var timingEvidence = ""
            if !validTiming {
                func describe(_ time: CMTime) -> String {
                    "value=\(time.value),scale=\(time.timescale),epoch=\(time.epoch),flags=\(time.flags.rawValue),seconds=\(time.seconds)"
                }
                let attachments = markerAttachments(sample).sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }.joined(separator: ";")
                timingEvidence = "AUDIO-TIMING \(label) pcm=\(pcm) count=\(count) " +
                    "rawPTS{\(describe(CMSampleBufferGetPresentationTimeStamp(sample)))} " +
                    "outputPTS{\(describe(start))} " +
                    "rawDuration{\(describe(CMSampleBufferGetDuration(sample)))} " +
                    "outputDuration{\(describe(duration))} attachments{\(attachments)}"
                print(timingEvidence)
            }
            try #require(validTiming, "\(timingEvidence)")
            if pcm { try add(Span(start: start, end: CMTimeAdd(start, duration)), to: &spans) }
            if count == 0 {
                // Empty/timing markers are not PCM frames or encoded packets.
                markers += 1
                continue
            }
            let block = try #require(CMSampleBufferGetDataBuffer(sample))
            let size = CMBlockBufferGetDataLength(block)
            try #require(size > 0 && size <= 16 * 1024 * 1024 && bytes <= 64 * 1024 * 1024 - size)
            var data = Data(count: size)
            let result = data.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!)
            }
            try #require(result == noErr)
            if pcm {
                let desc = try #require(CMSampleBufferGetFormatDescription(sample))
                let basic = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(desc)).pointee
                try #require(basic.mFormatID == kAudioFormatLinearPCM && basic.mBitsPerChannel == 16 &&
                             basic.mBytesPerFrame == basic.mChannelsPerFrame * 2 &&
                             basic.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0)
                try #require(size == count * Int(basic.mBytesPerFrame), "All interleaved PCM frame bytes must be scanned")
            }
            hash.update(data: data); bytes += size; samples += count
        }
        try #require(reader.status == .completed, "Complete native audio EOF is required")
        try #require(samples > 0 && bytes > 0)
        return Scan(sha: hash.finalize().map { String(format: "%02x", $0) }.joined(),
                    bytes: bytes, samples: samples, markers: markers, spans: spans, rawMarkers: rawMarkers)
    }

    private func emptyIntervals(_ track: AVAssetTrack) async throws -> [Span] {
        var intervals: [Span] = []
        for segment in try await track.load(.segments) where segment.isEmpty {
            let target = segment.timeMapping.target
            try add(Span(start: target.start, end: CMTimeRangeGetEnd(target)), to: &intervals)
        }
        return intervals
    }

    @MainActor
    private func compareExport(_ input: URL, expectedEnabled: [Bool]? = nil,
                               expectedRates: [Double]? = nil, expectedChannels: [UInt32]? = nil) async throws {
        let original = try PageWorkspace.digest(of: input)
        let source = VideoAssetPolicy.asset(url: input)
        let beforeTracks = try await source.loadTracks(withMediaType: .audio)
        if let rates = expectedRates { try #require(beforeTracks.count == rates.count) }
        if let channels = expectedChannels { try #require(beforeTracks.count == channels.count) }
        if let flags = expectedEnabled {
            try #require(beforeTracks.count == flags.count)
            for (track, enabled) in zip(beforeTracks, flags) {
                try #require(try await track.load(.isEnabled) == enabled, "Native authored enabled flag must actually exist")
            }
        }
        let video = try #require(try await source.loadTracks(withMediaType: .video).first)
        let bounds = try await video.load(.naturalSize)
        let exporter = BlurredVideoExporter()
        await exporter.export(input: input, pairs: [], quality: .original, canvasBounds: bounds,
                              expectedSourceSHA256: original)
        try #require(!exporter.wasCancelled, "\(exporter.statusText)")
        let output = try #require(exporter.lastOutputURL, "\(exporter.statusText)")
        let result = VideoAssetPolicy.asset(url: output)
        let afterTracks = try await result.loadTracks(withMediaType: .audio)
        try #require(afterTracks.count == beforeTracks.count, "Every source audio track must survive")
        let beforeEnd = try await source.load(.duration), afterEnd = try await result.load(.duration)
        #expect(CMTimeCompare(beforeEnd, afterEnd) == 0, "Exact asset endpoint: \(input.lastPathComponent)")
        for (index, pair) in zip(beforeTracks, afterTracks).enumerated() {
            let label = "\(input.lastPathComponent)/audio\(index)"
            let a = try await format(pair.0), b = try await format(pair.1)
            if let rates = expectedRates { try #require(a.rate == rates[index], "Authored source rate") }
            if let channels = expectedChannels { try #require(a.channels == channels[index], "Authored source channel count") }
            #expect(a.id == b.id, "Original codec: \(label)")
            #expect(a.rate == b.rate, "Original rate: \(label)")
            #expect(a.channels == b.channels, "Every original channel: \(label)")
            #expect(a.bits == b.bits, "Original bit depth: \(label)")
            #expect(a.flags == b.flags, "Original format flags: \(label)")
            #expect(a.bytesPerFrame == b.bytesPerFrame, "Original bytes per frame: \(label)")
            #expect(a.framesPerPacket == b.framesPerPacket, "Original frames per packet: \(label)")
            #expect(a.layout == b.layout, "Original channel layout bytes: \(label)")
            #expect(a.cookie == b.cookie, "Original codec magic cookie: \(label)")
            let beforeEnabled = try await pair.0.load(.isEnabled), afterEnabled = try await pair.1.load(.isEnabled)
            #expect(beforeEnabled == afterEnabled, "Original enabled state: \(label)")
            let beforeVolume = try await pair.0.load(.preferredVolume), afterVolume = try await pair.1.load(.preferredVolume)
            #expect(beforeVolume == afterVolume, "Original preferred volume: \(label)")
            let beforeLanguage = try await pair.0.load(.languageCode), afterLanguage = try await pair.1.load(.languageCode)
            #expect(beforeLanguage == afterLanguage, "Original language: \(label)")
            let beforeTag = try await pair.0.load(.extendedLanguageTag), afterTag = try await pair.1.load(.extendedLanguageTag)
            #expect(beforeTag == afterTag, "Original extended language: \(label)")
            let beforePCM = try scan(source, track: pair.0, pcm: true, label: "\(label)/source")
            let afterPCM = try scan(result, track: pair.1, pcm: true, label: "\(label)/output")
            #expect(beforePCM.sha == afterPCM.sha, "Full native PCM SHA: \(label)")
            #expect(beforePCM.bytes == afterPCM.bytes, "All native PCM bytes: \(label)")
            #expect(beforePCM.samples == afterPCM.samples, "All native PCM frames: \(label)")
            try equalSpans(beforePCM.spans, afterPCM.spans, label: label)
            let beforeEmpty = try await emptyIntervals(pair.0), afterEmpty = try await emptyIntervals(pair.1)
            try equalSpans(beforeEmpty, afterEmpty, label: "\(label)/empty edits")
            var rawEvidence = ""
            if a.id == kAudioFormatMPEG4AAC {
                let beforeRaw = try scan(source, track: pair.0, pcm: false, label: "\(label)/source")
                let afterRaw = try scan(result, track: pair.1, pcm: false, label: "\(label)/output")
                #expect(beforeRaw.sha == afterRaw.sha, "All original AAC packet SHA, without re-encoding: \(label)")
                #expect(beforeRaw.bytes == afterRaw.bytes, "All original AAC packet bytes: \(label)")
                #expect(beforeRaw.samples == afterRaw.samples, "All original AAC sample count: \(label)")
                #expect(beforeRaw.markers == afterRaw.markers, "All raw AAC zero markers: \(label)")
                try equalRawMarkers(beforeRaw.rawMarkers, afterRaw.rawMarkers, label: label)
                rawEvidence = "rawAACSHA=\(beforeRaw.sha)/\(afterRaw.sha) rawZeroMarkers=\(beforeRaw.markers)/\(afterRaw.markers)"
            }
            print("AUDIO-PRESERVATION \(label) format=\(a.id) rate=\(a.rate) channels=\(a.channels) enabled=\(beforeEnabled) " +
                  "pcmFrames=\(beforePCM.samples)/\(afterPCM.samples) pcmSHA=\(beforePCM.sha)/\(afterPCM.sha) " +
                  "pcmZeroMarkers=\(beforePCM.markers)/\(afterPCM.markers) \(rawEvidence)")
        }
        #expect(try PageWorkspace.digest(of: input) == original, "Source bytes must survive export")
    }

    private func directory() throws -> URL { try VideoExportTests().directory() }
    private func ffmpeg(_ args: [String]) throws { try VideoExportTests().ffmpeg(args) }

    @MainActor @Test
    func testPinnedEightOriginalPCMAudioAndExactNativeIntervalsSurvive() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("shared/fixtures/video-timelines")
        let manifest = root.appendingPathComponent("manifest.json")
        try #require(try PageWorkspace.digest(of: manifest) == "f1779cbc24d9f7a0451b182e028f587db1113f5f605ae80f22b6efa0d5a45f0f")
        let cases = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifest))
        try #require(cases.syntheticOnly && cases.cases.count == 8)
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        for fixture in cases.cases {
            let original = root.appendingPathComponent(fixture.file)
            try #require(try PageWorkspace.digest(of: original) == fixture.sourceSHA256)
            let input = folder.appendingPathComponent(fixture.file)
            try FileManager.default.copyItem(at: original, to: input)
            try await compareExport(input)
            #expect(try PageWorkspace.digest(of: original) == fixture.sourceSHA256)
        }
    }

    @MainActor @Test
    func testAACMOVAndMP4KeepOriginal32000And48000RatesAndAllPackets() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        for rate in [32_000, 48_000] {
            for ext in ["mov", "mp4"] {
                let input = folder.appendingPathComponent("aac-\(rate).\(ext)")
                try ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=96x64:rate=12:duration=1",
                            "-f", "lavfi", "-i", "aevalsrc=0.2*sin(2*PI*313*t)|0.3*sin(2*PI*719*t):s=\(rate):d=1",
                            "-map", "0:v:0", "-map", "1:a:0", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                            "-c:a", "aac", "-b:a", "128k", input.path])
                try await compareExport(input, expectedRates: [Double(rate)], expectedChannels: [2])
            }
        }
    }

    @MainActor @Test
    func testLosslessSixChannelsKeepEveryDistinctChannelAndLayout() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("six-distinct-channels.mov")
        let waves = [101, 211, 307, 401, 503, 601].map { "0.1*sin(2*PI*\($0)*t)" }.joined(separator: "|")
        try ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=96x64:rate=12:duration=1",
                    "-f", "lavfi", "-i", "aevalsrc=\(waves):s=48000:d=1:c=5.1",
                    "-map", "0:v:0", "-map", "1:a:0", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                    "-c:a", "pcm_s16le", input.path])
        try await compareExport(input, expectedRates: [48_000], expectedChannels: [6])
    }

    /// A native passthrough fixture author supplies actual stored enabled flags;
    /// FFmpeg disposition alone is not treated as a tkhd enabled-state oracle.
    private func authoredEnabledCopy(_ input: URL, output: URL, flags: [Bool]) async throws {
        let asset = VideoAssetPolicy.asset(url: input)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let tracks = videoTracks + audioTracks
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        defer {
            if reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
        }
        var streams: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        var audioIndex = 0
        for track in tracks {
            let descriptions = try await track.load(.formatDescriptions)
            let hint = try #require(descriptions.first)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            let into = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: hint)
            if track.mediaType == .audio {
                try #require(audioIndex < flags.count)
                into.marksOutputTrackAsEnabled = flags[audioIndex]
                into.preferredVolume = audioIndex == 0 ? 0.375 : 0.5
                into.languageCode = "kor"; into.extendedLanguageTag = "ko-KR"
                audioIndex += 1
            }
            try #require(reader.canAdd(out) && writer.canAdd(into))
            reader.add(out); writer.add(into); streams.append((out, into))
        }
        try #require(audioIndex == flags.count)
        let end = try await asset.load(.duration)
        writer.movieTimeScale = end.timescale
        try #require(reader.startReading() && writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var finished = Set<Int>()
        for _ in 0..<30_000 {
            if finished.count == streams.count { break }
            try #require(reader.status != .failed && writer.status != .failed)
            for (index, stream) in streams.enumerated() where !finished.contains(index) && stream.1.isReadyForMoreMediaData {
                if let sample = stream.0.copyNextSampleBuffer() { try #require(stream.1.append(sample)) }
                else { stream.1.markAsFinished(); finished.insert(index) }
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try #require(finished.count == streams.count && reader.status == .completed)
        writer.endSession(atSourceTime: end); await writer.finishWriting()
        try #require(writer.status == .completed)
    }

    @MainActor @Test
    func testTwoAudioTracksPreserveDistinctRatesStereoMonoAndEnabledFlags() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let base = folder.appendingPathComponent("multiple-source.mov")
        try ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=96x64:rate=12:duration=1",
                    "-f", "lavfi", "-i", "aevalsrc=0.2*sin(2*PI*313*t)|0.3*sin(2*PI*719*t):s=44100:d=1",
                    "-f", "lavfi", "-i", "sine=frequency=983:sample_rate=8000:duration=1",
                    "-map", "0:v:0", "-map", "1:a:0", "-map", "2:a:0",
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "pcm_s16le", base.path])
        let original = try PageWorkspace.digest(of: base)
        for flags in [[true, true], [true, false], [false, true]] {
            let input = folder.appendingPathComponent("flags-\(flags[0])-\(flags[1]).mov")
            try await authoredEnabledCopy(base, output: input, flags: flags)
            let authored = try await VideoAssetPolicy.asset(url: input).loadTracks(withMediaType: .audio)
            try #require(authored.count == 2)
            for (index, track) in authored.enumerated() {
                try #require(try await track.load(.preferredVolume) == (index == 0 ? 0.375 : 0.5), "Native authored volume")
                try #require(try await track.load(.languageCode) == "kor", "Native authored language")
                try #require(try await track.load(.extendedLanguageTag) == "ko-KR", "Native authored extended language")
            }
            try await compareExport(input, expectedEnabled: flags, expectedRates: [44_100, 8_000], expectedChannels: [2, 1])
        }
        #expect(try PageWorkspace.digest(of: base) == original)
    }

    @MainActor @Test
    func testUniquePCMEditsKeepTheEntireDistinctAuthoredWaveform() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("shared/fixtures/video-timelines-unique-pcm")
        let manifest = root.appendingPathComponent("manifest.json")
        try #require(try PageWorkspace.digest(of: manifest) == "645b3eda2a866e14bfe8e649881a8a5a600c1ecdad642e4a471ca91e1bf60811")
        let cases = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifest))
        try #require(cases.syntheticOnly && cases.cases.count == 2)
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        for fixture in cases.cases {
            let original = root.appendingPathComponent(fixture.file)
            try #require(try PageWorkspace.digest(of: original) == fixture.sourceSHA256)
            let positive = fixture.file == "unique-pcm-positive-quarter.mov"
            try #require(positive || fixture.file == "unique-pcm-negative-quarter.mov")
            var authored = Data(repeating: 0, count: positive ? 2000 * 2 : 0)
            for index in (positive ? 0 : 2000)..<9600 {
                var value = Int16(-10_000 + index).littleEndian
                withUnsafeBytes(of: &value) { authored.append(contentsOf: $0) }
            }
            let expected = SHA256.hash(data: authored).map { String(format: "%02x", $0) }.joined()
            let asset = VideoAssetPolicy.asset(url: original)
            let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
            let actual = try scan(asset, track: track, pcm: true, label: "\(fixture.file)/source-authored-oracle")
            try #require(actual.sha == expected && actual.bytes == authored.count && actual.samples == authored.count / 2,
                         "Actual native source must match every distinct authored sample; trim origin cannot shift by waveform period")
            let input = folder.appendingPathComponent(fixture.file)
            try FileManager.default.copyItem(at: original, to: input)
            try await compareExport(input, expectedRates: [8000], expectedChannels: [1])
            #expect(try PageWorkspace.digest(of: original) == fixture.sourceSHA256)
        }
    }
}
