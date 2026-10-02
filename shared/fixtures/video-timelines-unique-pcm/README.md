# Unique PCM timeline fixtures

These two synthetic MOVs were authored locally from software MPEG4 video and
mono 8000 Hz signed little-endian 16-bit PCM. They contain no user media. All
9600 audio samples have the distinct value `-10000 + i` for index `i`. Video is
96×64 with eight explicitly authored variable frame timestamps; the manifest
records exact rational times. Neither FPS nor a guessed decoder origin is an
oracle for the audio tests.

| Case | Authored audio start | Actual asset audio edit | Unique content | Historical native Mac PCM |
|---|---|---|---|---|
| positive-quarter | +1/4 | empty `[0,1/4)`, media 0 into asset `[1/4,29/20)` | 9600 samples, index 0…9599 | 2000 zero samples then all 9600 unique samples |
| negative-quarter | −1/4 | media 1/4 into asset `[0,19/20)` | 7600 samples, index 2000…9599 | 7600 unique samples; no leading zeros |

The positive asset duration is 29/20. The negative asset duration is 13/12:
its audio ends at 19/20 and the remainder is an explicit audio suffix. These
are parsed asset descriptors corroborated by the historical native Mac
observer, not an assertion that every demuxer returns timestamps in this
domain. The manifest separately records actual PyAV19 default-applied and
ignore-editlist observations. Ignore-editlist recovers all authored samples
at media time zero; default-applied performs the negative edit's trim.

`manifest.json` is an allowlisted portable projection of the private
preparation/native reports. Only relative file names, source SHA/size,
authorship, rational timeline and bounded count/hash witnesses are retained.
Private paths, PCM file locations, logs and execution folders are omitted.
The MOV files are byte-for-byte copies of the authored sources; their SHA
values are unchanged. No native PCM payload is bundled. The historical
native/full-content hashes allow a new run to compare complete output bytes
with both the unique authored waveform and the recorded native result.

`historicalEvidence` identifies immutable original reports by SHA and the
canonical-audio source SHA used for the prior comparison. That Mac execution
does not automatically validate later source versions or Windows. The new
test family, `test_canonical_audio_unique_fixtures`, uses the full-SHA
`read_samples` API, checks all content bytes, exact sample boundaries,
empty/suffix/EOF tags, input preservation and owned-spool cleanup. An empty
tag has no synthesized sample payload; only the test reconstructs the
historical native zero prefix to compare its full hash.

The distinct samples eliminate the older period-1000 waveform ambiguity:
sample 2000 is −8000, whereas sample 0 is −10000. This witnesses trim origin
for these two exact synthetic sources. It does not prove arbitrary media
clock mapping, audio-device behavior, UI playback, codec redistribution,
HDR, all formats or whole-app/P1 completion. Windows execution remains a
future validation at fixture preparation time.
