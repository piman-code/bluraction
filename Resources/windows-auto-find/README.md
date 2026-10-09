# Windows automatic face/text finding resources

These resources are loaded locally. Finding and tracking do not download models
or transmit the source media. Face finding detects face areas, not identity.

OpenCV Zoo reference: revision `47534e27c9851bb1128ccc0102f1145e27f23f98`.

| File | SHA-256 | License |
|---|---|---|
| face_detection_yunet_2023mar.onnx | 8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4 | MIT, see YuNet-LICENSE.txt |
| text_detection_cn_ppocrv3_2023may.onnx | 03f550c6b406fda8bf54bd8327815f6c7e2edd98cea02348c93d879254366587 | Apache-2.0, see PPOCR-LICENSE.txt |

Model sources:

- https://github.com/opencv/opencv_zoo/tree/47534e27c9851bb1128ccc0102f1145e27f23f98/models/face_detection_yunet
- https://github.com/opencv/opencv_zoo/tree/47534e27c9851bb1128ccc0102f1145e27f23f98/models/text_detection_ppocr

PP-OCRv3 examines the whole image and overlapping tiles, with an additional
contrast pass for small text. Nearby, similarly sized word areas on one baseline
are joined into lines to cover missing interior words. Wide column gaps stay
separate. All detection runs inside the application; no language pack or
external OCR process is required.

Behavior reference: BlurAction Mac branch `codex/multipage-document-blur`,
commit `2c2c6aa601766c6d0f3a360afecb2d9d5673ca1a`, AutoDetector.swift and
ObjectTracker.swift. The Windows implementation uses OpenCV CSRT and stores
actual source presentation timestamps in the existing portable project format.

Face recovery is restricted to regions named `찾은 얼굴`, nearby unambiguous
faces and at most 1.5 seconds since the last tracked frame. It does not prove
identity or complete masking. Review the entire output before sharing.
