# Video project v3 asset presentation contract

This contract is under implementation. `video_timeline.py` validates its mandatory
metadata independently; the shared JSON reader also accepts v3, while native/app
host loaders still accept v1/v2 only.
It is not proof of playback, Windows execution, output fidelity or completed v3
interoperability. Existing v1 images and v2 page workspaces retain their versions.

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
current Windows host rejects v3 before media access or session replacement until
its canonical decoder clock is verified; this prevents treating top-level video
as v2 pages or applying asset-time edits through the old origin-relative adapter.
The Mac `VideoTimeline` DTO uses exact wide arithmetic compatible with macOS14.
`ProjectJSONTokens` validates original JSON grammar and duplicate decoded keys;
its generic object gate is also used by standalone timeline decoding. Root version
and timeline integer tokens retain lexical strictness while normal edit decimals
remain valid. Neither boundary establishes frame presence or a source clock. The new native
`VideoAssetTimeline` reads exact AVFoundation metadata without origin shifts or
track padding; its caller still owns approved-source identity/SHA protection.

Focused metadata tests:

```sh
python -m unittest Tests.PortableProjectTests.test_video_timeline Tests.PortableProjectTests.test_video_project_v3 -v
python3 scripts/verify_mac.py --suite VideoTimelineTests
python3 scripts/verify_mac.py --suite VideoAssetTimelineTests
```

Actual Mac/PyAV/Qt observations and pending playback/audio/export/legacy integration
are tracked separately in the private QA evidence and project verification docs.
