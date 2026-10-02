import Testing
import AVFoundation
import BlurActionMediaSafety

@Suite(.serialized)
final class AudioMetadataSafetyTests {
    @Test
    func testActualNilAndKoreanMetadataPreservePresentationValues() throws {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
        #expect(BAAudioApplyMetadata(input, true, 1, nil, nil) == nil)
        #expect(input.languageCode == nil)
        #expect(input.extendedLanguageTag == nil)
        #expect(BAAudioApplyMetadata(input, false, 0.375, "kor", "ko-KR") == nil)
        #expect(input.marksOutputTrackAsEnabled == false)
        #expect(input.preferredVolume == 0.375)
        #expect(input.languageCode == "kor")
        #expect(input.extendedLanguageTag == "ko-KR")
    }

    @Test
    func testNonfiniteSourceVolumeFailsBeforeMutatingWriterInput() throws {
        for volume in [Float.nan, .infinity, -.infinity] {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            let error = try #require(BAAudioApplyMetadata(input, false, volume, "kor", "ko-KR")) as NSError
            #expect(error.domain == "local.piman.BlurAction.AudioMetadata")
            #expect(error.code == 1)
            #expect(input.marksOutputTrackAsEnabled)
            #expect(input.preferredVolume == 1)
            #expect(input.languageCode == nil)
        }
    }

    @Test
    func testNativeInvalidLanguageExceptionReturnsExportErrorWithoutSwiftUnwinding() throws {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
        let error = try #require(BAAudioApplyMetadata(input, true, 1, "invalid-language-code", nil)) as NSError
        #expect(error.domain == "local.piman.BlurAction.AudioMetadata")
        #expect(error.code == 2)
        #expect(error.userInfo["exceptionName"] as? String == "NSInvalidArgumentException")
    }

    @Test
    func testNativeInvalidExtendedTagExceptionReturnsExportErrorWithoutSwiftUnwinding() throws {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
        let error = try #require(BAAudioApplyMetadata(input, true, 1, "kor", "!!!!!")) as NSError
        #expect(error.domain == "local.piman.BlurAction.AudioMetadata")
        #expect(error.code == 2)
        #expect(error.userInfo["exceptionName"] as? String == "NSInvalidArgumentException")
    }

    @Test
    func testLegacyTagRemainsExactOrProducesTheNativeMetadataError() {
        // macOS 27 accepts this spelling; an older native validator may reject
        // it. Preserve every accepted source value, or return the actual native
        // exception as an error. Neither normalization nor silent omission is
        // an acceptable alternative, and acceptance is not BCP47 certification.
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
        if let error = BAAudioApplyMetadata(input, true, 1, "kor", "ko_%%%_KR") {
            let nativeError = error as NSError
            #expect(nativeError.domain == "local.piman.BlurAction.AudioMetadata")
            #expect(nativeError.code == 2)
            #expect(nativeError.userInfo["exceptionName"] as? String == "NSInvalidArgumentException")
            #expect(input.extendedLanguageTag == nil)
        } else {
            #expect(input.extendedLanguageTag == "ko_%%%_KR")
        }
    }
}
