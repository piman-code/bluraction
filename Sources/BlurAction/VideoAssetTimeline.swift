import AVFoundation
import CoreMedia
import Foundation

/// Native asset metadata -> exact common DTO. This neither proves decoder PTS
/// correspondence/frame presence nor checks source identity, SHA, or path scope.
/// Standalone builds need VideoTimeline.swift and ProjectJSONTokens.swift too.
enum VideoAssetTimeline {
    enum ReadError: Error {
        case localFileRequired, inexactTime, unsupportedTracks, unsupportedSegments
        case nonpositiveDuration, exactArithmeticOverflow
    }

    /// The caller owns approval/identity/SHA guards before and after observation.
    /// Forbid-all references constrains referenced media, not the original URL.
    static func read(url: URL) async throws -> VideoTimeline {
        try Task.checkCancellation()
        guard url.isFileURL else { throw ReadError.localFileRequired }
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        return try await read(from: asset)
    }

    /// Observe only an AVAsset already supplied/approved by the caller. Source
    /// URL and SHA protection remain the caller's responsibility. No origin or
    /// missing segment is inferred, and shorter track ends are not padded.
    static func read(from asset: AVAsset) async throws -> VideoTimeline {
        try Task.checkCancellation()
        let nativeDuration = try await asset.load(.duration)
        try Task.checkCancellation()
        let duration = try rational(nativeDuration)
        guard duration.numerator > 0 else { throw ReadError.nonpositiveDuration }
        let videos = try await asset.loadTracks(withMediaType: .video)
        try Task.checkCancellation()
        let audios = try await asset.loadTracks(withMediaType: .audio)
        try Task.checkCancellation()
        guard videos.count == 1, audios.count <= 16 else { throw ReadError.unsupportedTracks }
        var native: [(id: Int64, kind: String, track: AVAssetTrack)] = []
        for track in videos { native.append((Int64(track.trackID), "video", track)) }
        for track in audios { native.append((Int64(track.trackID), "audio", track)) }
        native.sort { $0.id < $1.id }
        var previousID: Int64 = 0
        var tracks: [VideoTimeline.Track] = []
        for record in native {
            try Task.checkCancellation()
            guard record.id > previousID else { throw ReadError.unsupportedTracks }
            previousID = record.id
            let scale = try await record.track.load(.naturalTimeScale)
            try Task.checkCancellation()
            guard scale > 0 else { throw ReadError.inexactTime }
            let segments = try await record.track.load(.segments)
            try Task.checkCancellation()
            guard (1...4096).contains(segments.count) else { throw ReadError.unsupportedSegments }
            var mapped: [VideoTimeline.Segment] = []
            for segment in segments {
                try Task.checkCancellation()
                let mapping = segment.timeMapping
                let start = try rational(mapping.target.start)
                let length = try rational(mapping.target.duration)
                guard length.numerator > 0 else { throw ReadError.nonpositiveDuration }
                if segment.isEmpty {
                    // Empty edits have no source media time; their source range
                    // may be invalid. Only the explicit target range is meaningful.
                    mapped.append(try .init(assetStart: start, assetDuration: length,
                                            mediaStart: nil, rate: .init(1)))
                } else {
                    let media = try rational(mapping.source.start)
                    let sourceDuration = try rational(mapping.source.duration)
                    let rate = try ratio(sourceDuration, length)
                    mapped.append(try .init(assetStart: start, assetDuration: length,
                                            mediaStart: media, rate: rate))
                }
            }
            tracks.append(try .init(id: record.id, kind: record.kind,
                                    mediaTimescale: Int64(scale), segments: mapped))
        }
        let result = try VideoTimeline(assetDuration: duration, tracks: tracks)
        try Task.checkCancellation()
        return result
    }

    /// Exact reduction of the supplied CMTime; no seconds/Double roundtrip.
    static func rational(_ time: CMTime) throws -> VideoTimeline.Rational {
        guard time.isNumeric, time.timescale > 0, time.epoch == 0,
              !time.flags.contains(.hasBeenRounded) else { throw ReadError.inexactTime }
        let divisor = gcd(time.value.magnitude, UInt64(time.timescale))
        // The divisor is <= positive Int32 timescale, including for Int64.min.
        let reducedNumerator = time.value / Int64(divisor)
        let reducedDenominator = Int64(time.timescale) / Int64(divisor)
        return try .init(reducedNumerator, reducedDenominator)
    }

    /// source-duration / asset-duration. Reduce across products before checked
    /// Int64 multiplication; an unrepresentable exact rate explicitly holds.
    static func ratio(_ source: VideoTimeline.Rational,
                      _ target: VideoTimeline.Rational) throws -> VideoTimeline.Rational {
        guard source.numerator > 0, target.numerator > 0 else { throw ReadError.nonpositiveDuration }
        let first = Int64(gcd(UInt64(source.numerator), UInt64(target.numerator)))
        let second = Int64(gcd(UInt64(target.denominator), UInt64(source.denominator)))
        let numerator = (source.numerator / first).multipliedReportingOverflow(by: target.denominator / second)
        let denominator = (source.denominator / second).multipliedReportingOverflow(by: target.numerator / first)
        guard !numerator.overflow, !denominator.overflow else { throw ReadError.exactArithmeticOverflow }
        return try .init(numerator.partialValue, denominator.partialValue)
    }

    private static func gcd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        var x = a, y = b
        while y != 0 { let remainder = x % y; x = y; y = remainder }
        return x
    }
}
