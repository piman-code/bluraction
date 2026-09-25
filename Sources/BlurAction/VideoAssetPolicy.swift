import AVFoundation

/// Media opened by the editor must be contained in the selected movie file.
enum VideoAssetPolicy {
    static func asset(url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
        ])
    }
}
