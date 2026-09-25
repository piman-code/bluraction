import AVFoundation
import Testing
@testable import BlurAction

struct VideoInputSafetyTests {
    @Test
    func selectedMovieCannotResolveOutsideMediaReferences() {
        let asset = VideoAssetPolicy.asset(url: URL(fileURLWithPath: "/private/tmp/local-movie.mov"))
        #expect(asset.referenceRestrictions == .forbidAll)
    }

    @Test
    func videoDimensionsAreBoundedBeforePreview() throws {
        try DocumentModel.validateVideoDimensions(size: CGSize(width: 7680, height: 4320), transform: .identity)
        #expect(throws: DocumentModel.LoadError.videoTooLarge) {
            try DocumentModel.validateVideoDimensions(size: CGSize(width: 8192, height: 4320), transform: .identity)
        }
        #expect(throws: DocumentModel.LoadError.videoTooLarge) {
            try DocumentModel.validateVideoDimensions(size: CGSize(width: 960, height: 540),
                                                     transform: CGAffineTransform(scaleX: 20, y: 1))
        }
        #expect(throws: DocumentModel.LoadError.noVideo) {
            try DocumentModel.validateVideoDimensions(size: CGSize(width: CGFloat.infinity, height: 540), transform: .identity)
        }
    }
}
