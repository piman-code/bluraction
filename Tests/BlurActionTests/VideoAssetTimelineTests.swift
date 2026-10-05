import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import BlurAction

/// Exact metadata-reader boundaries only. One authored temporary PCM WAV;
/// no user files, network, OS input, decoded frames, source fingerprint approval,
/// or cross-platform playback claims.
@Suite(.serialized)
struct VideoAssetTimelineTests {
    private typealias R = VideoTimeline.Rational

    @Test
    func signedCMTimeReductionPreservesZeroAndInt64Extremes() throws {
        let cases: [(CMTime, R)] = try [
            (CMTime(value: 0, timescale: 600), R(0)),
            (CMTime(value: 6, timescale: 4), R(3, 2)),
            (CMTime(value: -6, timescale: 4), R(-3, 2)),
            (CMTime(value: Int64.min, timescale: 1), R(Int64.min)),
            (CMTime(value: Int64.min, timescale: 2), R(Int64.min / 2)),
            (CMTime(value: Int64.min, timescale: Int32.max), R(Int64.min, Int64(Int32.max))),
            (CMTime(value: Int64.max, timescale: 3), R(Int64.max, 3))]
        for (native, exact) in cases {
            #expect(try VideoAssetTimeline.rational(native) == exact)
        }
    }

    @Test
    func nonnumericRoundedEpochAndInvalidTimescaleCannotEnterTheExactDTO() throws {
        var rounded = CMTime(value: 1, timescale: 2)
        rounded.flags.insert(.hasBeenRounded)
        let cases: [CMTime] = [.invalid, .indefinite, .positiveInfinity, .negativeInfinity, rounded,
            CMTime(value: 1, timescale: 2, flags: .valid, epoch: 1),
            CMTime(value: 1, timescale: 2, flags: .valid, epoch: -1),
            CMTime(value: 1, timescale: 0, flags: .valid, epoch: 0),
            CMTime(value: 1, timescale: -1, flags: .valid, epoch: 0)]
        for native in cases {
            do {
                _ = try VideoAssetTimeline.rational(native)
                Issue.record("Invalid or inexact CMTime entered the exact timeline")
            } catch VideoAssetTimeline.ReadError.inexactTime {}
        }
    }

    @Test
    func rateCrossCancellationAvoidsIntermediateOverflowAndKeepsExactFractions() throws {
        let maximum = Int64.max
        let large = try R(maximum, maximum - 1)
        let tiny = try R(1, maximum)
        let unit = try R(1)
        // Multiplying either unreduced pair would exceed Int64; the exact result
        // is representable and must not be rejected just for that intermediate.
        #expect(try VideoAssetTimeline.ratio(large, large) == unit)
        #expect(try VideoAssetTimeline.ratio(tiny, tiny) == unit)
        let source = try R(6, 5)
        let target = try R(3, 4)
        let expected = try R(8, 5)
        #expect(try VideoAssetTimeline.ratio(source, target) == expected)
    }

    @Test
    func unrepresentableExactRateNumeratorAndDenominatorFailWithoutWrapping() throws {
        let large = try R(Int64.max)
        let tiny = try R(1, Int64.max)
        for (source, target) in [(large, tiny), (tiny, large)] {
            do {
                _ = try VideoAssetTimeline.ratio(source, target)
                Issue.record("An exact rate outside the Int64 wire domain was accepted")
            } catch VideoAssetTimeline.ReadError.exactArithmeticOverflow {}
        }
    }

    @Test
    func zeroAndNegativeDurationsCannotProduceAnInventedPositiveRate() throws {
        let unit = try R(1)
        let zero = try R(0)
        let negative = try R(-1)
        for (source, target) in [(zero, unit), (negative, unit), (unit, zero), (unit, negative)] {
            do {
                _ = try VideoAssetTimeline.ratio(source, target)
                Issue.record("A nonpositive source or target duration produced a rate")
            } catch VideoAssetTimeline.ReadError.nonpositiveDuration {}
        }
    }

    @Test
    func nonFileURLIsRejectedBeforeCreatingOrLoadingAnAsset() async throws {
        // Custom non-network scheme; even a broken gate cannot contact a host.
        let url = try #require(URL(string: "bluraction-test:rejected-before-asset"))
        #expect(!url.isFileURL)
        do {
            _ = try await VideoAssetTimeline.read(url: url)
            Issue.record("Non-file URL reached the native reader")
        } catch VideoAssetTimeline.ReadError.localFileRequired {}
    }

    @Test
    @MainActor
    func preCancelledTaskRejectsBeforeURLValidationOrNativeObservation() async throws {
        let url = try #require(URL(string: "bluraction-test:cancel-before-asset"))
        // The child is queued on this actor. Cancelling before the first await
        // makes the pre-read cancellation deterministic, without a timer/sleep.
        let operation = Task { @MainActor in _ = try await VideoAssetTimeline.read(url: url) }
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
    }

    @Test
    @MainActor
    func preCancelledTaskRejectsAnAlreadyConstructedAssetBeforeLoadingMetadata() async throws {
        let asset = AVMutableComposition()
        let operation = Task { @MainActor in _ = try await VideoAssetTimeline.read(from: asset) }
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
    }

    @Test
    @MainActor
    func emptyAudioOnlyCompositionCannotInventPositiveDurationOrEnterTrackMapping() async throws {
        let asset = AVMutableComposition()
        let audio = try #require(asset.addMutableTrack(withMediaType: .audio,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid))
        // AVComposition/AVCompositionTrack SDK documentation forbids appending
        // empty ranges at the end. With no existing media, this does not create
        // a positive asset duration. Positive-duration audio-only track rejection
        // needs a separately authored real-media fixture, not this empty source.
        audio.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)))
        let duration = try await asset.load(.duration)
        #expect(duration.isNumeric && CMTimeCompare(duration, .zero) == 0)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        #expect(videos.isEmpty && audios.count == 1)
        do {
            _ = try await VideoAssetTimeline.read(from: asset)
            Issue.record("Zero-duration empty composition accepted as a video timeline")
        } catch VideoAssetTimeline.ReadError.nonpositiveDuration {}
    }

    @Test
    @MainActor
    func realOneSecondPCMSourceWithoutVideoIsRejectedAndPreserved() async throws {
        // RIFF WAVE, PCM16 little-endian, mono 8000Hz, exactly 8000 silent
        // samples. No encoder, downloaded fixture, user source or playback.
        func little32(_ value: UInt32) -> [UInt8] {
            (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
        }
        func little16(_ value: UInt16) -> [UInt8] {
            (0..<2).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
        }
        let sampleBytes: UInt32 = 8000 * 2
        var bytes = Data("RIFF".utf8)
        bytes.append(contentsOf: little32(36 + sampleBytes))
        bytes.append(Data("WAVEfmt ".utf8))
        bytes.append(contentsOf: little32(16))
        bytes.append(contentsOf: little16(1)) // PCM encoding
        bytes.append(contentsOf: little16(1)) // one channel
        bytes.append(contentsOf: little32(8000))
        bytes.append(contentsOf: little32(16000))
        bytes.append(contentsOf: little16(2)) // block alignment
        bytes.append(contentsOf: little16(16))
        bytes.append(Data("data".utf8))
        bytes.append(contentsOf: little32(sampleBytes))
        bytes.append(Data(repeating: 0, count: Int(sampleBytes)))
        #expect(bytes.count == 16044)

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("blur-native-audio-only-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("authored-one-second.wav")
        try bytes.write(to: source, options: .withoutOverwriting)
        #expect(try Data(contentsOf: source) == bytes)
        let asset = AVURLAsset(url: source, options: [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        let duration = try await asset.load(.duration)
        #expect(duration.isNumeric && CMTimeCompare(duration, CMTime(value: 1, timescale: 1)) == 0)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        #expect(videos.isEmpty && audios.count == 1)
        do {
            _ = try await VideoAssetTimeline.read(url: source)
            Issue.record("Actual positive-duration audio-only source accepted as video")
        } catch VideoAssetTimeline.ReadError.unsupportedTracks {}
        #expect(try Data(contentsOf: source) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [source.lastPathComponent])
    }
}
