#import "BlurActionMediaSafety.h"
#import <AVFoundation/AVFoundation.h>
#include <math.h>

NSError * _Nullable BAAudioApplyMetadata(AVAssetWriterInput *input, BOOL enabled,
    float volume, NSString * _Nullable languageCode, NSString * _Nullable extendedLanguageTag) {
    if (!isfinite(volume)) {
        return [NSError errorWithDomain:@"local.piman.BlurAction.AudioMetadata" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"원본 오디오의 볼륨 정보가 올바르지 않습니다."}];
    }
    @try {
        input.marksOutputTrackAsEnabled = enabled;
        input.preferredVolume = volume;
        input.languageCode = languageCode;
        input.extendedLanguageTag = extendedLanguageTag;
        return nil;
    } @catch (NSException *exception) {
        // No Swift closure is invoked inside this boundary. Do not disclose or
        // silently replace the original media's language/presentation metadata.
        return [NSError errorWithDomain:@"local.piman.BlurAction.AudioMetadata" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"원본 오디오의 재생·언어 정보를 보존할 수 없습니다.",
                @"exceptionName": exception.name}];
    }
}
