"""Default spawned transport against ten public authored MOVs.

No injected decoder target, fake session, audio device or desktop input. These
checks bind asset PTS, witnessed markers, exact PCM, validation and owned-process
cleanup. They do not prove RGB pixel parity, a Windows device, v3 or whole UI.
The family runner must supply its outer process-tree deadline (120 seconds).
"""
from fractions import Fraction
import hashlib
import json
import multiprocessing
import os
from pathlib import Path
import struct
import unittest

from platforms.windows.bluraction.canonical_frames import descriptor_sha256
from platforms.windows.bluraction.canonical_transport import (
    CanonicalSession, PCMPlaybackPlan, TransportReview,
)
from shared.video_timeline import rational


ROOT = Path(__file__).resolve().parents[2] / 'shared/fixtures'
KINDS = ('gap0-vfr', 'nonzero-origin', 'audio-earlier-gap', 'audio-later-gap',
         'video0-audio-negative-quarter', 'video-negative-twelfth-audio0',
         'video-negative-twelfth-audio-negative-quarter', 'video-negative-twelfth-noaudio')
UNIQUE = ('unique-pcm-positive-quarter', 'unique-pcm-negative-quarter')
MANIFESTS = {
    'video-timelines': 'f1779cbc24d9f7a0451b182e028f587db1113f5f605ae80f22b6efa0d5a45f0f',
    'video-timelines-unique-pcm': '645b3eda2a866e14bfe8e649881a8a5a600c1ecdad642e4a471ca91e1bf60811',
}


def segment_at(track, stamp):
    matches = [s for s in track['segments'] if rational(s['assetStart']) <= stamp <
               rational(s['assetStart']) + rational(s['assetDuration'])]
    if len(matches) != 1:
        raise AssertionError('Authored descriptor lacks one represented interval')
    return matches[0]


def video_at(case, stamp):
    duration = rational(case['timeline']['assetDuration'])
    if stamp == duration:
        return 'EOF', None, None
    video = next(t for t in case['timeline']['tracks'] if t['kind'] == 'video')
    end = rational(video['segments'][-1]['assetStart']) + rational(video['segments'][-1]['assetDuration'])
    if stamp >= end:
        return 'suffix', None, None
    segment = segment_at(video, stamp)
    if segment['mediaStart'] is None:
        return 'empty', None, None
    left = rational(segment['assetStart'])
    right = left + rational(segment['assetDuration'])
    rows = [f for f in case['frames'] if left <= rational(f['pts']) <= stamp <
            min(rational(f['pts']) + rational(f['duration']), right)]
    if len(rows) != 1:
        raise AssertionError('Witness has no unique actual frame at query')
    frame = rows[0]
    return 'content', frame, min(rational(frame['pts']) + rational(frame['duration']), right)


def marker(pixels):
    """Known binary/direction witness; no nearest-color or RGB SHA oracle."""
    def sums(xs, ys):
        values, count = [0, 0, 0], 0
        for y in ys:
            for x in xs:
                offset = (y * 192 + x) * 4
                for c in range(3):
                    values[c] += pixels[offset + c]
                count += 1
        return values, count
    code = 0
    for bit in range(8):
        values, count = sums(range(20 + bit * 20, 28 + bit * 20), range(44, 52))
        if min(values) > 192 * count:
            code |= 1 << bit
        elif max(values) >= 64 * count:
            raise AssertionError('Ambiguous binary marker')
    if code not in range(17, 25):
        raise AssertionError('Unknown witnessed marker')
    for xs, ys, channel, minimum in ((range(12, 20), range(12, 20), 0, 192),
            (range(172, 180), range(12, 20), 1, 64),
            (range(12, 20), range(108, 116), 2, 192)):
        values, count = sums(xs, ys)
        if values[channel] <= minimum * count or any(values[c] >= 64 * count
                                                    for c in range(3) if c != channel):
            raise AssertionError('Authored direction marker changed')
    return code


def authored(first, count, unique):
    values = [-10000 + i if unique else ((i * 31) % 1000) - 500
              for i in range(first, first + count)]
    return struct.pack('<' + 'h' * count, *values)


class CanonicalTransportFixtureTests(unittest.TestCase):
    def check_pixels(self, meta, buffers, size):
        self.assertEqual((meta['width'], meta['height']), size)
        self.assertEqual(len(buffers), 1)
        pixels = buffers[0]
        self.assertEqual(len(pixels), size[0] * size[1] * 4)
        self.assertTrue(all(a == 255 for a in pixels[3::4]))
        return pixels

    def check_video(self, session, case, unique):
        timeline = case['timeline']
        video = next(t for t in timeline['tracks'] if t['kind'] == 'video')
        queries = {Fraction(0), session.duration}
        for segment in video['segments']:
            start = rational(segment['assetStart'])
            end = start + rational(segment['assetDuration'])
            queries.update((start, end, (start + end) / 2))
        end = rational(video['segments'][-1]['assetStart']) + rational(video['segments'][-1]['assetDuration'])
        if end < session.duration:
            queries.add((end + session.duration) / 2)
        if unique:
            # This manifest witnesses authored PTS, not marker RGB/durations.
            stamps = tuple(rational(t) for t in case['author']['videoPTS'])
            queries.update(stamps)
            expected_first = stamps[0]
        else:
            self.assertIs(case['nativeKnownMarkerPTSConfirmed'], True)
            expected_first = rational(case['frames'][0]['pts'])
            for row in case['frames']:
                start = rational(row['pts'])
                _, _, right = video_at(case, start)
                queries.update((start, right, (start + right) / 2))
        self.assertEqual(session.first_time, expected_first)
        self.assertLessEqual(len(queries), 128)
        # A backwards request after EOF exercises a real seek/cache transition.
        for query in sorted(queries) + [expected_first]:
            with self.subTest(query=str(query)):
                meta, buffers = session.frame(query)
                self.assertEqual((meta['kind'], meta['requested'], meta['sha256']),
                                 ('frame', query, case['sourceSHA256']))
                if unique:
                    if query == session.duration:
                        presence, frame, right = 'EOF', None, None
                    elif query >= end:
                        presence, frame, right = 'suffix', None, None
                    else:
                        # Unique fixtures contain no leading/inner empty video edit.
                        segment = segment_at(video, query)
                        self.assertIsNotNone(segment['mediaStart'])
                        presence, frame, right = 'content', None, None
                else:
                    presence, frame, right = video_at(case, query)
                self.assertEqual(meta['presence'], presence)
                if presence != 'content':
                    self.assertEqual((meta['time'], meta['intervalEnd'], buffers), (None, None, ()))
                    self.assertNotIn('width', meta)
                    self.assertNotIn('height', meta)
                    continue
                self.assertIs(type(meta['time']), Fraction)
                self.assertIs(type(meta['intervalEnd']), Fraction)
                self.assertLessEqual(meta['time'], query)
                self.assertGreater(meta['intervalEnd'], query)
                self.assertLessEqual(meta['intervalEnd'], end)
                size = tuple(case['author']['videoSize']) if unique else (192, 128)
                pixels = self.check_pixels(meta, buffers, size)
                if unique:
                    if query in stamps:
                        self.assertEqual(meta['time'], query)
                    self.assertIn(meta['time'], stamps)
                else:
                    self.assertEqual((meta['time'], meta['intervalEnd']), (rational(frame['pts']), right))
                    self.assertEqual(marker(pixels), frame['markerCode'])

    def check_pcm(self, session, case, unique):
        tracks = [t for t in case['timeline']['tracks'] if t['kind'] == 'audio']
        infos = session.metadata['audioTracks']
        self.assertEqual(tuple(t['track_id'] for t in infos), tuple(t['id'] for t in tracks))
        if not tracks:
            self.assertEqual(infos, ())
            return  # No audio device or manufactured no-audio PCM.
        self.assertEqual(len(tracks), 1)
        track, info = tracks[0], infos[0]
        fmt = info['format']
        self.assertEqual((fmt['name'], fmt['sample_rate'], fmt['bytes_per_sample'],
                          fmt['planar'], tuple(fmt['channels']), fmt['byte_order']),
                         ('s16', 8000, 2, False, ('FC',), 'little'))
        self.assertGreater(info['raw_frame_count'], 0)
        plan = PCMPlaybackPlan(session, Fraction(0))
        self.assertEqual(plan.anchor, Fraction(0))
        output, content = bytearray(), bytearray()
        content_count = empty_count = 0
        finished = False
        for _ in range(128):
            before = plan.cursor
            data, after, finished = plan.next_block(count=4096)
            if finished:
                self.assertEqual((data, after), (b'', before))
                break
            self.assertTrue(data)
            self.assertEqual(len(data) % 2, 0)
            count = len(data) // 2
            self.assertTrue(0 < count <= 4096)
            self.assertEqual(after, before + Fraction(count, 8000))
            segment = segment_at(track, before)
            start = rational(segment['assetStart'])
            end = start + rational(segment['assetDuration'])
            self.assertLessEqual(after, end)
            if segment['mediaStart'] is None:
                self.assertEqual(data, bytes(count * 2))
                empty_count += count
            else:
                origin = (rational(segment['mediaStart']) + before - start) * 8000
                self.assertEqual(origin.denominator, 1)
                self.assertEqual(data, authored(origin.numerator, count, unique))
                content.extend(data)
                content_count += count
            output.extend(data)
        self.assertTrue(finished, 'Bounded PCM schedule must reach declared suffix/EOF')
        audio_end = rational(track['segments'][-1]['assetStart']) + rational(track['segments'][-1]['assetDuration'])
        expected_content = sum(rational(s['assetDuration']) * 8000 for s in track['segments']
                               if s['mediaStart'] is not None)
        expected_empty = sum(rational(s['assetDuration']) * 8000 for s in track['segments']
                             if s['mediaStart'] is None)
        self.assertEqual((content_count, empty_count), (expected_content, expected_empty))
        self.assertEqual((plan.samples, plan.cursor), (content_count + empty_count, audio_end))
        self.assertEqual(info['scheduled_samples'], content_count)
        self.assertEqual(plan.next_block(), (b'', audio_end, True))
        # A fresh seek plan after EOF must retrieve the first *observed* sample
        # of each content edit, including a nonzero asset start/trimmed source.
        for segment in track['segments']:
            if segment['mediaStart'] is None:
                continue
            start = rational(segment['assetStart'])
            origin = rational(segment['mediaStart']) * 8000
            self.assertEqual(origin.denominator, 1)
            seek_plan = PCMPlaybackPlan(session, start)
            self.assertEqual(seek_plan.anchor, start)
            self.assertEqual(seek_plan.next_block(count=1),
                             (authored(origin.numerator, 1, unique), start + Fraction(1, 8000), False))
        if audio_end < session.duration:
            meta, buffers = session.audio(track['id'], audio_end)
            self.assertEqual((meta['chunk'].presence, meta['chunk'].samples, buffers), ('suffix', 0, ()))
        meta, buffers = session.audio(track['id'], session.duration)
        self.assertEqual((meta['chunk'].presence, meta['chunk'].samples, buffers), ('EOF', 0, ()))
        if unique:
            witness = case['nativeMacPCM']
            self.assertIs(witness['completeEOF'], True)
            origin = 0 if case['kind'] == UNIQUE[0] else 2000
            self.assertEqual(witness['firstAuthoredSampleIndex'], origin)
            self.assertEqual(bytes(content), authored(origin, content_count, True))
            self.assertEqual(struct.unpack('<h', content[:2])[0], -10000 + origin)
            self.assertEqual((content_count, empty_count, plan.samples),
                             (witness['contentSamples'], witness['leadingZeroSamples'], witness['sampleCount']))
            self.assertEqual(hashlib.sha256(content).hexdigest(), witness['contentPCM_SHA256'])
            self.assertEqual(hashlib.sha256(output).hexdigest(), witness['fullPCM_SHA256'])

    def check_case(self, kind):
        unique = kind in UNIQUE
        folder = 'video-timelines-unique-pcm' if unique else 'video-timelines'
        directory = ROOT / folder
        manifest = directory / 'manifest.json'
        self.assertFalse(directory.is_symlink())
        self.assertFalse(manifest.is_symlink())
        manifest_before = manifest.read_bytes()
        self.assertEqual(hashlib.sha256(manifest_before).hexdigest(), MANIFESTS[folder])
        document = json.loads(manifest_before)
        self.assertEqual(tuple(c['kind'] for c in document['cases']), UNIQUE if unique else KINDS)
        if not unique:
            self.assertIs(document['syntheticOnly'], True)
        case = next(c for c in document['cases'] if c['kind'] == kind)
        self.assertEqual(case['file'], kind + '.mov')
        source = directory / case['file']
        self.assertFalse(source.is_symlink())
        self.assertEqual(source.resolve().parent, directory.resolve())
        source_before = source.read_bytes()
        self.assertEqual(hashlib.sha256(source_before).hexdigest(), case['sourceSHA256'])
        session = None
        work = pid = None
        try:
            # OMIT _decoder_target: this is the actual production spawned decoder.
            session = CanonicalSession(source, case['sourceSHA256'], build_timeout=10, query_timeout=10)
            pid, work = session._process.pid, Path(session._directory.name)
            self.assertNotEqual(pid, os.getpid())
            self.assertTrue(session._process.is_alive())
            self.assertTrue(work.is_dir())
            self.assertEqual(session.metadata['timeline'], case['timeline'])
            self.assertEqual(session.metadata['descriptorSHA256'], descriptor_sha256(case['timeline']))
            self.assertEqual(session.metadata['sha256'], case['sourceSHA256'])
            self.assertEqual(session.duration, rational(case['timeline']['assetDuration']))
            self.check_video(session, case, unique)
            self.check_pcm(session, case, unique)
            session.validate()  # Full source SHA transaction before closing owned resources.
        finally:
            try:
                if session is not None:
                    session.close()
                    session.close()
                    self.assertIsNone(session._process)
                    self.assertIsNone(session._directory)
                    self.assertFalse(work.exists())
                    self.assertNotIn(pid, [child.pid for child in multiprocessing.active_children()])
                    with self.assertRaises(TransportReview):
                        session.frame(Fraction(0))
            finally:
                self.assertEqual(source.read_bytes(), source_before)
                self.assertEqual(manifest.read_bytes(), manifest_before)


for _kind in KINDS + UNIQUE:
    def _test(self, kind=_kind):
        self.check_case(kind)
    setattr(CanonicalTransportFixtureTests, 'test_' + _kind.replace('-', '_'), _test)
