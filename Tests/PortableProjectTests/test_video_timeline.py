import copy
from fractions import Fraction
import unittest

from shared.video_timeline import (VideoTimelineError, encode_rational, rational,
                                   validate_video_metadata, verify_asset_descriptor)


def number(n, d=1):
    return encode_rational(Fraction(n, d))


def fixture():
    return {'version': 3, 'mediaKind': 'video', 'sourceSHA256': 'a' * 64,
            'producer': {'name': 'BlurAction', 'platform': 'macos', 'version': '0.8.0'},
            'timeline': {'version': 1, 'basis': 'asset-presentation', 'assetDuration': number(39, 20),
                         'tracks': [{'id': 1, 'kind': 'video', 'mediaTimescale': 12288,
                                     'segments': [{'assetStart': number(0), 'assetDuration': number(1, 2), 'mediaStart': None, 'rate': number(1)},
                                                  {'assetStart': number(1, 2), 'assetDuration': number(13, 12), 'mediaStart': number(0), 'rate': number(1)}]},
                                    {'id': 2, 'kind': 'audio', 'mediaTimescale': 8000,
                                     'segments': [{'assetStart': number(0), 'assetDuration': number(3, 4), 'mediaStart': None, 'rate': number(1)},
                                                  {'assetStart': number(3, 4), 'assetDuration': number(6, 5), 'mediaStart': number(0), 'rate': number(1)}]}]}}


class VideoTimelineTests(unittest.TestCase):
    def test_leading_gap_and_audio_suffix_are_explicit_without_retiming(self):
        project = fixture(); before = copy.deepcopy(project)
        validate_video_metadata(project)
        verify_asset_descriptor(project, source_sha256='a' * 64, observed_timeline=copy.deepcopy(project['timeline']))
        self.assertEqual(project, before)

    def test_fingerprint_or_exact_segment_mismatch_cannot_be_trusted(self):
        p = fixture()
        with self.assertRaises(VideoTimelineError):
            verify_asset_descriptor(p, source_sha256='b' * 64, observed_timeline=p['timeline'])
        altered = copy.deepcopy(p['timeline'])
        altered['tracks'][0]['segments'][1]['mediaStart'] = number(1, 12)
        with self.assertRaises(VideoTimelineError):
            verify_asset_descriptor(p, source_sha256='a' * 64, observed_timeline=altered)

    def test_track_order_is_canonical_container_id_not_native_enumeration(self):
        p = fixture(); p['timeline']['tracks'].reverse()
        with self.assertRaises(VideoTimelineError):
            validate_video_metadata(p)
        p['timeline']['tracks'].sort(key=lambda track: track['id'])
        validate_video_metadata(p)

    def test_wire_rational_preserves_int64_precision_and_rejects_float_bool(self):
        for n in [0, 1, -1, (1 << 63) - 1, -(1 << 63)]:
            self.assertEqual(rational(number(n)), Fraction(n))
        for n in [1, True, 1.0, '01', '+1', '-0', '1e0', ' 1', str(1 << 63), str(-(1 << 63)-1)]:
            with self.subTest(n=n), self.assertRaises(VideoTimelineError):
                rational({'numerator': n, 'denominator': '1'})
        for d in ['0', '-1', '01', True, 1, '9223372036854775808']:
            with self.subTest(d=d), self.assertRaises(VideoTimelineError):
                rational({'numerator': '1', 'denominator': d})
        with self.assertRaises(VideoTimelineError):
            rational({'numerator': '2', 'denominator': '4'})

    def test_unknown_time_bases_versions_fields_and_missing_envelope_fail(self):
        changes = [('mediaKind', 'image'), ('version', True), ('version', 3.0), ('sourceSHA256', None), ('sourceSHA256', 'A'*64)]
        for key, value in changes:
            p = fixture(); p[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(VideoTimelineError):
                validate_video_metadata(p)
        for key, value in [('basis', 'qt-origin'), ('version', 2), ('rawOrigin', number(0))]:
            p = fixture(); p['timeline'][key] = value
            with self.subTest(key=key), self.assertRaises(VideoTimelineError):
                validate_video_metadata(p)
        for key in ['producer', 'timeline', 'sourceSHA256']:
            p = fixture(); del p[key]
            with self.assertRaises(VideoTimelineError):
                validate_video_metadata(p)

    def test_asset_bounds_track_identity_and_segment_contiguity(self):
        for mutate in [lambda p: p['timeline'].update(assetDuration=number(0)),
                       lambda p: p['timeline']['tracks'][1].update(id=1),
                       lambda p: p['timeline']['tracks'][0].update(id=True),
                       lambda p: p['timeline']['tracks'][0].update(mediaTimescale=0),
                       lambda p: p['timeline']['tracks'][1].update(kind='video'),
                       lambda p: p['timeline']['tracks'][0]['segments'][1].update(assetStart=number(1)),
                       lambda p: p['timeline']['tracks'][0]['segments'][1].update(assetDuration=number(4)),
                       lambda p: p['timeline']['tracks'][0]['segments'][1].update(mediaStart=number(-1)),
                       lambda p: p['timeline']['tracks'][0]['segments'][0].update(rate=number(2))]:
            p = fixture(); mutate(p)
            with self.subTest(p=p), self.assertRaises(VideoTimelineError):
                validate_video_metadata(p)

    def test_multiple_trim_segments_and_rate_remain_metadata_not_decoder_policy(self):
        p = fixture(); segment = p['timeline']['tracks'][0]['segments'][1]
        segment.update(assetDuration=number(1, 2), mediaStart=number(1, 12), rate=number(2))
        p['timeline']['tracks'][0]['segments'].append({'assetStart': number(1), 'assetDuration': number(7, 12), 'mediaStart': number(3), 'rate': number(1)})
        validate_video_metadata(p)
        self.assertEqual(p['timeline']['tracks'][0]['segments'][1]['mediaStart'], number(1, 12))

    def test_track_and_segment_limits_do_not_accept_partial_descriptors(self):
        p = fixture(); p['timeline']['tracks'] *= 9
        with self.assertRaises(VideoTimelineError):
            validate_video_metadata(p)
        p = fixture(); p['timeline']['tracks'][0]['segments'] *= 2049
        with self.assertRaises(VideoTimelineError):
            validate_video_metadata(p)


if __name__ == '__main__':
    unittest.main()
