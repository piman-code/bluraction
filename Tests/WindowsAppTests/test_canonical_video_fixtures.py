"""Actual owned decode of eight authored MOVs; not desktop/audio/P1 proof.

Source hashes, asset descriptors and known-marker PTS bind independent historical
AVFoundation observations. Historical RGB bytes remain in manifest.json; the
explicit pixel-contract-v2 record binds exact accurateRGB bytes from BOTH hosts.
All inputs are public synthetic fixtures with no user media or private paths.
The family runner owns native-call deadlines and process-tree cleanup.
"""
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import unittest

from PySide6.QtGui import QImage
from platforms.windows.bluraction.canonical_video import DecoderAccess, OwnedCanonicalVideoProvider
from platforms.windows.bluraction.frame_inventory import FrameInventory, InventoryLimits
from platforms.windows.bluraction.local_decoder import open_local_decoder
from platforms.windows.bluraction.video import PIXEL_CONTRACT_V2
from shared.video_timeline import rational
from platforms.windows.bluraction.canonical_frames import descriptor_sha256


FIXTURES = Path(__file__).resolve().parents[2] / 'shared/fixtures/video-timelines'
KINDS = ('gap0-vfr', 'nonzero-origin', 'audio-earlier-gap', 'audio-later-gap',
         'video0-audio-negative-quarter', 'video-negative-twelfth-audio0',
         'video-negative-twelfth-audio-negative-quarter', 'video-negative-twelfth-noaudio')
PIXEL_RECORD_SHA256 = '3b061a506b408e90de384b159215d6101f950b5829610315fab82d0017d1eb74'


def expected_at(query, case):
    """Independent half-open oracle from witnessed rows plus asset segments."""
    timeline = case['timeline']
    if query == rational(timeline['assetDuration']):
        return 'EOF', None, None, None
    track = next(t for t in timeline['tracks'] if t['kind'] == 'video')
    last = track['segments'][-1]
    if query >= rational(last['assetStart']) + rational(last['assetDuration']):
        return 'suffix', None, None, None
    segments = [s for s in track['segments'] if rational(s['assetStart']) <= query <
                rational(s['assetStart']) + rational(s['assetDuration'])]
    if len(segments) != 1:
        raise AssertionError('Oracle descriptor has an unrepresented/ambiguous gap')
    segment = segments[0]
    if segment['mediaStart'] is None:
        return 'empty', None, None, None
    left = rational(segment['assetStart'])
    right = left + rational(segment['assetDuration'])
    frames = [(f, rational(f['pts']), min(rational(f['pts']) + rational(f['duration']), right))
              for f in case['frames'] if left <= rational(f['pts']) <= query <
              min(rational(f['pts']) + rational(f['duration']), right)]
    if len(frames) > 1:
        raise AssertionError('Oracle witnessed intervals overlap')
    return ('content', *frames[0]) if frames else ('content-no-sample', None, None, None)


def image_bytes(image):
    if image is None or image.isNull() or (image.width(), image.height()) != (192, 128):
        raise AssertionError('Authored fixture geometry changed')
    image = image.convertToFormat(QImage.Format.Format_RGBA8888)
    memory, stride = image.constBits(), image.bytesPerLine()
    return b''.join(bytes(memory[y * stride:y * stride + 192 * 4]) for y in range(128))


def classify(pixels):
    if any(a != 255 for a in pixels[3::4]):
        raise AssertionError('Opaque authored alpha changed')
    def sums(xs, ys):
        result, count = [0, 0, 0], 0
        for y in ys:
            for x in xs:
                offset = (y * 192 + x) * 4
                for c in range(3):
                    result[c] += pixels[offset + c]
                count += 1
        return result, count
    code = 0
    for bit in range(8):
        value, count = sums(range(20 + bit * 20, 28 + bit * 20), range(44, 52))
        if min(value) > 192 * count:
            code |= 1 << bit
        elif max(value) >= 64 * count:
            raise AssertionError('Ambiguous binary marker; do not choose nearest color')
    if code not in range(17, 25):
        raise AssertionError('Unknown authored marker')
    for xs, ys, channel, lower in ((range(12, 20), range(12, 20), 0, 192),
            (range(172, 180), range(12, 20), 1, 64),
            (range(12, 20), range(108, 116), 2, 192)):
        value, count = sums(xs, ys)
        if value[channel] <= lower * count or any(value[c] >= 64 * count for c in range(3) if c != channel):
            raise AssertionError('Authored direction marker moved or changed')
    return code


class CanonicalVideoFixtureTests(unittest.TestCase):
    def check_case(self, kind):
        manifest_path = FIXTURES / 'manifest.json'
        manifest_before = manifest_path.read_bytes()
        manifest = json.loads(manifest_before)
        pixel_path = FIXTURES / 'manifest-v2.json'
        self.assertFalse(pixel_path.is_symlink())
        pixel_before = pixel_path.read_bytes()
        self.assertEqual(hashlib.sha256(pixel_before).hexdigest(), PIXEL_RECORD_SHA256)
        pixel_manifest = json.loads(pixel_before)
        self.assertEqual(pixel_manifest['schemaVersion'], 2)
        self.assertIs(pixel_manifest['syntheticOnly'], True)
        self.assertEqual(pixel_manifest['historicalManifestSHA256'], hashlib.sha256(manifest_before).hexdigest())
        self.assertEqual(pixel_manifest['pixelContract']['id'], PIXEL_CONTRACT_V2)
        self.assertEqual(pixel_manifest['pixelContract']['inputFormat'], 'yuv420p')
        self.assertEqual(pixel_manifest['pixelContract']['interpolationFlags'], 786434)
        self.assertEqual([c['kind'] for c in pixel_manifest['cases']], list(KINDS))
        self.assertEqual(sum(len(c['frames']) for c in pixel_manifest['cases']), 61)
        self.assertIs(manifest['syntheticOnly'], True)
        self.assertEqual([c['kind'] for c in manifest['cases']], list(KINDS))
        case = next(c for c in manifest['cases'] if c['kind'] == kind)
        pixel_case = next(c for c in pixel_manifest['cases'] if c['kind'] == kind)
        self.assertEqual((pixel_case['file'], pixel_case['sourceSHA256']), (case['file'], case['sourceSHA256']))
        self.assertEqual(len(pixel_case['frames']), len(case['frames']))
        pixels_by_index = {}
        for historical, precise in zip(case['frames'], pixel_case['frames']):
            for key in ('index', 'pts', 'duration', 'markerCode'):
                self.assertEqual(precise[key], historical[key])
            self.assertEqual(precise['historicalMacRGB8SHA256'], historical['visibleRGB8SHA256'])
            self.assertEqual(precise['visibleRGBBytes'], 192 * 128 * 3)
            self.assertNotIn(precise['index'], pixels_by_index)
            pixels_by_index[precise['index']] = precise
        self.assertIs(case['nativeKnownMarkerPTSConfirmed'], True)
        self.assertEqual(case['file'], kind + '.mov')
        source = FIXTURES / case['file']
        self.assertFalse(source.is_symlink())
        original = source.read_bytes()
        self.assertEqual(hashlib.sha256(original).hexdigest(), case['sourceSHA256'])
        inventories = []
        def build_inventory(path, **kwargs):
            inventory = FrameInventory.build(path, **kwargs)
            inventories.append(inventory)
            return inventory
        try:
            with OwnedCanonicalVideoProvider.build(source, expected_sha256=case['sourceSHA256'],
                    generation=11, current_generation=lambda: 11,
                    decoder_access=DecoderAccess(build_inventory, open_local_decoder),
                    limits=InventoryLimits(max_frames=128, max_spool_bytes=1024 * 1024,
                                           max_dimension=256, max_pixels=32768)) as provider:
                self.assertEqual(len(inventories), 1)
                inventory = inventories[0]
                self.assertTrue(inventory.complete)
                before = tuple(inventory)
                self.assertEqual(len(before), len(case['frames']))
                for observed, frame in zip(before, case['frames']):
                    self.assertEqual(observed.pts, rational(frame['pts']))
                    self.assertEqual(observed.duration, rational(frame['duration']))
                timeline = case['timeline']
                self.assertEqual(provider.timeline, timeline)
                self.assertEqual(provider.descriptor_sha256, descriptor_sha256(timeline))
                duration = rational(timeline['assetDuration'])
                self.assertEqual(provider.asset_duration, duration)
                queries = {Fraction(0), duration}
                video = next(t for t in timeline['tracks'] if t['kind'] == 'video')
                for segment in video['segments']:
                    left = rational(segment['assetStart'])
                    right = left + rational(segment['assetDuration'])
                    queries.update((left, right, (left + right) / 2))
                for frame in case['frames']:
                    stamp = rational(frame['pts'])
                    _, selected, left, right = expected_at(stamp, case)
                    self.assertIs(selected, frame)
                    queries.update((left, right, (left + right) / 2))
                selected_end = rational(video['segments'][-1]['assetStart']) + rational(video['segments'][-1]['assetDuration'])
                if selected_end < duration:
                    queries.add((selected_end + duration) / 2)
                for query in sorted(queries) + [rational(case['frames'][0]['pts'])]:
                    with self.subTest(kind=kind, query=str(query)):
                        presence, frame, left, right = expected_at(query, case)
                        result = provider.frame_at(query)
                        self.assertEqual(result.presence, presence)
                        self.assertEqual(result.requested_time, query)
                        self.assertEqual(result.generation, 11)
                        self.assertEqual(result.source_sha256, case['sourceSHA256'])
                        self.assertEqual(result.descriptor_sha256, descriptor_sha256(timeline))
                        if frame is None:
                            self.assertEqual((result.image, result.asset_pts, result.source_index,
                                              result.interval_start, result.interval_end), (None,) * 5)
                        else:
                            self.assertEqual((result.asset_pts, result.source_index, result.interval_start,
                                              result.interval_end), (rational(frame['pts']), frame['index'], left, right))
                            pixels = image_bytes(result.image)
                            self.assertEqual(classify(pixels), frame['markerCode'])
                            rgb = b''.join(pixels[i:i + 3] for i in range(0, len(pixels), 4))
                            # Explicit algorithm change, not a tolerance or
                            # mutation of the original Mac-only RGB oracle.
                            self.assertEqual(hashlib.sha256(rgb).hexdigest(),
                                             pixels_by_index[frame['index']]['visibleRGB8SHA256'])
                            result.image.fill(0)
                            self.assertEqual(image_bytes(provider.frame_at(query).image), pixels)
                self.assertEqual(tuple(inventory), before)
                self.assertTrue(inventory.complete)
            self.assertFalse(inventories[0].complete)
        finally:
            for inventory in inventories:
                inventory.close()
            self.assertEqual(source.read_bytes(), original)
            self.assertEqual(manifest_path.read_bytes(), manifest_before)
            self.assertEqual(pixel_path.read_bytes(), pixel_before)


def case_test(kind):
    def test(self):
        self.check_case(kind)
    return test


for _kind in KINDS:
    setattr(CanonicalVideoFixtureTests, 'test_' + _kind.replace('-', '_'), case_test(_kind))
