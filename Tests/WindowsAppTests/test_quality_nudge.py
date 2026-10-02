"""Quality policy and in-process Qt controller regressions, not OS acceptance.

The encoder spy intentionally stops before encoding: it checks the actual bitrate
assignment and failed-output cleanup, without claiming a real codec/device pass.
"""
import os
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')

from copy import deepcopy
from fractions import Fraction
from pathlib import Path
from types import SimpleNamespace
import tempfile
import time
import unittest
from unittest.mock import patch

from PySide6.QtCore import QEvent, Qt
from PySide6.QtGui import QColor, QImage, QKeyEvent
from PySide6.QtWidgets import QApplication, QMessageBox

from platforms.windows.bluraction.editor import Workspace
from platforms.windows.bluraction.ui import BlurActionWindow
from platforms.windows.bluraction.video import QualityPreset, VideoError, export_video, output_bit_rate

APP = QApplication.instance() or QApplication([])
if not isinstance(APP, QApplication):
    raise RuntimeError('Quality/nudge UI tests require a separate QApplication process.')


class QualityPolicyTests(unittest.TestCase):
    def test_all_four_image_quality_and_video_targets_match_mac_policy(self):
        expected = [('original', '원본', 100, 9_000_000), ('high', '고품질', 92, 6_220_800),
                    ('medium', '중간', 75, 3_110_400), ('low', '낮음', 50, 1_555_200)]
        self.assertEqual(len(QualityPreset), 4)
        for value, label, compression, rate in expected:
            with self.subTest(preset=value):
                preset = QualityPreset(value)
                self.assertEqual((preset.label, preset.image_quality), (label, compression))
                self.assertEqual(output_bit_rate(preset, 9_000_000, 30, 1920, 1080), rate)

    def test_floor_cap_zero_fps_hint_and_original_not_lossless_claim(self):
        self.assertEqual(output_bit_rate('original', 0, 30, 64, 32), 500_000)
        self.assertEqual(output_bit_rate('low', 0, 30, 64, 32), 500_000)
        self.assertEqual(output_bit_rate('high', 0, 240, 16_384, 8192), 500_000_000)
        self.assertEqual(output_bit_rate('high', 0, 0, 1920, 1080), 500_000)
        self.assertEqual(output_bit_rate('high', 0, Fraction(30000, 1001), 1920, 1080), 6_214_585)

    def test_invalid_metadata_and_unknown_preset_are_rejected(self):
        invalid = [(float('nan'), 30, 1920, 1080), (float('inf'), 30, 1920, 1080),
                   (-1, 30, 1920, 1080), (500_000_001, 30, 1920, 1080),
                   (0, 241, 1920, 1080), (0, -1, 1920, 1080), (0, True, 1920, 1080),
                   (0, 30, 0, 1080), (0, 30, 32769, 1), (0, 30, 16384, 8193)]
        for metadata in invalid:
            with self.subTest(metadata=metadata), self.assertRaises(VideoError):
                output_bit_rate('high', *metadata)
        with self.assertRaises(ValueError):
            output_bit_rate('unknown', 0, 30, 1920, 1080)

    def test_export_assigns_each_quality_to_real_code_path_before_encoding(self):
        class Container:
            def __enter__(self): return self
            def __exit__(self, *_): return False
        class Result:
            codec_context = None
            def __init__(self): self.codec_context = SimpleNamespace()
            def set_display_rotation(self, value): self.rotation = value
        class Output(Container):
            def __init__(self): self.result = Result()
            def add_stream(self, encoder, rate):
                self.encoder, self.rate = encoder, rate
                return self.result
            def start_encoding(self): raise RuntimeError('intentional pre-encode spy stop')
        input_ = Container()
        input_.streams = [SimpleNamespace(type='video', bit_rate=9_000_000, time_base=Fraction(1, 30000))]
        class Streams(list):
            audio = []
        input_.streams = Streams(input_.streams)
        image = QImage(1920, 1080, QImage.Format.Format_RGBA8888)
        source = SimpleNamespace(path=Path('unused-synthetic.mov'), stream_index=0,
                                 average_rate=Fraction(30), _first_image=image, validate=lambda _: None)
        for preset, expected in [(QualityPreset.ORIGINAL, 9_000_000), (QualityPreset.HIGH, 6_220_800),
                                 (QualityPreset.MEDIUM, 3_110_400), (QualityPreset.LOW, 1_555_200)]:
            with self.subTest(preset=preset), tempfile.TemporaryDirectory() as directory:
                target = Path(directory) / 'fresh.mp4'
                output = Output()
                fake_av = SimpleNamespace(open=lambda *args, **kwargs: output if len(args) > 1 else input_)
                with patch('platforms.windows.bluraction.video._av', return_value=fake_av), \
                     patch('platforms.windows.bluraction.video.encoder_capability',
                           return_value={'registered': True, 'encoder': 'h264_mf'}):
                    with self.assertRaisesRegex(VideoError, 'intentional pre-encode spy stop'):
                        export_video(source, {'regions': [], 'drawings': []}, target, quality=preset)
                self.assertEqual(output.result.bit_rate, expected)
                self.assertEqual(output.encoder, 'h264_mf')
                self.assertEqual(output.result.rotation, 0)
                self.assertEqual(list(Path(directory).iterdir()), [])


class QualityNudgeControllerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.source = Path(self.temp.name) / 'synthetic.png'
        image = QImage(200, 100, QImage.Format.Format_RGBA8888)
        image.fill(QColor('white'))
        self.assertTrue(image.save(str(self.source)))
        self.original = self.source.read_bytes()
        self.workspace = Workspace()
        self.workspace.load([self.source])
        self.warning = patch('platforms.windows.bluraction.ui.QMessageBox.warning',
                             return_value=QMessageBox.StandardButton.Ok).start()
        self.addCleanup(patch.stopall)
        self.window = BlurActionWindow(self.workspace)
        self.settle()

    def settle(self):
        deadline = time.monotonic() + 5
        while self.window.canvas.preview_queue.busy and time.monotonic() < deadline:
            APP.processEvents()
            time.sleep(.005)
        APP.processEvents()
        self.assertFalse(self.window.canvas.preview_queue.busy)

    def refresh(self):
        self.window.refresh()
        self.settle()

    def tearDown(self):
        self.workspace.busy = False
        self.workspace.video = None  # Tests never construct a native media session.
        self.workspace.dirty = False
        self.window.close()
        self.settle()
        self.assertEqual(self.source.read_bytes(), self.original)
        self.assertEqual(self.warning.call_count, 0, self.warning.call_args_list)
        self.temp.cleanup()

    def cover(self, origin=(.1, .2), size=(.2, .3), kind='rectangle'):
        self.workspace.add_cover(kind, [list(origin), [origin[0] + size[0], origin[1] + size[1]]])
        self.refresh()
        return self.workspace.page.state['regions'][-1]

    def nudge(self, key, modifiers=Qt.KeyboardModifier.NoModifier):
        with patch('platforms.windows.bluraction.ui.QApplication.focusWidget', return_value=self.window.canvas), \
             patch('platforms.windows.bluraction.ui.QApplication.activeModalWidget', return_value=None):
            self.window.nudge_items(key, modifiers)
        self.settle()

    def test_default_quality_labels_and_busy_disable(self):
        self.assertEqual([self.window.quality.itemText(i) for i in range(4)], ['원본', '고품질', '중간', '낮음'])
        self.assertEqual(self.window.quality.currentData(), 'high')
        self.assertIn('92%', self.window.quality_info.text())
        self.window.quality.setCurrentIndex(3)
        self.assertIn('50%', self.window.quality_info.text())
        self.workspace.busy = True
        self.window.refresh()
        self.assertFalse(self.window.quality.isEnabled())

    def test_image_export_freezes_selected_quality_before_worker(self):
        tasks = []
        with patch('platforms.windows.bluraction.ui.QFileDialog.getSaveFileName',
                   return_value=(str(Path(self.temp.name) / 'out.jpg'), 'JPEG 이미지 (*.jpg)')), \
             patch.object(self.window, 'start_export', side_effect=tasks.append), \
             patch('platforms.windows.bluraction.ui.export_image') as exporter:
            self.window.quality.setCurrentIndex(2)
            self.window.export_dialog()
            self.window.quality.setCurrentIndex(0)
            self.assertEqual(len(tasks), 1)
            tasks[0](None, lambda _: None)
            self.assertEqual(exporter.call_args.args[2:4], ('jpeg', 75))

    def test_video_export_freezes_selected_quality_before_worker(self):
        tasks = []
        self.workspace.video = SimpleNamespace(duration=5)
        with patch('platforms.windows.bluraction.ui.QFileDialog.getSaveFileName',
                   return_value=(str(Path(self.temp.name) / 'out.mov'), 'MOV 영상 (*.mov)')), \
             patch.object(self.window, 'start_export', side_effect=tasks.append), \
             patch('platforms.windows.bluraction.video.export_video') as exporter:
            self.window.quality.setCurrentIndex(3)
            self.window.export_dialog()
            self.window.quality.setCurrentIndex(1)
            self.assertEqual(len(tasks), 1)
            tasks[0](None, lambda _: None)
            self.assertEqual(exporter.call_args.kwargs, {'quality': QualityPreset.LOW})

    def test_source_pixel_steps_are_zoom_and_letterbox_independent(self):
        item = self.cover()
        self.assertIsNone(self.workspace.page.pdf_index)
        self.assertEqual(self.workspace.page.point_size, (100, 50))  # PDF-export layout, not 200x100 pixels.
        self.workspace.page.point_size = (600, 800)  # A different PDF layout cannot change image editing units.
        self.window.canvas.resize(400, 400)  # 200x100 image has top/bottom letterbox.
        self.nudge(Qt.Key.Key_Right)
        self.assertAlmostEqual(item['shape']['rectangle']['origin'][0], .105)
        self.window.canvas.resize(1000, 180)
        self.nudge(Qt.Key.Key_Right, Qt.KeyboardModifier.ShiftModifier)
        self.assertAlmostEqual(item['shape']['rectangle']['origin'][0], .155)
        self.nudge(Qt.Key.Key_Up, Qt.KeyboardModifier.ControlModifier)
        self.assertAlmostEqual(item['shape']['rectangle']['origin'][1], .201)
        self.nudge(Qt.Key.Key_Down)
        self.assertAlmostEqual(item['shape']['rectangle']['origin'][1], .191)

    def test_pdf_point_units_and_shift_precedes_precision(self):
        fixture = Path(__file__).resolve().parents[2] / 'shared/fixtures/manual-os/synthetic-three-pages.pdf'
        original_pdf = fixture.read_bytes()
        self.workspace.load([fixture])
        item = self.cover()
        self.assertEqual(self.workspace.page.pdf_index, 0)
        self.assertEqual(self.workspace.page.point_size, (450, 600))
        self.nudge(Qt.Key.Key_Right, Qt.KeyboardModifier.ShiftModifier | Qt.KeyboardModifier.ControlModifier)
        self.assertAlmostEqual(item['shape']['rectangle']['origin'][0], .1 + 10 / 450)
        self.nudge(Qt.Key.Key_Up, Qt.KeyboardModifier.ControlModifier)
        self.assertAlmostEqual(item['shape']['rectangle']['origin'][1], .2 + .1 / 600)
        self.assertEqual(fixture.read_bytes(), original_pdf)

    def test_group_boundary_clamp_locked_member_and_single_undo_redo(self):
        first = self.cover()
        first_id = self.workspace.selectionID
        second = self.cover((.795, .2), (.2, .3), 'ellipse')
        self.workspace.add_drawing('line', [[.3, .2], [.4, .3]])
        drawing = self.workspace.page.state['drawings'][-1]
        first['effect']['groupID'] = second['effect']['groupID'] = drawing['groupID'] = 'GROUP'
        drawing['locked'] = True
        self.workspace.selectionID = first_id
        self.refresh()
        before = deepcopy(self.workspace.page.state)
        locked_before = deepcopy(drawing)
        depth = len(self.workspace._undo[0])
        self.nudge(Qt.Key.Key_Right, Qt.KeyboardModifier.ShiftModifier)
        self.assertAlmostEqual(first['shape']['rectangle']['origin'][0], .105)
        self.assertAlmostEqual(second['shape']['ellipse']['origin'][0], .8)
        self.assertEqual(drawing, locked_before)
        self.assertEqual(len(self.workspace._undo[0]), depth + 1)
        after = deepcopy(self.workspace.page.state)
        self.workspace.undo()
        self.assertEqual(self.workspace.page.state, before)
        self.workspace.redo()
        self.assertEqual(self.workspace.page.state, after)

    def test_boundary_and_locked_anchor_noop_do_not_dirty_or_checkpoint(self):
        item = self.cover((.8, .2))
        before = deepcopy(self.workspace.page.state)
        depth = len(self.workspace._undo[0])
        self.workspace.dirty = False
        self.nudge(Qt.Key.Key_Right)
        self.assertEqual(self.workspace.page.state, before)
        self.assertEqual(len(self.workspace._undo[0]), depth)
        self.assertFalse(self.workspace.dirty)
        item['effect']['locked'] = True
        self.nudge(Qt.Key.Key_Left)
        self.assertEqual(len(self.workspace._undo[0]), depth)
        self.assertFalse(self.workspace.dirty)

    def test_text_focus_busy_preview_modal_and_other_modifiers_block_move(self):
        self.cover()
        before = deepcopy(self.workspace.page.state)
        depth = len(self.workspace._undo[0])
        with patch('platforms.windows.bluraction.ui.QApplication.focusWidget', return_value=self.window.text):
            self.window.nudge_items(Qt.Key.Key_Left)
        self.workspace.busy = True
        self.nudge(Qt.Key.Key_Left)
        self.workspace.busy = False
        self.window.canvas.busy = True
        self.nudge(Qt.Key.Key_Left)
        self.window.canvas.busy = False
        with patch('platforms.windows.bluraction.ui.QApplication.focusWidget', return_value=self.window.canvas), \
             patch('platforms.windows.bluraction.ui.QApplication.activeModalWidget', return_value=self.window.text):
            self.window.nudge_items(Qt.Key.Key_Left)
        self.nudge(Qt.Key.Key_Left, Qt.KeyboardModifier.AltModifier)
        self.assertEqual(self.workspace.page.state, before)
        self.assertEqual(len(self.workspace._undo[0]), depth)

    def test_keyboard_event_routes_canvas_only_and_guards_unfinished_gesture(self):
        item = self.cover()
        key = QKeyEvent(QEvent.Type.KeyPress, Qt.Key.Key_Left, Qt.KeyboardModifier.ControlModifier)
        with patch('platforms.windows.bluraction.ui.QApplication.focusWidget', return_value=self.window.canvas), \
             patch('platforms.windows.bluraction.ui.QApplication.activeModalWidget', return_value=None):
            self.window.canvas.keyPressEvent(key)
        self.settle()
        self.assertTrue(key.isAccepted())
        self.assertAlmostEqual(item['shape']['rectangle']['origin'][0], .0995)
        before = deepcopy(self.workspace.page.state)
        self.window.canvas._stroke = [[.1, .1]]
        with patch('platforms.windows.bluraction.ui.QApplication.focusWidget', return_value=self.window.canvas):
            self.window.canvas.keyPressEvent(key)
        self.assertEqual(self.workspace.page.state, before)
        self.window.canvas._stroke = []

    def test_motion_record_uses_displayed_time_and_restores_in_one_undo(self):
        item = self.cover()
        self.workspace.time = 1.25
        self.workspace.record_motion = True
        self.refresh()
        before = deepcopy(self.workspace.page.state)
        self.nudge(Qt.Key.Key_Up)
        self.assertEqual([f['time'] for f in item['effect']['keyframes']], [0, 1.25])
        self.assertEqual(item['shape']['rectangle']['origin'], [.1, .2])
        self.assertAlmostEqual(item['effect']['keyframes'][-1]['rect'][0][1], .21)
        self.workspace.undo()
        self.assertEqual(self.workspace.page.state, before)

    def test_recording_off_translates_complete_motion_path_and_erasure(self):
        item = self.cover()
        effect = item['effect']
        effect['keyframes'] = [
            {'time': 0, 'rect': [[.1, .2], [.2, .3]]},
            {'time': 2, 'rect': [[.3, .4], [.2, .3]]}]
        effect['erasures'] = [{'points': [[.15, .25], [.16, .26]], 'width': .01}]
        self.workspace.time = 1
        self.refresh()
        self.nudge(Qt.Key.Key_Right)
        self.assertEqual([f['time'] for f in effect['keyframes']], [0, 2])
        self.assertAlmostEqual(item['shape']['rectangle']['origin'][0], .105)
        self.assertAlmostEqual(effect['keyframes'][0]['rect'][0][0], .105)
        self.assertAlmostEqual(effect['keyframes'][1]['rect'][0][0], .305)
        self.assertAlmostEqual(effect['erasures'][0]['points'][0][0], .155)
        self.assertEqual(effect['erasures'][0]['width'], .01)

    def test_one_pixel_motion_item_translation_preserves_all_exact_extents(self):
        item = self.cover(size=(.005, .01))
        # Use exact persisted values, including a later subpixel frame. The
        # image's 100x50 PDF layout must never enlarge its 200x100 editing grid.
        shape = item['shape']['rectangle']
        shape['size'] = [.005, .01]
        effect = item['effect']
        effect['keyframes'] = [
            {'time': 0, 'rect': [[.1, .2], [.005, .01]]},
            {'time': 2, 'rect': [[.15, .25], [.0025, .005]]}]
        effect['erasures'] = [{'points': [[.101, .201], [.102, .202]], 'width': .00025}]
        self.workspace.time = 0
        self.refresh()
        before = deepcopy(self.workspace.page.state)
        depth = len(self.workspace._undo[0])
        self.workspace.move_selected(.005, -.001, time=0)
        self.assertEqual(shape['size'], [.005, .01])
        self.assertEqual([f['rect'][1] for f in effect['keyframes']], [[.005, .01], [.0025, .005]])
        self.assertEqual([f['time'] for f in effect['keyframes']], [0, 2])
        self.assertAlmostEqual(shape['origin'][0], .105)
        self.assertAlmostEqual(effect['keyframes'][1]['rect'][0][0], .155)
        self.assertAlmostEqual(effect['erasures'][0]['points'][0][0], .106)
        self.assertAlmostEqual(effect['erasures'][0]['points'][0][1], .200)
        self.assertEqual(effect['erasures'][0]['width'], .00025)
        self.assertEqual(len(self.workspace._undo[0]), depth + 1)
        after = deepcopy(self.workspace.page.state)
        self.workspace.undo()
        self.assertEqual(self.workspace.page.state, before)
        self.workspace.redo()
        self.assertEqual(self.workspace.page.state, after)

    def test_near_boundary_tiny_group_keeps_polygon_line_holes_and_locked_item(self):
        ellipse = self.cover((.99, .97), (.005, .01), 'ellipse')
        anchor_id = self.workspace.selectionID
        ellipse['shape']['ellipse']['size'] = [.005, .01]
        ellipse['effect']['keyframes'] = [{'time': 0, 'rect': [[.99, .97], [.005, .01]]}]
        self.workspace.add_cover('polygon', [[.996, .985], [.998, .995], [.997, .987]])
        polygon = self.workspace.page.state['regions'][-1]
        polygon['effect']['erasures'] = [{'points': [[.997, .986]], 'width': .0001}]
        self.workspace.add_drawing('line', [[.995, .98], [.995, .989]])
        line = self.workspace.page.state['drawings'][-1]
        self.workspace.add_drawing('line', [[.999, .98], [1, .99]])
        locked = self.workspace.page.state['drawings'][-1]
        locked['locked'] = True
        for properties in (ellipse['effect'], polygon['effect'], line, locked):
            properties['groupID'] = 'TINY_GROUP'
        self.workspace.selectionID = anchor_id
        self.workspace.time = 0
        self.refresh()
        original_polygon = deepcopy(polygon['shape']['polygon']['points'])
        original_line = deepcopy(line['points'])
        original_locked = deepcopy(locked)
        depth = len(self.workspace._undo[0])
        self.nudge(Qt.Key.Key_Right, Qt.KeyboardModifier.ShiftModifier)
        self.assertEqual(ellipse['shape']['ellipse']['size'], [.005, .01])
        self.assertEqual(ellipse['effect']['keyframes'][0]['rect'][1], [.005, .01])
        self.assertAlmostEqual(ellipse['shape']['ellipse']['origin'][0], .992)
        for after, before in zip(polygon['shape']['polygon']['points'], original_polygon):
            self.assertAlmostEqual(after[0] - before[0], .002)
            self.assertEqual(after[1], before[1])
        for after, before in zip(line['points'], original_line):
            self.assertAlmostEqual(after[0] - before[0], .002)
            self.assertEqual(after[1], before[1])
        self.assertAlmostEqual(polygon['effect']['erasures'][0]['points'][0][0], .999)
        self.assertEqual(polygon['effect']['erasures'][0]['width'], .0001)
        self.assertEqual(locked, original_locked)
        self.assertEqual(len(self.workspace._undo[0]), depth + 1)
        after = deepcopy(self.workspace.page.state)
        self.nudge(Qt.Key.Key_Right)
        self.assertEqual(self.workspace.page.state, after)
        self.assertEqual(len(self.workspace._undo[0]), depth + 1)

    def test_real_resize_retains_existing_minimum_policy_but_recorded_move_does_not(self):
        item = self.cover(size=(.005, .01))
        shape, effect = item['shape']['rectangle'], item['effect']
        shape['size'] = [.005, .01]
        effect['keyframes'] = [{'time': 0, 'rect': [[.1, .2], [.005, .01]]}]
        self.workspace.time = 0
        self.workspace.resize_selected([.1, .2, .0025, .005], time=0)
        self.assertEqual(shape['size'], [.01, .02])
        self.assertEqual(effect['keyframes'][0]['rect'][1], [.01, .02])
        shape['size'] = [.005, .01]
        effect['keyframes'] = [{'time': 0, 'rect': [[.1, .2], [.005, .01]]}]
        self.workspace.record_motion = True
        self.workspace.move_selected(.005, 0, time=1)
        self.assertEqual(shape['size'], [.005, .01])
        self.assertEqual([frame['time'] for frame in effect['keyframes']], [0, 1])
        self.assertEqual([frame['rect'][1] for frame in effect['keyframes']], [[.005, .01], [.005, .01]])
        self.assertAlmostEqual(effect['keyframes'][1]['rect'][0][0], .105)


if __name__ == '__main__':
    unittest.main()
