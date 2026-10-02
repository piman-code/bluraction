# Video project v3 asset presentation contract

`video_timeline.py` validates the mandatory metadata. The Mac
`VideoProjectFile`/controller and Windows workspace host accept video v3 and save
it with source and timeline bindings. Windows opens it through the verified owned
asset decoder; a shared JSON parse alone cannot authorize that transaction.
Existing v1 images and v2 page workspaces retain their versions. These loader
paths do not establish complete output fidelity, clean-OS installation or
cross-host interoperability; each requires its own executed verification.

Video v3 requires the existing single-media `mediaPath`, `regions`, `drawings`,
plus `version:3`, `mediaKind:"video"`, mandatory original `sourceSHA256`,
`producer:{name:"BlurAction",platform:"macos"|"windows",version:<app version>}`,
and `timeline`. Producer is provenance, never proof of a legacy project's time
basis. Older Mac versions reject v3 instead of ignoring mandatory time metadata.

`timeline` has exactly `version:1`, `basis:"asset-presentation"`, `assetDuration`,
and `tracks`. Each track has `id` (container track ID, not decoder stream index),
`kind` (`video` or `audio`), `mediaTimescale`, and `segments`. Tracks are sorted by
ascending unique ID, with one video and up to sixteen audio tracks. Every segment
contains `assetStart`, `assetDuration`, `mediaStart`, and `rate`. `mediaStart:null`
is a required explicit empty segment; an absent field is invalid. Content media
starts are nonnegative. Segments are contiguous from zero, positive in duration,
ordered, and contained in asset duration. A track may end before the asset ends.
An empty segment's rate is one; positive content rates describe metadata even when
a particular playback adapter cannot yet represent them. No unsupported rate is
silently treated as one. Each track needs content; segment count caps at 4096.

All rational fields use reduced decimal Int64 strings, for example
`{"numerator":"13","denominator":"12"}`. Denominators are positive; zero is
`0/1`. Strings avoid binary64 JSON precision loss. Booleans, float tokens, leading
zeros, `-0`, exponential notation, unreduced fractions, and out-of-range integers
are invalid. Unknown nested timeline fields/bases/versions fail validation.

Existing region/drawing time ranges, keyframes and erasure start numbers keep their
binary64 values. They refer to asset presentation seconds. When applying edits to
a decoded frame, compare using binary64 converted from that frame's exact
canonical presentation PTS. Frame timing is not reconstructed from FPS, a Qt
microsecond timestamp or a rounded slider position. Complete actual PTS indices
are temporary private runtime data rather than project JSON frame arrays.

Source verification requires identity and SHA checks before and after native
inspection, then exact comparison of the canonical, sorted asset descriptor.
Saved segments do not establish a decoder clock mapping. MOV/MP4 `mediaTime`,
FFmpeg edit-list-applied PTS, AVFoundation segment source time, asset presentation
time and native Qt frame timestamps are distinct domains. The FFmpeg MOV
demuxer's edit-list options change the stream index; do not apply the same affine
segment mapping twice. See [FFmpeg MOV demuxer options](https://ffmpeg.org/ffmpeg-formats.html#mov_002fmp4_002f3gp).
`stts` describes decode timing rather than proving presentation PTS.

For old Mac v1 projects, retain numeric edit times as asset times once the source
mapping is independently established. An unlabelled old Windows v1 project's
time meaning cannot be inferred from its path or current host. Ambiguous legacy
temporal edits stay held for a reviewed conversion to a new filename. Source or
descriptor mismatch must fail the candidate transaction while preserving the
active workspace, dirty edits, selection and undo history.

The shared reader retains unknown root/edit fields and requires host review. The
Windows host resolves and verifies the video source, obtains the complete native
asset descriptor, and compares both SHA and exact timeline before replacing the
workspace. Unverified clocks or descriptors fail the candidate transaction.
It dispatches top-level video v3 separately from v2 pages and saves the original
asset-time edit values without applying the old origin-relative adapter.
The Mac `VideoTimeline` DTO uses exact wide arithmetic compatible with macOS14.
`ProjectJSONTokens` validates original JSON grammar and duplicate decoded keys;
its generic object gate is also used by standalone timeline decoding. Root version
and timeline integer tokens retain lexical strictness while normal edit decimals
remain valid. Neither boundary establishes frame presence or a source clock. The new native
`VideoAssetTimeline` reads exact AVFoundation metadata without origin shifts or
track padding; its caller still owns approved-source identity/SHA protection.

Opening and saving a bound project does not prove every media operation uses that
binding. The owned MOV Windows export and tracking paths now consume canonical
sample membership, exact clipped intervals and the asset EOF used by preview.
Export uses a separate owned worker and verifies the encoded result through
complete native video/audio reads before publishing a new file. Content VFR PTS
are retained; declared empty/suffix scenes may add explicit black output samples
at 60 Hz for scene animation, without labelling these as original content frames.
MOV preserves meaningful PCM bytes, rates and active track layouts; MP4 AAC
checks exact decoded sample coverage rather than claiming lossless byte equality.
Tracking starts from the actual displayed PTS and preserves existing keyframes
outside the requested range. Cancellation or incomplete tracking cannot apply a
partial candidate. Local macOS execution of these Windows modules is separate
from actual Windows encoder/transport and clean-OS verification. Those native
checks and general-container, HDR, rate, disabled-track and device/multi-track
capabilities remain explicit gates rather than being inferred from DTO capacity.

The Mac exporter ends its writer session at the source asset's exact CMTime,
using that movie timescale, so encoder packet padding or an inferred final VFR
frame duration cannot extend the asset endpoint. This duration contract does not
establish identical PCM, channel layout or generic format fidelity.

The separate `video-project-roundtrip.yml` workflow transfers only allowlisted
synthetic sources/projects through three native stages: Mac controller emit,
Windows open/edit/undo/redo/save, and Mac controller reopen/save verification.
Its stage-specific reports bind source and payload hashes. An executed Mac emit
stage proves only that first stage; the returned Windows project and completed
Mac verification are needed to claim the full roundtrip. See
[`scripts/video-project-roundtrip/README.md`](../scripts/video-project-roundtrip/README.md)
for the reproducible stage commands. Panel/drop and installed-app user checks
remain separate from those internal controller stages.

Focused metadata tests:

```sh
python -m unittest Tests.PortableProjectTests.test_video_timeline Tests.PortableProjectTests.test_video_project_v3 -v
python3 scripts/verify_mac.py --suite VideoTimelineTests
python3 scripts/verify_mac.py --suite VideoAssetTimelineTests
```

Actual Mac/PyAV/Qt observations and pending playback/audio/export/legacy integration
are tracked separately in the private QA evidence and project verification docs.
