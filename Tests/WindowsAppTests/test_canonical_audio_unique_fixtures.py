"""Two authored unique PCM MOVs: exact samples/edits, not whole-app proof.

Historical native Mac PCM witnesses identify trim sample 2000 unambiguously:
sample 0 is -10000 and sample 2000 is -8000. The family runner supplies the
native deadline/process ownership. Missing decoders are failures, not skips.
"""
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import struct
import unittest

from platforms.windows.bluraction.canonical_audio import (
    AudioLimits, CanonicalAudioReview, OwnedCanonicalAudioProvider,
)
from shared.video_timeline import rational


FIXTURES = Path(__file__).resolve().parents[2] / 'shared/fixtures/video-timelines-unique-pcm'
MANIFEST_SHA256 = '645b3eda2a866e14bfe8e649881a8a5a600c1ecdad642e4a471ca91e1bf60811'
KINDS = ('unique-pcm-positive-quarter', 'unique-pcm-negative-quarter')


def authored(first, count):
    return struct.pack('<' + 'h' * count, *[-10000 + i for i in range(first, first + count)])


class UniqueAudioFixtures(unittest.TestCase):
    def check_case(self, kind):
        manifest = FIXTURES / 'manifest.json'
        manifest_before = manifest.read_bytes()
        self.assertEqual(hashlib.sha256(manifest_before).hexdigest(), MANIFEST_SHA256)
        document = json.loads(manifest_before)
        self.assertEqual(tuple(c['kind'] for c in document['cases']), KINDS)
        case = next(c for c in document['cases'] if c['kind'] == kind)
        self.assertEqual(case['file'], kind + '.mov')
        source = FIXTURES / case['file']
        source_before = source.read_bytes()
        self.assertEqual(len(source_before), case['sourceBytes'])
        self.assertEqual(hashlib.sha256(source_before).hexdigest(), case['sourceSHA256'])
        witness = case['nativeMacPCM']
        self.assertTrue(witness['completeEOF'])
        self.assertEqual(case['author']['waveform'], '-10000+i')
        self.assertEqual(case['author']['audioSamples'], 9600)
        expected_origin, expected_content, expected_empty = (
            (0, 9600, 2000) if kind == KINDS[0] else (2000, 7600, 0))
        self.assertEqual((witness['firstAuthoredSampleIndex'], witness['contentSamples'],
                          witness['leadingZeroSamples']),
                         (expected_origin, expected_content, expected_empty))
        timeline = case['timeline']
        provider = None
        directory = None
        try:
            provider = OwnedCanonicalAudioProvider.build(
                source, expected_sha256=case['sourceSHA256'], generation=7,
                current_generation=lambda: 7, expected_timeline=timeline,
                decoder_clock_mode='ffmpeg-editlist-applied',
                limits=AudioLimits(max_frames=128, max_spool_bytes=1024 * 1024,
                                   max_frame_bytes=256 * 1024))
            directory = Path(provider._directory.name)
            self.assertEqual(provider.timeline, timeline)
            self.assertEqual(provider.asset_duration, rational(timeline['assetDuration']))
            tracks = [t for t in timeline['tracks'] if t['kind'] == 'audio']
            self.assertEqual(len(tracks), 1)
            track = tracks[0]
            self.assertEqual(track['id'], 2)
            self.assertEqual(len(provider.tracks), 1)
            info = provider.tracks[0]
            self.assertEqual(info.track_id, track['id'])
            self.assertEqual((info.format.name, info.format.sample_rate,
                              info.format.bytes_per_sample, info.format.planar,
                              len(info.format.channels), info.format.byte_order),
                             ('s16', 8000, 2, False, 1, 'little'))
            self.assertGreater(info.raw_frame_count, 0)  # A completed actual decode, not a fabricated silence inventory.
            content = bytearray()
            native_reconstructed = bytearray()
            calls = 0
            for segment in track['segments']:
                start = rational(segment['assetStart'])
                end = start + rational(segment['assetDuration'])
                count = (end - start) * 8000
                self.assertEqual(count.denominator, 1)
                if segment['mediaStart'] is None:
                    for query in (start, (start + end) / 2, end - Fraction(1, 8000)):
                        row = provider.read_samples(track['id'], query)
                        self.assertEqual((row.presence, row.samples, row.planes), ('empty', 0, ()))
                        self.assertEqual((row.interval_start, row.interval_end), (start, end))
                    native_reconstructed.extend(bytes(count.numerator * 2))
                    continue
                origin = rational(segment['mediaStart']) * 8000
                self.assertEqual(origin.denominator, 1)
                self.assertEqual(origin.numerator, expected_origin)
                query = start
                offset = 0
                segment_bytes = bytearray()
                while query < end:
                    calls += 1
                    self.assertLessEqual(calls, 128)
                    row = provider.read_samples(track['id'], query, max_samples=4096)
                    self.assertEqual((row.presence, row.requested_time, row.generation), ('content', query, 7))
                    self.assertEqual(row.source_sha256, case['sourceSHA256'])
                    self.assertEqual(row.descriptor_sha256, provider.descriptor_sha256)
                    self.assertTrue(0 < row.samples <= min(4096, count.numerator - offset))
                    self.assertEqual(row.planes, (authored(origin.numerator + offset, row.samples),))
                    observation = provider.observation(track['id'], row.source_frame_index)
                    self.assertEqual(row.asset_pts, observation.pts)
                    self.assertEqual(query, observation.pts + Fraction(row.source_sample_offset, 8000))
                    self.assertEqual((row.interval_start, row.interval_end),
                                     (query, query + Fraction(row.samples, 8000)))
                    self.assertLessEqual(row.interval_end, end)
                    segment_bytes.extend(row.planes[0])
                    query = row.interval_end
                    offset += row.samples
                self.assertEqual((query, offset), (end, count.numerator))
                self.assertEqual(bytes(segment_bytes), authored(expected_origin, expected_content))
                # Exact first/last sample queries exercise both half-open edit boundaries.
                self.assertEqual(provider.read_samples(track['id'], start, 1).planes,
                                 (authored(expected_origin, 1),))
                self.assertEqual(provider.read_samples(track['id'], end - Fraction(1, 8000), 1).planes,
                                 (authored(expected_origin + expected_content - 1, 1),))
                content.extend(segment_bytes)
                native_reconstructed.extend(segment_bytes)
            self.assertEqual(info.scheduled_samples, expected_content)
            self.assertEqual(len(content) // 2, expected_content)
            self.assertEqual(hashlib.sha256(content).hexdigest(), witness['contentPCM_SHA256'])
            self.assertEqual(len(native_reconstructed) // 2, witness['sampleCount'])
            self.assertEqual(hashlib.sha256(native_reconstructed).hexdigest(), witness['fullPCM_SHA256'])
            # This is historical native byte parity for these exact sources. An empty
            # edit remains an explicit tag; production never fabricates PCM above.
            audio_end = rational(track['segments'][-1]['assetStart']) + rational(track['segments'][-1]['assetDuration'])
            if audio_end < provider.asset_duration:
                row = provider.read_samples(track['id'], audio_end)
                self.assertEqual((row.presence, row.samples, row.planes), ('suffix', 0, ()))
                self.assertEqual((row.interval_start, row.interval_end), (audio_end, provider.asset_duration))
            else:
                self.assertEqual(audio_end, provider.asset_duration)
            eof = provider.read_samples(track['id'], provider.asset_duration)
            self.assertEqual((eof.presence, eof.samples, eof.planes), ('EOF', 0, ()))
            self.assertEqual((eof.interval_start, eof.interval_end), (provider.asset_duration,) * 2)
            provider.close()
            provider.close()
            self.assertFalse(directory.exists())
            with self.assertRaises(CanonicalAudioReview):
                provider.read_samples(track['id'], Fraction(0))
        finally:
            try:
                if provider is not None:
                    provider.close()
                    self.assertFalse(directory.exists())
            finally:
                self.assertEqual(source.read_bytes(), source_before)
                self.assertEqual(manifest.read_bytes(), manifest_before)

    def test_positive_quarter_empty_then_unique_sample_zero(self):
        self.check_case(KINDS[0])

    def test_negative_quarter_exact_unique_trim_2000_and_suffix(self):
        self.check_case(KINDS[1])
