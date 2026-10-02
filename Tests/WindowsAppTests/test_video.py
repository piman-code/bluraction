"""Synthetic PyAV/Qt/CSRT checks; macOS execution is not Windows runtime proof.

Missing video dependencies are explicit skips. Missing native H.264 registration
is tested as an error and skips the hardware export proof only. A registered but
unusable encoder is a failed proof, not an automatic pass or GPL fallback.
Parent controls installation and serial execution; this file installs nothing.
"""
import os
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
from array import array
from copy import deepcopy
from fractions import Fraction
import importlib.util
from pathlib import Path
import random
import struct
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from PIL import Image
from PySide6.QtGui import QGuiApplication, QTransform
from platforms.windows.bluraction.media import Cancelled, fingerprint
from platforms.windows.bluraction.renderer import render
from platforms.windows.bluraction import video

APP = QGuiApplication.instance() or QGuiApplication([])
HAS_AV = importlib.util.find_spec('av') is not None
HAS_CV = importlib.util.find_spec('cv2') is not None
HAS_NUMPY = importlib.util.find_spec('numpy') is not None
PTS = [2000, 2040, 2130, 2200, 2430]


class DisplayMatrixPolicyTests(unittest.TestCase):
    """Mapping-shaped policy seams; actual decoded rotation is tested below."""

    def frame(self, side_data, rotation=0):
        return SimpleNamespace(side_data=side_data, rotation=rotation,
                               to_image=lambda: Image.new('RGB', (16, 12), 'white'))

    def test_missing_matrix_and_unrelated_side_data_keep_unrotated_pixels(self):
        for mapping in ({}, {'ICC_PROFILE': b'controlled unrelated data'}):
            with self.subTest(mapping=mapping):
                result = video._display_image(self.frame(mapping))
                self.assertEqual((result.width(), result.height()), (16, 12))
                self.assertEqual(result.pixelColor(8, 6).getRgb(), (255, 255, 255, 255))

    def test_mapping_display_matrix_still_rejects_privacy_unsafe_transforms(self):
        identity = [65536, 0, 0, 0, 65536, 0, 0, 0, 1 << 30]
        reflected = identity.copy(); reflected[0] *= -1
        perspective = identity.copy(); perspective[2] = 1
        scaled = identity.copy(); scaled[0] *= 2
        # Both rows have unit length and positive determinant, but their
        # dot product is nonzero: the original row-length check missed shear.
        shear = identity.copy(); shear[3:5] = [46341, 46341]
        cases = [('truncated', b'\0' * 35, '표시 행렬'),
                 ('reflected', struct.pack('=9i', *reflected), '반사'),
                 ('perspective', struct.pack('=9i', *perspective), '투시'),
                 ('scaled', struct.pack('=9i', *scaled), '크기 변환'),
                 ('unit-row-shear', struct.pack('=9i', *shear), '직교')]
        for w in (0, -(1 << 30), 1 << 29):
            unnormalized = identity.copy(); unnormalized[8] = w
            cases.append((f'homogeneous-{w}', struct.pack('=9i', *unnormalized), '정규화'))
        for name, payload, message in cases:
            with self.subTest(transform=name):
                with self.assertRaisesRegex(video.VideoError, message):
                    video._display_image(self.frame({'DISPLAYMATRIX': payload}))
        result = video._display_image(self.frame({'DISPLAYMATRIX': struct.pack('=9i', *identity)}))
        self.assertEqual((result.width(), result.height()), (16, 12))

    def test_unit_orthogonal_rotation_and_fixed_point_rounding_controls_remain_valid(self):
        controls = [(0, [65536, 0, 0, 0, 65536, 0, 0, 0, 1 << 30]),
                    (90, [0, -65536, 0, 65536, 0, 0, 0, 0, 1 << 30]),
                    (180, [-65536, 0, 0, 0, -65536, 0, 0, 0, 1 << 30]),
                    (270, [0, 65536, 0, -65536, 0, 0, 0, 0, 1 << 30]),
                    (0, [65535, 0, 0, 0, 65535, 0, 0, 0, 1 << 30])]
        for rotation, matrix in controls:
            with self.subTest(rotation=rotation, matrix=matrix):
                result = video._display_image(self.frame(
                    {'DISPLAYMATRIX': struct.pack('=9i', *matrix)}, rotation))
                expected = (12, 16) if rotation % 180 else (16, 12)
                self.assertEqual((result.width(), result.height()), expected)
                self.assertEqual(result.pixelColor(6, 6).getRgb(), (255, 255, 255, 255))


@unittest.skipUnless(HAS_AV, 'Approved isolated PyAV 19 runtime is not installed; no decode/export proof')
class VideoTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.folder = Path(self.temp.name)
        self.path = self.folder / 'synthetic-vfr.mov'
        self.make_source(self.path, audio=True)
        self.original = self.path.read_bytes()
        self.source = video.VideoSource(self.path)

    def tearDown(self):
        self.assertEqual(self.path.read_bytes(), self.original, 'Original media must remain byte-identical')
        self.temp.cleanup()

    def make_source(self, path, audio=False, rotation=0):
        """LGPL built-in MPEG-4 + PCM fixture, actual uneven PTS, no ffmpeg command."""
        av = video._av()
        with av.open(str(path), 'w') as output:
            stream = output.add_stream('mpeg4', rate=25)
            stream.width, stream.height = 96, 64
            stream.pix_fmt = 'yuv420p'
            stream.time_base = stream.codec_context.time_base = Fraction(1, 1000)
            stream.codec_context.max_b_frames = 0
            stream.set_display_rotation(rotation)
            sound = output.add_stream('pcm_s16le', rate=8000) if audio else None
            if sound:
                sound.layout = 'mono'
            randomizer = random.Random(9127)
            texture = Image.new('RGB', (24, 24))
            texture.putdata([(randomizer.randrange(10, 220), randomizer.randrange(10, 220), randomizer.randrange(10, 220)) for _ in range(24 * 24)])
            durations = dict(zip(PTS, [40, 90, 70, 230, 80]))
            for index, pts in enumerate(PTS):
                image = Image.new('RGB', (96, 64), 'white')
                image.paste(texture, (20 + index * 3, 20))
                image.putpixel((1, 1), (255, 0, 0))
                image.putpixel((94, 1), (0, 255, 0))
                frame = av.VideoFrame.from_image(image)
                frame.pts, frame.time_base, frame.duration = pts, Fraction(1, 1000), durations[pts]
                for packet in stream.encode(frame):
                    stamp_ms = round(packet.pts * packet.time_base * 1000)
                    packet.duration = round(Fraction(durations[stamp_ms], 1000) / packet.time_base)
                    output.mux(packet)
            for packet in stream.encode(None):
                stamp_ms = round(packet.pts * packet.time_base * 1000)
                packet.duration = round(Fraction(durations[stamp_ms], 1000) / packet.time_base)
                output.mux(packet)
            if sound:
                frame = av.AudioFrame(format='s16', layout='mono', samples=4000)
                frame.sample_rate, frame.pts, frame.time_base = 8000, 16120, Fraction(1, 8000)
                samples = array('h', [((i * 31) % 1000) - 500 for i in range(4000)]).tobytes()
                frame.planes[0].update(samples + b'\0' * (frame.planes[0].buffer_size - len(samples)))
                output.mux(sound.encode(frame)); output.mux(sound.encode(None))

    def test_actual_uneven_pts_seek_duration_and_shared_preview_timing(self):
        frames = list(self.source.iter_frames())
        times = [float(frame.time) for frame in frames]
        self.assertEqual(len(times), len(PTS))
        for actual, pts in zip(times, PTS):
            self.assertAlmostEqual(actual, pts / 1000 - float(self.source.origin), places=6)
        self.assertNotEqual(round(times[1] - times[0], 6), round(times[2] - times[1], 6))
        self.assertGreaterEqual(self.source.duration, times[-1] + .079)
        for index in range(len(times) - 1):
            middle = (times[index] + times[index + 1]) / 2
            image = self.source.frame_at(middle)
            timed = self.source.frame_at_timed(middle)
            expected = frames[index].image
            self.assertEqual(bytes(image.constBits()), bytes(expected.constBits()), 'Seek must hold preceding presentation frame')
            self.assertEqual(timed.time, frames[index].time, 'Actual chosen PTS must accompany its pixels')
            self.assertEqual(bytes(timed.image.constBits()), bytes(image.constBits()))
        effect = self.cover_state([times[2], times[3]])
        before = render(self.source.frame_at(times[1]), effect, time=times[1])
        active = render(self.source.frame_at(times[2]), effect, time=times[2])
        self.assertGreater(before.pixelColor(75, 45).red(), 240)
        self.assertLess(active.pixelColor(75, 45).red(), 5)

    def test_timed_seek_cancellation_and_eof_preserve_actual_frame_identity(self):
        frames = list(self.source.iter_frames())
        with self.assertRaises(Cancelled):
            self.source.frame_at_timed(self.source.duration, cancel=lambda: True)
        eof = self.source.frame_at_timed(self.source.duration)
        self.assertEqual(eof.time, frames[-1].time)
        self.assertEqual(bytes(eof.image.constBits()), bytes(frames[-1].image.constBits()))
        self.assertEqual(self.source.first_frame_time, frames[0].time)

    def test_actual_container_rotation_is_applied_once_to_decoded_pixels(self):
        rotated = self.folder / 'rotated.mov'
        self.make_source(rotated, rotation=90)
        original_bytes = rotated.read_bytes()
        with video._av().open(str(rotated)) as container:
            decoded = next(container.decode(video=0))
            matrix = decoded.side_data.get('DISPLAYMATRIX')
            self.assertIsNotNone(matrix, 'The actual codec fixture must expose its rotation matrix')
            self.assertEqual(len(bytes(matrix)), 36)
            self.assertIn(matrix.type, tuple(decoded.side_data), 'PyAV 19 iteration yields Type keys')
        source = video.VideoSource(rotated)
        self.assertEqual((source.page().image.width(), source.page().image.height()), (64, 96))
        unrotated = self.source.frame_at(0)
        expected = unrotated.transformed(QTransform().rotate(-90))
        actual = source.frame_at(0)
        # constBits is a borrowed view; retain its QImage through the byte copy.
        self.assertEqual(bytes(actual.constBits()), bytes(expected.constBits()))
        self.assertEqual(rotated.read_bytes(), original_bytes)

    def test_actual_export_drops_rotation_metadata_after_normalizing_pixels(self):
        capability = video.encoder_capability()
        if not capability['registered']:
            self.skipTest('Native rotated export proof missing: ' + capability['reason'])
        rotated = self.folder / 'rotated.mov'
        self.make_source(rotated, rotation=90)
        source = video.VideoSource(rotated)
        destination = self.folder / 'rotation-output.mov'
        video.export_video(source, {'regions': [], 'drawings': []}, destination)
        exported = video.VideoSource(destination)
        self.assertEqual((exported.page().image.width(), exported.page().image.height()), (64, 96))
        with video._av().open(str(destination)) as container:
            self.assertEqual(next(container.decode(video=0)).rotation, 0, 'Exported pixels must not carry source rotation again')

    def test_actual_export_preserves_video_pts_audio_packets_and_timed_render(self):
        capability = video.encoder_capability()
        if not capability['registered']:
            self.skipTest('Native encoder export proof missing: ' + capability['reason'])
        destination = self.folder / 'flattened.mov'
        times = [float(frame.time) for frame in self.source.iter_frames()]
        progress = []
        video.export_video(self.source, self.cover_state([times[2], times[3]]), destination, progress=progress.append)
        self.assertEqual(progress, sorted(progress)); self.assertEqual(progress[-1], 1)
        av = video._av()
        with av.open(str(self.path)) as original, av.open(str(destination)) as exported:
            input_frames = list(original.decode(video=0))
            input_pts = [f.pts * f.time_base for f in input_frames]
            output_frames = list(exported.decode(video=0))
            self.assertEqual([f.pts * f.time_base for f in output_frames], input_pts)
            self.assertEqual([f.duration * f.time_base for f in output_frames],
                             [f.duration * f.time_base for f in input_frames], 'Actual frame lengths, including EOF, must survive encoding')
            self.assertGreater(video._display_image(output_frames[1]).pixelColor(75, 45).red(), 225)
            self.assertLess(video._display_image(output_frames[2]).pixelColor(75, 45).red(), 25)
        def audio_packets(path):
            with av.open(str(path)) as container:
                self.assertEqual(len(container.streams.audio), 1)
                return [(packet.pts * packet.time_base, packet.dts * packet.time_base,
                         packet.duration * packet.time_base, bytes(packet))
                        for packet in container.demux(audio=0) if packet.dts is not None]
        self.assertEqual(audio_packets(destination), audio_packets(self.path), 'Audio bytes and timing must be remuxed unchanged')
        self.assertAlmostEqual(video.VideoSource(destination).duration, self.source.duration, places=6)

    def test_fresh_target_cancel_changed_source_and_missing_encoder_errors(self):
        existing = self.folder / 'existing.mov'; existing.write_bytes(b'keep existing output')
        with self.assertRaises(FileExistsError):
            video.export_video(self.source, {}, existing)
        self.assertEqual(existing.read_bytes(), b'keep existing output')
        target = self.folder / 'cancelled.mov'
        with self.assertRaises(Cancelled):
            video.export_video(self.source, {}, target, cancel=lambda: True)
        self.assertFalse(target.exists())
        with patch.object(video, 'encoder_capability', return_value={'encoder': 'h264_mf', 'registered': False, 'reason': 'synthetic missing codec'}):
            with self.assertRaisesRegex(video.VideoError, 'synthetic missing codec'):
                video.export_video(self.source, {}, target)
        self.assertFalse(target.exists())
        self.assertFalse(list(self.folder.glob('.bluraction-video-*')))
        changed = self.folder / 'changed.mov'; self.make_source(changed)
        source = video.VideoSource(changed)
        with changed.open('ab') as stream:
            stream.write(b'synthetic mutation')
        with self.assertRaises(video.VideoError):
            video.export_video(source, {}, target)
        self.assertFalse(target.exists())

    def test_mid_export_cancel_removes_only_temporary_output(self):
        capability = video.encoder_capability()
        if not capability['registered']:
            self.skipTest('Native encoder runtime is required for mid-export cancellation proof')
        target = self.folder / 'mid-cancel.mov'
        cancelled = False
        def progress(value):
            nonlocal cancelled
            cancelled = value > .1
        with self.assertRaises(Cancelled):
            video.export_video(self.source, {'regions': [], 'drawings': []}, target, lambda: cancelled, progress)
        self.assertFalse(target.exists()); self.assertFalse(list(self.folder.glob('.bluraction-video-*')))

    @unittest.skipUnless(HAS_CV, 'Approved OpenCV CSRT runtime not installed; no tracking proof')
    def test_actual_csrt_track_uses_actual_pts_and_preserves_original_item(self):
        item = self.track_item()
        original = deepcopy(item)
        progress = []
        end = .44
        frames = video.track(self.source, item, True, 0, end, progress=progress.append)
        self.assertEqual(item, original)
        self.assertEqual(progress, sorted(progress)); self.assertEqual(progress[-1], 1)
        self.assertEqual([round(frame['time'], 6) for frame in frames], [0, .04, .13, .2, .43])
        self.assertGreater(frames[-1]['rect'][0][0], frames[0]['rect'][0][0] + .06)
        self.assertTrue(all(0 <= frame['rect'][0][1] < 1 for frame in frames))

    @unittest.skipUnless(HAS_NUMPY, 'Approved frame-array runtime not installed; loss injection proof missing')
    def test_tracking_loss_and_cancel_do_not_return_partial_or_mutate_item(self):
        item = self.track_item(); original = deepcopy(item)
        class LostTracker:
            def init(self, image, roi):
                return None  # modern OpenCV init returns void
            def update(self, image):
                return False, (0, 0, 0, 0)
        with patch.object(video, '_csrt', return_value=(None, LostTracker())):
            with self.assertRaises(video.TrackingLost):
                video.track(self.source, item, True, 0, .44)
        self.assertEqual(item, original)
        with self.assertRaises(Cancelled):
            video.track(self.source, item, True, 0, .44, cancel=lambda: True)
        self.assertEqual(item, original)

    @unittest.skipUnless(HAS_NUMPY, 'Approved frame-array runtime not installed; resized-box proof missing')
    def test_resizing_tracker_moves_drawing_without_scaling_but_scales_region(self):
        class ResizingTracker:
            def init(self, image, roi):
                self.index = 0
                return None
            def update(self, image):
                self.index += 1
                return True, (23 + 3 * self.index, 18, 36, 30)
        drawing = {'kind': 'rectangle', 'points': [[20 / 96, 20 / 64], [44 / 96, 44 / 64]],
                   'timeRange': [0, .5], 'keyframes': [], 'hidden': False, 'locked': False}
        original = deepcopy(drawing)
        with patch.object(video, '_csrt', side_effect=lambda: (None, ResizingTracker())):
            frames = video.track(self.source, drawing, False, 0, .44)
            region_frames = video.track(self.source, self.track_item(), True, 0, .44)
        self.assertEqual(drawing, original, 'Tracking returns edits without mutating the selected drawing')
        self.assertEqual([round(frame['time'], 6) for frame in frames], [0, .04, .13, .2, .43])
        for frame in frames:
            self.assertAlmostEqual(frame['rect'][1][0], 24 / 96)
            self.assertAlmostEqual(frame['rect'][1][1], 24 / 64)
        # Initial ROI center is (32,32); first resized result center (44,33).
        self.assertAlmostEqual(frames[1]['rect'][0][0], 32 / 96)
        self.assertAlmostEqual(frames[1]['rect'][0][1], 19 / 64)
        self.assertAlmostEqual(region_frames[1]['rect'][1][0], 36 / 96)
        self.assertAlmostEqual(region_frames[1]['rect'][1][1], 30 / 64)
        tracked = deepcopy(drawing); tracked['keyframes'] = frames
        displayed = video.positioned(tracked, False, frames[-1]['time'])
        for old, moved in zip(original['points'], displayed['points']):
            self.assertAlmostEqual(moved[0] - old[0], 21 / 96)
            self.assertAlmostEqual(moved[1] - old[1], -1 / 64)

    def cover_state(self, time_range):
        return {'regions': [{'shape': {'rectangle': {'id': 'synthetic', 'origin': [.6, .1], 'size': [.3, .4]}},
            'effect': {'enabled': True, 'blurRadius': 25, 'featherRadius': 0, 'style': 'solid',
                'color': {'red': 0, 'green': 0, 'blue': 0, 'alpha': 1}, 'timeRange': time_range, 'keyframes': []}}], 'drawings': []}

    def track_item(self):
        return {'shape': {'rectangle': {'id': 'synthetic', 'origin': [20 / 96, 20 / 64], 'size': [24 / 96, 24 / 64]}},
            'effect': {'enabled': True, 'timeRange': [0, .5], 'keyframes': [], 'locked': False}}


if __name__ == '__main__':
    unittest.main()
