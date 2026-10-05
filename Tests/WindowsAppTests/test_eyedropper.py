"""Actual renderer/Qt/PDF/MOV regressions; no desktop or OS-input automation.

These tests run inside their own Qt process. Windows execution is established
only by the verifier's actual host, not by importing the Windows module on Mac.
"""
import os
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')

from copy import deepcopy
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

from PySide6.QtCore import QEvent, QPointF, Qt
from PySide6.QtGui import QColor, QColorSpace, QImage, QKeyEvent, QMouseEvent
from PySide6.QtWidgets import QApplication, QMessageBox

from platforms.windows.bluraction import renderer
from platforms.windows.bluraction.editor import Workspace
from platforms.windows.bluraction.ui import BlurActionWindow, EditorCanvas
from platforms.windows.bluraction.video import asset_transport_load

APP = QApplication.instance() or QApplication([])
if not isinstance(APP, QApplication):
    raise RuntimeError('Eyedropper tests require a separate QApplication process.')
ROOT = Path(__file__).resolve().parents[2]
SRGB = QColorSpace(QColorSpace.NamedColorSpace.SRgb)


def mouse(canvas, kind, position):
    buttons = Qt.MouseButton.LeftButton if kind == QEvent.Type.MouseButtonPress else Qt.MouseButton.NoButton
    event = QMouseEvent(kind, position, position, Qt.MouseButton.LeftButton, buttons, Qt.KeyboardModifier.NoModifier)
    if kind == QEvent.Type.MouseButtonPress:
        canvas.mousePressEvent(event)
    else:
        canvas.mouseReleaseEvent(event)


class CompositeSamplingTests(unittest.TestCase):
    def setUp(self):
        self.canvas = EditorCanvas()
        self.canvas.resize(400, 400)
        self.image = QImage(2, 2, QImage.Format.Format_RGBA8888)
        self.image.setColorSpace(SRGB)
        for x, y, color in [(0, 0, 'red'), (1, 0, 'green'), (0, 1, 'blue'), (1, 1, 'yellow')]:
            self.image.setPixelColor(x, y, QColor(color))
        self.present(self.image)

    def present(self, image, state=None, stamp=None):
        state = state or {'regions': [], 'drawings': []}
        self.canvas.accept_prepared(image, state, renderer.render(image, state, stamp), stamp, 'synthetic')

    def tearDown(self):
        self.canvas.close()

    def test_corners_pixel_boundaries_and_bottom_left_transform(self):
        for normalized, expected in [([0, 1], 'red'), ([1, 1], 'green'), ([0, 0], 'blue'), ([1, 0], 'yellow'),
                                     ([.499, .75], 'red'), ([.5, .75], 'green')]:
            with self.subTest(point=normalized):
                self.assertEqual(self.canvas.sample_composite_at(self.canvas.display_point(normalized)), QColor(expected))

    def test_letterbox_and_fit_change_do_not_sample_black_background(self):
        image = QImage(4, 2, QImage.Format.Format_RGBA8888)
        image.fill(QColor('red')); image.setColorSpace(SRGB)
        self.present(image)
        self.assertIsNone(self.canvas.sample_composite_at(QPointF(200, 50)))
        for width, height in [(400, 400), (900, 200), (240, 600)]:
            self.canvas.resize(width, height)
            self.assertEqual(self.canvas.sample_composite_at(self.canvas.display_point([.25, .75])), QColor('red'))

    def test_reads_effect_and_drawing_composite_instead_of_source_or_decorations(self):
        image = QImage(100, 100, QImage.Format.Format_RGBA8888)
        image.fill(QColor('red')); image.setColorSpace(SRGB)
        state = {'regions': [{'shape': {'rectangle': {'id': 'COVER', 'origin': [0, 0], 'size': [1, 1]}},
                             'effect': {'style': 'solid', 'color': {'red': 0, 'green': 0, 'blue': 1, 'alpha': 1},
                                        'enabled': True, 'timeRange': [0, 0], 'featherRadius': 0}}],
                 'drawings': [{'id': 'DRAW', 'kind': 'rectangle', 'points': [[.2, .2], [.8, .8]],
                              'red': 0, 'green': 1, 'blue': 0, 'alpha': 1,
                              'fillOpacity': 1, 'lineWidth': .01, 'timeRange': [0, 0]}]}
        self.present(image, state)
        self.canvas.selection_ids = {'DRAW'}
        self.canvas._stroke = [[0, 0], [1, 1]]
        self.assertEqual(self.canvas.sample_composite_at(self.canvas.display_point([.1, .5])), QColor('blue'))
        self.assertEqual(self.canvas.sample_composite_at(self.canvas.display_point([.5, .5])), QColor(0, 255, 0))
        self.assertEqual(self.canvas.image.pixelColor(50, 50), QColor('red'))

    def test_straight_and_premultiplied_alpha_are_unassociated_then_opaque(self):
        for format_ in (QImage.Format.Format_RGBA8888, QImage.Format.Format_RGBA8888_Premultiplied):
            with self.subTest(format=format_):
                image = QImage(2, 2, format_)
                image.fill(QColor(200, 100, 50, 128)); image.setColorSpace(SRGB)
                # Preserve the actual Qt format to test pixelColor's unpremultiply path.
                self.canvas.accept_prepared(image, {'regions': [], 'drawings': []}, image, None, 'alpha')
                actual = self.canvas.sample_composite_at(self.canvas.display_point([.5, .5]))
                self.assertEqual(actual.alpha(), 255)
                for channel, wanted in zip(actual.getRgb()[:3], (200, 100, 50)):
                    self.assertLessEqual(abs(channel - wanted), 1)

    def test_transparent_unknown_color_space_and_invalid_positions_fail(self):
        image = QImage(2, 2, QImage.Format.Format_RGBA8888)
        image.fill(Qt.GlobalColor.transparent); image.setColorSpace(SRGB)
        self.canvas.accept_prepared(image, {'regions': [], 'drawings': []}, image, None, 'transparent')
        with self.assertRaisesRegex(ValueError, '투명'):
            self.canvas.sample_composite_at(self.canvas.display_point([.5, .5]))
        image.fill(QColor('red')); image.setColorSpace(QColorSpace())
        self.canvas.accept_prepared(image, {'regions': [], 'drawings': []}, image, None, 'untagged')
        with self.assertRaisesRegex(ValueError, '색 공간'):
            self.canvas.sample_composite_at(self.canvas.display_point([.5, .5]))
        with self.assertRaises(ValueError):
            self.canvas.sample_composite_at(QPointF(float('nan'), 1))

    def test_busy_blank_preview_and_unfinished_gesture_cannot_arm_or_sample(self):
        self.canvas.busy = True
        self.assertFalse(self.canvas.arm_color_pick())
        with self.assertRaises(ValueError):
            self.canvas.sample_composite_at(QPointF(1, 1))
        self.canvas.busy = False
        self.canvas._stroke = [[0, 0]]
        self.assertFalse(self.canvas.arm_color_pick())
        self.canvas._stroke = []
        self.canvas._preview = QImage()
        self.assertFalse(self.canvas.arm_color_pick())


class EyedropperControllerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.source = Path(self.temp.name) / 'synthetic.png'
        image = QImage(200, 100, QImage.Format.Format_RGBA8888)
        image.fill(QColor('red')); image.setColorSpace(SRGB)
        self.assertTrue(image.save(str(self.source)))
        self.original = self.source.read_bytes()
        self.workspace = Workspace(); self.workspace.load([self.source])
        self.warnings = patch('platforms.windows.bluraction.ui.QMessageBox.warning',
                              return_value=QMessageBox.StandardButton.Ok).start()
        self.addCleanup(patch.stopall)
        self.window = BlurActionWindow(self.workspace)
        self.settle()

    def settle(self):
        deadline = time.monotonic() + 10
        while (self.window.canvas.preview_queue.busy or self.window._asset_audio.queue.busy) and time.monotonic() < deadline:
            APP.processEvents(); time.sleep(.005)
        APP.processEvents()
        self.assertFalse(self.window.canvas.preview_queue.busy)
        self.assertFalse(self.window._asset_audio.queue.busy)

    def refresh(self):
        self.window.refresh(); self.settle()

    def click(self, point=(.1, .5)):
        position = self.window.canvas.display_point(point)
        mouse(self.window.canvas, QEvent.Type.MouseButtonPress, position)
        mouse(self.window.canvas, QEvent.Type.MouseButtonRelease, position)
        self.settle()

    def tearDown(self):
        self.workspace.busy = False; self.workspace.dirty = False
        self.window.close(); self.settle()
        self.assertEqual(self.source.read_bytes(), self.original)
        self.assertEqual(self.warnings.call_count, 0, self.warnings.call_args_list)
        self.temp.cleanup()

    def test_buttons_enable_after_real_preview_and_sample_without_creating_gesture(self):
        self.assertTrue(self.window.cover_pick.isEnabled())
        self.assertTrue(self.window.drawing_pick.isEnabled())
        self.window.canvas.set_tool('cover_rectangle')
        old_cursor = self.window.canvas.cursor().shape()
        before = deepcopy(self.workspace.page.state)
        self.window.drawing_pick.click()
        self.assertIsNotNone(self.window.canvas._color_pick)
        self.assertEqual(self.window.canvas.cursor().shape(), Qt.CursorShape.CrossCursor)
        self.click()
        self.assertEqual(self.window.drawing_color, QColor('red'))
        self.assertEqual(self.workspace.page.state, before)
        self.assertFalse(self.workspace.dirty)
        self.assertFalse(self.workspace._undo)
        self.assertEqual(self.window.canvas.tool, 'cover_rectangle')
        self.assertEqual(self.window.canvas.cursor().shape(), old_cursor)
        self.assertIsNone(self.window.canvas._color_pick)
        self.assertIsNone(self.window._pick_context)

    def test_letterbox_keeps_armed_and_escape_cancels_without_changes(self):
        self.window.canvas.resize(400, 400)
        color, before = QColor(self.window.cover_color), deepcopy(self.workspace.page.state)
        self.assertTrue(self.window.start_color_pick(True))
        mouse(self.window.canvas, QEvent.Type.MouseButtonPress, QPointF(200, 50))
        self.assertIsNotNone(self.window.canvas._color_pick)
        event = QKeyEvent(QEvent.Type.KeyPress, Qt.Key.Key_Escape, Qt.KeyboardModifier.NoModifier)
        self.window.canvas.keyPressEvent(event)
        self.assertIsNone(self.window.canvas._color_pick)
        self.assertEqual(self.window.cover_color, color)
        self.assertEqual(self.workspace.page.state, before)
        self.assertFalse(self.workspace._undo)

    def test_selected_drawing_color_only_precision_one_undo_redo_save_reopen(self):
        self.workspace.add_drawing('rectangle', [[.6, .2], [.9, .8]],
            width=.123456789012, fill=.612345678901, font='Sans Serif')
        drawing = self.workspace.page.state['drawings'][0]
        drawing.update(name=None, textBackground=None)
        self.refresh()
        before = deepcopy(self.workspace.page.state)
        depth = len(self.workspace._undo[0])
        self.assertTrue(self.window.start_color_pick(False)); self.click()
        after = deepcopy(self.workspace.page.state)
        unchanged = deepcopy(after['drawings'][0]); unchanged.update({key: before['drawings'][0][key]
            for key in ('red', 'green', 'blue', 'alpha')})
        self.assertEqual(unchanged, before['drawings'][0])
        self.assertEqual([drawing[k] for k in ('red', 'green', 'blue', 'alpha')], [1, 0, 0, 1])
        self.assertEqual(len(self.workspace._undo[0]), depth + 1)
        self.workspace.undo(); self.assertEqual(self.workspace.page.state, before)
        self.workspace.redo(); self.assertEqual(self.workspace.page.state, after)
        destination = Path(self.temp.name) / 'picked.bluraction'
        self.workspace.save_project(destination)
        saved = destination.read_bytes()
        reopened = Workspace(); reopened.load_project(destination)
        self.assertEqual(reopened.page.state, after)
        self.assertEqual(destination.read_bytes(), saved)

    def test_mixed_selection_group_and_lock_restylings_only_explicit_matching_items(self):
        self.workspace.add_cover('rectangle', [[.6, .1], [.9, .9]])
        cover = self.workspace.page.state['regions'][0]
        cover_id = self.workspace.selectionID
        a = self.workspace.add_drawing('line', [[.6, .2], [.7, .3]])
        b = self.workspace.add_drawing('line', [[.7, .2], [.8, .3]])
        c = self.workspace.add_drawing('line', [[.8, .2], [.9, .3]])
        drawings = self.workspace.page.state['drawings']
        for drawing in drawings: drawing['groupID'] = 'SAME_GROUP'
        drawings[1]['locked'] = True
        self.workspace.selection_ids = {a, b, cover_id}
        self.refresh()
        before = deepcopy(self.workspace.page.state)
        depth = len(self.workspace._undo[0])
        self.assertTrue(self.window.start_color_pick(False)); self.click()
        self.assertEqual(drawings[1:], before['drawings'][1:])
        self.assertEqual(cover, before['regions'][0])
        self.assertEqual(drawings[0]['red'], 1); self.assertEqual(drawings[0]['green'], 0)
        self.assertEqual(len(self.workspace._undo[0]), depth + 1)
        self.assertEqual(self.workspace.selection_ids, {a, b, cover_id})

    def test_locked_and_same_color_targets_do_not_add_checkpoint_or_dirty(self):
        self.workspace.add_drawing('line', [[.6, .2], [.8, .4]],
                                   {'red': 1, 'green': 0, 'blue': 0, 'alpha': 1})
        drawing = self.workspace.page.state['drawings'][0]
        self.refresh(); self.workspace.dirty = False
        depth = len(self.workspace._undo[0])
        self.assertTrue(self.window.start_color_pick(False)); self.click()
        self.assertEqual(len(self.workspace._undo[0]), depth)
        self.assertFalse(self.workspace.dirty)
        drawing['locked'] = True
        drawing['red'], drawing['green'] = 0, 1
        self.refresh(); before = deepcopy(self.workspace.page.state)
        self.assertTrue(self.window.start_color_pick(False)); self.click()
        self.assertEqual(self.workspace.page.state, before)
        self.assertEqual(len(self.workspace._undo[0]), depth)
        self.assertFalse(self.workspace.dirty)

    def test_cover_sample_updates_only_color_and_default_for_next_cover(self):
        self.workspace.add_cover('ellipse', [[.6, .2], [.9, .8]], 'mosaic', 123.456789, 0)
        item = self.workspace.page.state['regions'][0]
        self.refresh(); before = deepcopy(item)
        self.assertTrue(self.window.start_color_pick(True)); self.click()
        expected = deepcopy(before); expected['effect']['color'] = {'red': 1, 'green': 0, 'blue': 0, 'alpha': 1}
        self.assertEqual(item, expected)
        self.window.create_item('cover_rectangle', [[.05, .1], [.2, .3]])
        self.settle()
        self.assertEqual(self.workspace.page.state['regions'][-1]['effect']['color'], expected['effect']['color'])

    def test_busy_modal_gesture_and_tool_change_cancel_or_prevent_arming(self):
        self.workspace.busy = True
        self.assertFalse(self.window.start_color_pick(True))
        self.workspace.busy = False
        with patch('platforms.windows.bluraction.ui.QApplication.activeModalWidget', return_value=self.window.text):
            self.assertFalse(self.window.start_color_pick(True))
        before_color = QColor(self.window.cover_color)
        self.assertTrue(self.window.start_color_pick(True))
        with patch('platforms.windows.bluraction.ui.QApplication.activeModalWidget', return_value=self.window.text):
            self.click()
        self.assertEqual(self.window.cover_color, before_color)
        self.assertIsNone(self.window._pick_context)
        self.window.canvas._stroke = [[.2, .2]]
        self.assertFalse(self.window.start_color_pick(True)); self.window.canvas._stroke = []
        self.assertTrue(self.window.start_color_pick(True))
        self.window.canvas.set_tool('line')
        self.assertIsNone(self.window.canvas._color_pick)
        self.assertTrue(self.window.start_color_pick(True))
        self.workspace.busy = True; self.window.refresh()
        self.assertIsNone(self.window.canvas._color_pick)
        self.assertIsNone(self.window._pick_context)

    def test_real_transparent_png_consumes_pick_without_brush_document_or_undo_change(self):
        transparent = Path(self.temp.name) / 'transparent.png'
        image = QImage(100, 100, QImage.Format.Format_RGBA8888)
        image.fill(Qt.GlobalColor.transparent); image.setColorSpace(SRGB)
        self.assertTrue(image.save(str(transparent)))
        original = transparent.read_bytes()
        self.workspace.load([transparent]); self.refresh()
        before = deepcopy(self.workspace.page.state); color = QColor(self.window.cover_color)
        self.assertTrue(self.window.start_color_pick(True)); self.click((.5, .5))
        self.assertIsNone(self.window.canvas._color_pick)
        self.assertIsNone(self.window._pick_context)
        self.assertIn('투명', self.window.statusBar().currentMessage())
        self.assertEqual(self.window.cover_color, color)
        self.assertEqual(self.workspace.page.state, before)
        self.assertFalse(self.workspace._undo)
        self.assertFalse(self.workspace.dirty)
        self.assertEqual(transparent.read_bytes(), original)

    def test_context_state_and_selection_changes_reject_stale_sample(self):
        self.workspace.add_drawing('line', [[.6, .2], [.8, .4]])
        self.window.drawing_color = QColor('blue')  # Distinct from the red pixel, so rejection is observable.
        self.refresh(); before_color = QColor(self.window.drawing_color)
        self.assertTrue(self.window.start_color_pick(False))
        self.workspace.selection_ids.clear()
        # Canvas selection snapshot has not yet refreshed; window must still reject it.
        self.click(); self.assertEqual(self.window.drawing_color, before_color)
        self.refresh()
        self.assertTrue(self.window.start_color_pick(False))
        self.workspace.page.state['drawings'][0]['text'] = 'new model content'
        self.click(); self.assertEqual(self.window.drawing_color, before_color)
        self.refresh(); self.assertTrue(self.window.start_color_pick(False))
        self.window.canvas.preview_context = ('old-page',)
        self.click(); self.assertEqual(self.window.drawing_color, before_color)
        self.assertIsNone(self.window.canvas._color_pick)

    def test_keyboard_i_is_canvas_only_and_arrows_do_not_move_while_armed(self):
        self.workspace.add_cover('rectangle', [[.6, .2], [.9, .8]])
        self.refresh(); before = deepcopy(self.workspace.page.state)
        event = QKeyEvent(QEvent.Type.KeyPress, Qt.Key.Key_I, Qt.KeyboardModifier.NoModifier)
        with patch('platforms.windows.bluraction.ui.QApplication.focusWidget', return_value=self.window.text):
            self.window.canvas.keyPressEvent(event)
        self.assertIsNone(self.window.canvas._color_pick)
        with patch('platforms.windows.bluraction.ui.QApplication.focusWidget', return_value=self.window.canvas):
            self.window.canvas.keyPressEvent(event)
            self.window.canvas.keyPressEvent(QKeyEvent(QEvent.Type.KeyPress, Qt.Key.Key_Left, Qt.KeyboardModifier.NoModifier))
            self.window.nudge_items(Qt.Key.Key_Right)
        self.assertIsNotNone(self.window.canvas._color_pick)
        self.assertEqual(self.workspace.page.state, before)

    def test_actual_pdf_pages_sample_current_composite_and_page_change_cancels(self):
        fixture = ROOT / 'shared/fixtures/manual-os/synthetic-three-pages.pdf'
        original = fixture.read_bytes()
        self.workspace.load([fixture]); self.refresh()
        for index, expected in [(0, QColor('blue')), (1, QColor('red'))]:
            self.workspace.set_page(index)
            self.workspace.add_cover('rectangle', [[0, 0], [1, 1]], 'solid', 0, 0,
                dict(zip(('red', 'green', 'blue', 'alpha'), expected.getRgbF())))
            self.refresh()
            self.workspace.selection_ids.clear(); self.refresh()
            self.assertTrue(self.window.start_color_pick(False)); self.click((.5, .5))
            self.assertEqual(self.window.drawing_color, expected)
        self.assertTrue(self.window.start_color_pick(False))
        self.workspace.set_page(2); self.refresh()
        self.assertIsNone(self.window.canvas._color_pick)
        self.assertEqual(fixture.read_bytes(), original)

    def test_actual_video_samples_displayed_pts_and_seek_cancels_old_snapshot(self):
        fixture = ROOT / 'shared/fixtures/video-timelines/nonzero-origin.mov'
        original = fixture.read_bytes()
        # Desktop prepare workers opt into the same owned source constructor.
        with asset_transport_load():
            self.workspace.load([fixture])
        self.refresh()
        source = self.workspace.video
        self.assertIsNotNone(source.asset_session)
        first = float(source.first_frame_time)
        target = min(source.duration - .01, first + .5)
        target_pts = source.frame_at_timed(target).time
        self.workspace.add_cover('rectangle', [[0, 0], [1, 1]], 'solid', 0, 0,
            {'red': 0, 'green': 0, 'blue': 1, 'alpha': 1})
        self.refresh()
        self.assertTrue(self.window.start_color_pick(False))
        self.window.seek_video(target)
        self.assertIsNone(self.window.canvas._color_pick)
        self.assertFalse(self.window.start_color_pick(False))
        self.settle()
        self.assertAlmostEqual(self.workspace.time, target_pts)
        self.assertEqual(self.window.canvas.time, self.workspace.time)
        self.assertTrue(self.window.start_color_pick(False)); self.click((.5, .5))
        self.assertEqual(self.window.drawing_color, QColor('blue'))
        self.assertEqual(self.window.canvas.time, target_pts)
        self.assertEqual(fixture.read_bytes(), original)

    def test_color_dialog_uses_same_lock_and_precision_transaction(self):
        self.workspace.add_drawing('rectangle', [[.6, .2], [.9, .8]], width=.123456789, fill=.612345678)
        item = self.workspace.page.state['drawings'][0]; item['locked'] = True
        self.refresh(); before = deepcopy(self.workspace.page.state); depth = len(self.workspace._undo[0])
        with patch('platforms.windows.bluraction.ui.QColorDialog.getColor', return_value=QColor(20, 30, 40, 128)):
            self.window.choose_color(False)
        self.assertEqual(self.window.drawing_color, QColor(20, 30, 40, 128))
        self.assertEqual(self.workspace.page.state, before)
        self.assertEqual(len(self.workspace._undo[0]), depth)


if __name__ == '__main__':
    unittest.main()
