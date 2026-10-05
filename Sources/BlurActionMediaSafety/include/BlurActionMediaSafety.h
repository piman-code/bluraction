#import <Foundation/Foundation.h>

@class AVAssetWriterInput;

NS_ASSUME_NONNULL_BEGIN

/// Apply actual source audio presentation metadata before writing. A malformed
/// language must become an export error, never unwind an Objective-C exception
/// through the Swift decoder/rendering task.
FOUNDATION_EXPORT NSError * _Nullable BAAudioApplyMetadata(
    AVAssetWriterInput *input,
    BOOL enabled,
    float volume,
    NSString * _Nullable languageCode,
    NSString * _Nullable extendedLanguageTag);

NS_ASSUME_NONNULL_END
