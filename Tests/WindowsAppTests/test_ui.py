"""Synthetic Qt controller checks; these are not Windows OS/user acceptance."""
import os
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
from pathlib import Path
import json
import tempfile
import time
import threading
import unittest
from copy import deepcopy
from unittest.mock import patch
from shiboken6 import isValid

from PySide6.QtCore import QPoint, QPointF, QRectF, QSize, Qt, QThread, Slot
from PySide6.QtGui import QColor, QCloseEvent, QImage
from PySide6.QtMultimedia import QMediaPlayer, QVideoFrame, QtVideo
from PySide6.QtPdf import QPdfDocument
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QMessageBox

from platforms.windows.bluraction.editor import Workspace
from platforms.windows.bluraction.media import Cancelled, Page, fingerprint
from platforms.windows.bluraction.ui import BlurActionWindow, EditorCanvas, ExportWorker, fitted_rect, font_available

APP = QApplication.instance() or QApplication([])
if not isinstance(APP, QApplication):
    raise RuntimeError('Run UI suite separately, or create QApplication in the engine suite.')


class CanvasTests(unittest.TestCase):
    def present(self, *args, **kwargs):
        self.canvas.set_document(*args, **kwargs)
        deadline = time.monotonic() + 5
        while self.canvas.preview_queue.busy and time.monotonic() < deadline:
            APP.processEvents()
            time.sleep(.005)
        self.assertFalse(self.canvas.preview_queue.busy)

    def setUp(self):
        self.canvas = EditorCanvas()
        self.canvas.resize(400, 400)
        image = QImage(200, 100, QImage.Format.Format_RGBA8888)
        image.fill(QColor('white'))
        self.present(image, {'regions': [], 'drawings': []})

    def tearDown(self):
        self.canvas.close()
        deadline = time.monotonic() + 5
        while self.canvas.preview_queue.busy and time.monotonic() < deadline:
            APP.processEvents()
            time.sleep(.005)
        self.assertFalse(self.canvas.preview_queue.busy)

    def test_aspect_fit_bottom_left_round_trip_and_letterbox_rejection(self):
        self.assertEqual(self.canvas.display_rect, QRectF(0, 100, 400, 200))
        self.assertEqual(self.canvas.normalized(QPointF(0, 300)), [0, 0])
        self.assertEqual(self.canvas.normalized(QPointF(400, 100)), [1, 1])
        for point in ([.12, .73], [.9, .1]):
            actual = self.canvas.normalized(self.canvas.display_point(point))
            self.assertAlmostEqual(actual[0], point[0])
            self.assertAlmostEqual(actual[1], point[1])
        self.assertIsNone(self.canvas.normalized(QPointF(200, 50)))
        self.assertTrue(fitted_rect(QRectF(0, 0, 10, 10), QSize()).isEmpty())

    def test_selection_refresh_reuses_pixels_but_image_effect_and_time_changes_repaint(self):
        from platforms.windows.bluraction import renderer
        region = {'shape': {'rectangle': {'id': 'REGION', 'origin': [.1, .1], 'size': [.8, .8]}},
                  'effect': {'style': 'solid', 'blurRadius': 25, 'featherRadius': 0,
                             'enabled': True, 'timeRange': [.5, 1]}}
        image = self.canvas.image
        state = {'regions': [region], 'drawings': []}
        with patch('platforms.windows.bluraction.ui.renderer.render', wraps=renderer.render) as draw:
            self.present(image, state, time=.75)
            self.assertEqual(self.canvas._preview.pixelColor(100, 50), QColor('black'))
            initial = bytes(self.canvas._preview.constBits())
            self.present(image, deepcopy(state), ['REGION'], time=.75)
            self.present(image, deepcopy(state), [], time=.75)
            self.assertEqual(draw.call_count, 1)
            self.assertEqual(bytes(self.canvas._preview.constBits()), initial)
            self.assertEqual(self.canvas.selection_ids, set())
            self.present(image, state, time=1.01)
            self.assertEqual(self.canvas._preview.pixelColor(100, 50), QColor('white'))
            image.setPixelColor(0, 0, QColor('red'))
            self.present(image, state, time=1.01)
            self.assertEqual(self.canvas._preview.pixelColor(0, 0), QColor('red'))
            region['effect']['color'] = {'red': 1, 'green': 0, 'blue': 0}
            self.present(image, state, time=.75)
            self.assertEqual(self.canvas._preview.pixelColor(100, 50), QColor('red'))
            self.assertEqual(draw.call_count, 4)

    def test_failed_preview_stays_blank_and_same_document_can_retry(self):
        from platforms.windows.bluraction import renderer
        image = self.canvas.image.copy()
        image.fill(QColor('red'))
        state = {'regions': [], 'drawings': []}
        calls = []
        actual_render = renderer.render
        def transient_failure(*args, **kwargs):
            calls.append(True)
            if len(calls) == 1:
                raise RuntimeError('synthetic transient render failure')
            return actual_render(*args, **kwargs)
        with patch('platforms.windows.bluraction.ui.renderer.render', side_effect=transient_failure):
            self.present(image, state)
            self.assertTrue(self.canvas._preview.isNull())
            self.present(image, state)
            self.assertEqual(self.canvas._preview.pixelColor(10, 10), QColor('red'))
            self.assertEqual(len(calls), 2)

    def test_mouse_creation_uses_source_display_rect_and_ignores_letterbox(self):
        output = []
        self.canvas.created.connect(lambda kind, points: output.append((kind, points)))
        self.canvas.set_tool('cover_rectangle')
        QTest.mousePress(self.canvas, Qt.MouseButton.LeftButton, pos=QPoint(40, 120))
        QTest.mouseRelease(self.canvas, Qt.MouseButton.LeftButton, pos=QPoint(360, 280))
        self.assertEqual(output[0][0], 'cover_rectangle')
        self.assertAlmostEqual(output[0][1][0][0], .1)
        self.assertAlmostEqual(output[0][1][0][1], .9)
        self.assertAlmostEqual(output[0][1][1][0], .9)
        self.assertAlmostEqual(output[0][1][1][1], .1)
        QTest.mousePress(self.canvas, Qt.MouseButton.LeftButton, pos=QPoint(40, 50))
        QTest.mouseRelease(self.canvas, Qt.MouseButton.LeftButton, pos=QPoint(360, 280))
        self.assertEqual(len(output), 1)

    def test_nested_region_identity_and_hidden_shape_hit_testing(self):
        region = {'shape': {'rectangle': {'id': 'REGION', 'origin': [.1, .1], 'size': [.8, .8]}},
                  'effect': {'style': 'solid', 'blurRadius': 25, 'featherRadius': 0,
                             'enabled': True, 'timeRange': [0, 0]}}
        self.present(self.canvas.image, {'regions': [region], 'drawings': []})
        self.assertEqual(self.canvas.hit_test(QPointF(200, 200)), 'REGION')
        region['effect']['enabled'] = False
        self.present(self.canvas.image, {'regions': [region], 'drawings': []})
        self.assertIsNone(self.canvas.hit_test(QPointF(200, 200)))

    def test_busy_mouse_input_cannot_create_a_shape(self):
        created = []
        self.canvas.created.connect(lambda kind, points: created.append(points))
        self.canvas.set_tool('rectangle')
        self.canvas.busy = True
        QTest.mousePress(self.canvas, Qt.MouseButton.LeftButton, pos=QPoint(40, 120))
        QTest.mouseRelease(self.canvas, Qt.MouseButton.LeftButton, pos=QPoint(360, 280))
        self.assertEqual(created, [])


class CompletionObservedWindow(BlurActionWindow):
    """Observe the real queued QObject slot without replacing it with Mock.

    A free Python callable connected to a worker signal has different Qt
    receiver affinity. This bound slot keeps result delivery on the GUI thread.
    """
    completion_observer = None

    @Slot(object)
    def export_finished(self, outcome):
        if self.completion_observer is not None:
            self.completion_observer(outcome)
        super().export_finished(outcome)


class WindowTests(unittest.TestCase):
    def setUp(self):
        self.warning_patch = patch('platforms.windows.bluraction.ui.QMessageBox.warning',
                                   return_value=QMessageBox.StandardButton.Ok)
        self.warning = self.warning_patch.start()
        self.addCleanup(self.warning_patch.stop)
        self.question_patch = patch('platforms.windows.bluraction.ui.QMessageBox.question',
                                    return_value=QMessageBox.StandardButton.No)
        self.question = self.question_patch.start()
        self.addCleanup(self.question_patch.stop)
        self.info_patch = patch('platforms.windows.bluraction.ui.QMessageBox.information',
                                return_value=QMessageBox.StandardButton.Ok)
        self.info = self.info_patch.start()
        self.addCleanup(self.info_patch.stop)
        self.temp = tempfile.TemporaryDirectory()
        self.source = Path(self.temp.name) / 'synthetic.png'
        image = QImage(160, 100, QImage.Format.Format_RGBA8888)
        image.fill(QColor('white'))
        self.assertTrue(image.save(str(self.source)))
        self.original = self.source.read_bytes()
        self.workspace = Workspace()
        self.workspace.load([self.source])
        self.window = BlurActionWindow(self.workspace)
        self.spin_until(lambda: not self.window.canvas.preview_queue.busy)

    def tearDown(self):
        # Never delete a source folder or destroy its parent window while its
        # actual QThread can still read it. Process Qt delivery and release the
        # Python GIL; QTest.qWait alone can starve Python worker callbacks.
        if self.window._thread is not None:
            thread = self.window._thread
            self.window.cancel_operation()
            deadline = time.monotonic() + 3
            while isValid(thread) and thread.isRunning() and time.monotonic() < deadline:
                APP.processEvents()
                time.sleep(.005)
            if isValid(thread):
                self.assertFalse(thread.isRunning(), 'Worker still running; synthetic source files must be retained')
                self.assertTrue(thread.wait(100), 'Stopped worker did not join')
            deadline = time.monotonic() + 1
            while self.window._thread is not None and time.monotonic() < deadline:
                APP.processEvents()
                time.sleep(.005)
            self.assertIsNone(self.window._thread)
        self.assertFalse(self.workspace.busy)
        self.workspace.dirty = False
        self.window.close()
        self.spin_until(lambda: not self.window.canvas.preview_queue.busy)
        self.assertEqual(self.source.read_bytes(), self.original)
        self.temp.cleanup()
        self.assertEqual(self.warning.call_count, 0, f'Unexpected UI errors: {self.warning.call_args_list}')

    def test_inspector_changes_only_explicit_field_and_preserves_project_precision(self):
        self.workspace.add_cover('rectangle', [[.1, .1], [.5, .5]], 'blur',
                                 499.123456789, 400.987654321)
        original = deepcopy(self.workspace.page.state['regions'][0]['effect'])
        self.window.refresh()
        self.assertAlmostEqual(self.window.radius.value(), 499.123457, places=6)
        self.assertAlmostEqual(self.window.feather.value(), 400.987654, places=6)
        self.window.style.setCurrentIndex(self.window.style.findData('mosaic'))
        result = self.workspace.page.state['regions'][0]['effect']
        self.assertEqual(result['blurRadius'], original['blurRadius'])
        self.assertEqual(result['featherRadius'], original['featherRadius'])
        self.assertEqual(result['style'], 'mosaic')
        self.workspace.undo()
        self.assertEqual(self.workspace.page.state['regions'][0]['effect'], original)
        self.workspace.redo()
        destination = Path(self.temp.name) / 'precision.bluraction'
        self.workspace.save_project(destination)
        reopened = Workspace()
        reopened.load_project(destination)
        self.assertEqual(reopened.page.state['regions'][0]['effect']['blurRadius'], original['blurRadius'])
        self.assertEqual(reopened.page.state['regions'][0]['effect']['featherRadius'], original['featherRadius'])

        self.workspace.add_drawing('rectangle', [[.1, .1], [.5, .5]], width=.123456789123,
                                   fill=.987654321123)
        before = deepcopy(self.workspace.page.state['drawings'][-1])
        self.window.refresh()
        self.assertGreater(self.window.width.value(), 100)
        self.window.fill.setValue(.25)
        self.assertEqual(self.workspace.page.state['drawings'][-1]['lineWidth'], before['lineWidth'])
        self.workspace.undo()
        self.assertEqual(self.workspace.page.state['drawings'][-1], before)
        self.workspace.selectionID = before['id']
        self.window.refresh()
        self.window.width.setValue(125.5)
        self.assertEqual(self.workspace.page.state['drawings'][-1]['fillOpacity'], before['fillOpacity'])
        self.assertEqual(self.workspace.page.state['drawings'][-1]['lineWidth'], .1255)

    def test_cover_creation_selection_and_one_undo_transaction(self):
        self.window.style.setCurrentIndex(self.window.style.findData('solid'))
        self.window.feather.setValue(0)
        self.window.create_item('cover_rectangle', [[0, 0], [.5, .5]])
        self.assertEqual(len(self.workspace.page.state['regions']), 1)
        self.assertEqual(self.window.layers.count(), 1)
        self.assertTrue(self.workspace.selectionID)
        self.assertTrue(self.window.actions['undo'].isEnabled())
        self.window.actions['undo'].trigger()
        self.assertEqual(self.workspace.page.state['regions'], [])
        self.assertTrue(self.window.actions['redo'].isEnabled())

    def test_busy_preserves_workspace_and_cancel_control_stays_enabled(self):
        page = self.workspace.page
        self.workspace.busy = True
        self.window._set_editing_enabled(False)
        self.window.refresh()
        self.window.open_paths([self.source])
        self.assertIs(self.workspace.page, page)
        self.assertFalse(self.window.actions['open'].isEnabled())
        self.assertFalse(self.window.style.isEnabled())
        self.assertTrue(self.window.cancel_button.isEnabled())
        close = QCloseEvent()
        self.window.closeEvent(close)
        self.assertFalse(close.isAccepted())
        self.workspace.busy = False  # This test set the guard without a real worker.

    def test_declining_discard_preserves_unsaved_editor_and_source(self):
        self.workspace.add_drawing('line', [[.1, .1], [.9, .9]])
        old_state = self.workspace.page.state
        with patch('platforms.windows.bluraction.ui.QMessageBox.question', return_value=0):
            self.window.open_paths([self.source])
        self.assertIs(self.workspace.page.state, old_state)
        self.assertEqual(len(old_state['drawings']), 1)

    def test_qt_frame_presentation_rotation_and_mirroring_are_applied_once(self):
        from types import SimpleNamespace
        self.workspace.video = SimpleNamespace(duration=2)
        self.workspace.time = 0
        image = QImage(20, 10, QImage.Format.Format_RGBA8888)
        image.fill(QColor('white'))
        image.setPixelColor(0, 0, QColor('red'))
        frame = QVideoFrame(image)
        frame.setRotation(QtVideo.Rotation.Clockwise90)
        frame.setMirrored(True)
        frame.setStartTime(500_000)
        self.window.playback_position_changed(500)
        self.window.video_frame_changed(frame)
        self.spin_until(lambda: not self.window.canvas.preview_queue.busy)
        self.assertEqual(self.window.canvas.image.size(), QSize(10, 20))
        self.assertEqual(self.window.canvas.image.pixelColor(0, 0), QColor('red'))
        self.assertEqual(self.workspace.time, .5)
        self.workspace.video = None

    def test_worker_seek_actual_pts_drives_creation_eraser_and_save_while_transport_differs(self):
        from fractions import Fraction
        from platforms.windows.bluraction.video import TimedImage
        calls = []
        entered, release = threading.Event(), threading.Event()
        class TimedSource:
            duration = 2
            def frame_at_timed(self, seconds, cancel=None):
                calls.append((seconds, QThread.currentThread()))
                entered.set()
                release.wait(3)
                image = QImage(160, 100, QImage.Format.Format_RGBA8888)
                image.fill(QColor('white'))
                return TimedImage(Fraction(1, 10), image)
        self.workspace.video = TimedSource()
        self.workspace.time = 0
        with patch('platforms.windows.bluraction.ui.QMediaPlayer.setSource'):
            self.window.refresh()
            self.spin_until(lambda: not self.window.canvas.preview_queue.busy)
            self.window.seek_video(.13)
            self.assertTrue(self.window.canvas.busy)
            self.spin_until(entered.is_set)
            active = self.window.canvas.preview_queue.active
            try:
                self.window.refresh()  # Selection/inspector refresh cannot substitute old pixels for the seek.
                self.assertIs(self.window.canvas.preview_queue.active, active)
                self.assertFalse(active.cancel.is_set())
                self.assertIsNone(self.window.canvas.preview_queue.pending)
            finally:
                release.set()
            self.spin_until(lambda: not self.window.canvas.preview_queue.busy)
        self.assertEqual(calls[0][0], .13)
        self.assertIsNot(calls[0][1], APP.thread())
        self.assertEqual(self.workspace.time, .1)
        self.assertEqual(self.window.canvas.time, .1)
        self.window.playback_position_changed(130)
        self.assertEqual(self.window._transport_time, .13)
        self.assertEqual(self.workspace.time, .1)
        self.window.style.setCurrentIndex(self.window.style.findData('solid'))
        self.window.feather.setValue(0)
        self.window.create_item('cover_rectangle', [[.1, .1], [.9, .9]])
        self.spin_until(lambda: not self.window.canvas.preview_queue.busy)
        region = self.workspace.page.state['regions'][0]
        self.assertEqual(region['effect']['timeRange'][0], .1)
        self.assertEqual(self.window.canvas._preview.pixelColor(80, 50), QColor('black'))
        self.window.erase_from_now.setChecked(True)
        self.window.erase_points([[.4, .5], [.6, .5]])
        self.spin_until(lambda: not self.window.canvas.preview_queue.busy)
        self.assertEqual(region['effect']['erasures'][0]['from'], .1)
        saved = Path(self.temp.name) / 'actual-displayed-pts.bluraction'
        self.workspace.save_project(saved)
        tree = json.loads(saved.read_text())
        self.assertEqual(tree['regions'][0]['effect']['timeRange'][0], .1)
        self.assertEqual(tree['regions'][0]['effect']['erasures'][0]['from'], .1)
        self.workspace.video = None

    def test_candidate_first_render_failure_preserves_old_dirty_session(self):
        self.workspace.add_drawing('line', [[.1, .1], [.9, .9]])
        self.window.refresh()
        self.spin_until(lambda: not self.window.canvas.preview_queue.busy)
        prior = (deepcopy(self.workspace.page.state), deepcopy(self.workspace._undo),
                 self.workspace.selectionID, bytes(self.window.canvas._preview.constBits()))
        target = Path(self.temp.name) / 'new-source.png'
        self.assertTrue(self.window.canvas.image.save(str(target)))
        with patch.object(self.window, 'confirm_discard', return_value=True), \
             patch('platforms.windows.bluraction.ui.renderer.render', side_effect=ValueError('first render failed')):
            self.window.open_paths([target])
            self.wait_for_operation()
        self.assertEqual(self.workspace.page.source, self.source)
        self.assertEqual(self.workspace.page.state, prior[0])
        self.assertEqual(self.workspace._undo, prior[1])
        self.assertEqual(self.workspace.selectionID, prior[2])
        self.assertEqual(bytes(self.window.canvas._preview.constBits()), prior[3])
        self.assertTrue(self.workspace.dirty)
        self.assertEqual(self.warning.call_count, 1)
        self.warning.reset_mock()

    def test_same_source_seek_resume_rejects_stale_frames_but_allows_advance_backseek_and_restart(self):
        from fractions import Fraction
        from platforms.windows.bluraction.video import TimedImage
        (source, _), base = self.fake_video_sources()
        class SeekSource(base):
            def frame_at_timed(self, seconds, cancel=None):
                result = QImage(160, 100, QImage.Format.Format_RGBA8888)
                result.fill(QColor('green'))
                return TimedImage(Fraction(str(seconds)), result)
        def frame(time_, color):
            result = QImage(160, 100, QImage.Format.Format_RGBA8888)
            result.fill(QColor(color))
            sample = QVideoFrame(result)
            sample.setStartTime(round(time_ * 1_000_000))
            return sample
        def center():
            return self.window.canvas._preview.pixelColor(80, 50)
        with patch('platforms.windows.bluraction.video.VideoSource', SeekSource), \
             patch('platforms.windows.bluraction.ui.QMediaPlayer.setSource'), \
             patch('platforms.windows.bluraction.ui.QMediaPlayer.play') as play:
            self.window.open_paths([source])
            self.wait_for_operation()
            self.window.seek_video(1.5)
            self.wait_for_presented_state()
            self.complete_injected_native_seek()
            accepted = bytes(self.window.canvas._preview.constBits())
            generation = self.window._video_generation
            self.window.toggle_playback()
            self.assertTrue(play.called)
            # Actual registered callback, same source/current pipeline as the probe.
            self.window.video_sink.videoFrameChanged.emit(frame(.1, 'red'))
            self.wait_for_presented_state()
            self.assertEqual(self.workspace.time, 1.5)
            self.assertEqual(bytes(self.window.canvas._preview.constBits()), accepted)
            self.window.seek_video(.2)
            self.wait_for_presented_state()
            self.complete_injected_native_seek()
            self.assertGreater(self.window._video_generation, generation)
            self.window.toggle_playback()
            # Pre-backwards-seek queued callback has the old pipeline identity.
            self.window.video_frame_changed(frame(1.7, 'red'), generation)
            self.wait_for_presented_state()
            self.assertEqual(self.workspace.time, .2)
            self.assertEqual(center(), QColor('green'))
            # Real Qt can emit the next valid frame BEFORE positionChanged.
            # Current-generation real PTS, not transport, is the display clock.
            self.window.video_sink.videoFrameChanged.emit(frame(.4, 'blue'))
            self.wait_for_presented_state()
            self.assertEqual(self.workspace.time, .4)
            self.assertEqual(center(), QColor('blue'))
            self.window.player.positionChanged.emit(400)
            self.window.video_sink.videoFrameChanged.emit(frame(.3, 'red'))
            self.wait_for_presented_state()
            self.assertEqual(self.workspace.time, .4)
            generation = self.window._video_generation
            self.window.player.positionChanged.emit(2000)
            self.window.toggle_playback()  # EOF restart is an explicit timed seek0.
            self.wait_for_presented_state()
            self.complete_injected_native_seek()
            self.assertGreater(self.window._video_generation, generation)
            self.assertEqual(self.workspace.time, 0)
            self.assertFalse(self.window._paused_seek)
            self.window.video_frame_changed(frame(.4, 'red'), generation)
            self.window.player.positionChanged.emit(40)
            self.window.video_sink.videoFrameChanged.emit(frame(.04, 'blue'))
            self.wait_for_presented_state()
            self.assertEqual(self.workspace.time, .04)
            self.assertEqual(center(), QColor('blue'))
        self.assertFalse(self.workspace.dirty)
        self.assertEqual(self.workspace.page.state, {'regions': [], 'drawings': []})

    def complete_injected_native_seek(self):
        """Explicit synthetic status/ack; this is not native media-load proof."""
        target = self.window._native_seek_ms
        with patch('platforms.windows.bluraction.ui.QMediaPlayer.isSeekable', return_value=True):
            self.window.player.mediaStatusChanged.emit(QMediaPlayer.MediaStatus.LoadedMedia)
            if self.window._native_seek_ms is not None:
                self.window.player.positionChanged.emit(target)
        self.assertIsNone(self.window._native_seek_ms)

    def test_native_seek_waits_for_loaded_seekable_and_ack_before_pending_play(self):
        from fractions import Fraction
        from platforms.windows.bluraction.video import TimedImage
        (source, _), base = self.fake_video_sources()
        class Source(base):
            def frame_at_timed(self, seconds, cancel=None):
                return TimedImage(Fraction(str(seconds)), self.frame_at(seconds))
        with patch('platforms.windows.bluraction.video.VideoSource', Source), \
             patch('platforms.windows.bluraction.ui.QMediaPlayer.setSource'), \
             patch('platforms.windows.bluraction.ui.QMediaPlayer.setPosition') as position, \
             patch('platforms.windows.bluraction.ui.QMediaPlayer.isSeekable', return_value=False) as seekable, \
             patch('platforms.windows.bluraction.ui.QMediaPlayer.play') as play:
            self.window.open_paths([source])
            self.wait_for_operation()
            position.reset_mock()
            self.window.seek_video(1.5, resume=True)
            self.wait_for_presented_state()
            self.window.player.mediaStatusChanged.emit(QMediaPlayer.MediaStatus.LoadingMedia)
            self.window.player.positionChanged.emit(0)
            self.assertEqual(self.window._transport_time, 1.5)
            position.assert_not_called()
            play.assert_not_called()
            self.window.player.mediaStatusChanged.emit(QMediaPlayer.MediaStatus.LoadedMedia)
            position.assert_not_called()  # Loaded alone is insufficient when not seekable.
            self.window.toggle_playback()  # Cancel a pending play without losing seek target.
            self.assertFalse(self.window._play_after_seek)
            self.assertEqual(self.window._native_seek_ms, 1500)
            self.window.toggle_playback()
            self.assertTrue(self.window._play_after_seek)
            play.assert_not_called()
            seekable.return_value = True
            self.window.player.seekableChanged.emit(True)
            position.assert_called_once_with(1500)
            self.assertTrue(self.window._native_seek_sent)
            play.assert_not_called()  # Real position acknowledgement is still pending.
            self.window.player.positionChanged.emit(1500)
            play.assert_called_once()
            self.assertIsNone(self.window._native_seek_ms)
            self.assertFalse(self.window._paused_seek)
            self.assertEqual(self.workspace.time, 1.5)
            self.assertEqual(self.window.canvas.time, 1.5)
            self.assertFalse(self.workspace.dirty)

    def test_play_button_cancels_pending_resume_during_slow_seek_without_autoplay(self):
        from fractions import Fraction
        from platforms.windows.bluraction.video import TimedImage
        entered, release = threading.Event(), threading.Event()
        (source, _), base = self.fake_video_sources()
        class SlowSource(base):
            def frame_at_timed(self, seconds, cancel=None):
                entered.set()
                if not release.wait(3):
                    raise RuntimeError('Controlled seek was not released')
                return TimedImage(Fraction(str(seconds)), self.frame_at(seconds))
        with patch('platforms.windows.bluraction.video.VideoSource', SlowSource), \
             patch('platforms.windows.bluraction.ui.QMediaPlayer.setSource'), \
             patch('platforms.windows.bluraction.ui.QMediaPlayer.play') as play:
            self.window.open_paths([source])
            self.wait_for_operation()
            try:
                self.window.seek_video(1.5, resume=True)
                self.spin_until(entered.is_set)
                self.assertTrue(self.window.canvas.preview_pending)
                self.assertTrue(self.window._play_after_seek)
                self.assertTrue(self.window.play_button.isEnabled())
                QTest.mouseClick(self.window.play_button, Qt.MouseButton.LeftButton)
                self.assertFalse(self.window._play_after_seek)
                self.assertTrue(self.window.canvas.preview_pending)
                # A new play during incoherent pixels remains forbidden.
                QTest.mouseClick(self.window.play_button, Qt.MouseButton.LeftButton)
                self.assertFalse(self.window._play_after_seek)
                play.assert_not_called()
            finally:
                release.set()
            self.wait_for_presented_state()
            self.complete_injected_native_seek()
            play.assert_not_called()
            self.assertFalse(self.window._play_after_seek)
            self.assertTrue(self.window._paused_seek)
            self.assertEqual(self.workspace.time, 1.5)
            self.assertEqual(self.window.canvas.time, 1.5)
            self.assertFalse(self.workspace.dirty)

    def test_native_seek_supersede_close_and_synchronous_ack_do_not_resume_old_request(self):
        from fractions import Fraction
        from platforms.windows.bluraction.video import TimedImage
        (source, _), base = self.fake_video_sources()
        class Source(base):
            def frame_at_timed(self, seconds, cancel=None):
                return TimedImage(Fraction(str(seconds)), self.frame_at(seconds))
        with patch('platforms.windows.bluraction.video.VideoSource', Source), \
             patch('platforms.windows.bluraction.ui.QMediaPlayer.setSource'), \
             patch('platforms.windows.bluraction.ui.QMediaPlayer.isSeekable', return_value=True), \
             patch('platforms.windows.bluraction.ui.QMediaPlayer.setPosition') as position, \
             patch('platforms.windows.bluraction.ui.QMediaPlayer.play') as play:
            self.window.open_paths([source])
            self.wait_for_operation()
            self.window.seek_video(1.5, resume=True)
            old_player = self.window.player
            self.window.seek_video(.5, resume=True)
            old_player.mediaStatusChanged.emit(QMediaPlayer.MediaStatus.LoadedMedia)
            old_player.positionChanged.emit(1500)
            self.wait_for_presented_state()
            position.assert_not_called()
            play.assert_not_called()
            self.assertEqual(self.window._transport_time, .5)
            self.assertEqual(self.workspace.time, .5)
            # setPosition's synchronous real signal sees fully initialized pending state.
            position.side_effect = lambda target: self.window.player.positionChanged.emit(target)
            self.window.player.mediaStatusChanged.emit(QMediaPlayer.MediaStatus.LoadedMedia)
            position.assert_called_once_with(500)
            play.assert_called_once()
            self.assertIsNone(self.window._native_seek_ms)
            play.reset_mock()
            self.window.seek_video(.25, resume=True)
            self.wait_for_presented_state()
            current_player = self.window.player
            close = QCloseEvent()
            self.window.closeEvent(close)
            self.assertTrue(close.isAccepted())
            current_player.mediaStatusChanged.emit(QMediaPlayer.MediaStatus.LoadedMedia)
            current_player.positionChanged.emit(250)
            play.assert_not_called()
            self.assertFalse(self.window._play_after_seek)
            self.assertIsNone(self.window._native_seek_ms)
            self.assertEqual(self.workspace.time, .25)

    def fake_video_sources(self):
        """Regular local sources with synthetic frames, no decoder/encoder claim."""
        sources = {}
        for name, color in [('A', 'red'), ('B', 'blue')]:
            path = Path(self.temp.name) / f'synthetic-video-{name}.mp4'
            path.write_bytes(f'synthetic-video-source-{name}'.encode())
            sources[path] = QColor(color)

        class FakeVideoSource:
            duration = 2
            first_frame_time = 0

            def __init__(self, path, cancel=None):
                self.source = Path(path)

            def frame_at(self, seconds, cancel=None):
                image = QImage(160, 100, QImage.Format.Format_RGBA8888)
                image.fill(sources[self.source])
                return image

            def page(self, cancel=None):
                return Page(self.source, fingerprint(self.source), self.frame_at(0))

            def validate(self, cancel=None):
                fingerprint(self.source, cancel=cancel)

        return list(sources), FakeVideoSource

    def cache_green_video_frame(self):
        image = QImage(160, 100, QImage.Format.Format_RGBA8888)
        image.fill(QColor('green'))
        frame = QVideoFrame(image)
        frame.setStartTime(400_000)
        self.window.player.positionChanged.emit(400)
        self.window.video_sink.videoFrameChanged.emit(frame)
        self.spin_until(lambda: not self.window.canvas.preview_queue.busy)
        self.assertEqual(self.window.canvas.image.pixelColor(80, 50), QColor('green'))
        self.assertEqual(self.workspace.time, .4)
        return frame

    def test_video_project_commit_uses_new_frame_and_rejects_old_pipeline_callbacks(self):
        (source_a, source_b), factory = self.fake_video_sources()
        with patch('platforms.windows.bluraction.video.VideoSource', factory), \
             patch('platforms.windows.bluraction.ui.QMediaPlayer.setSource'):
            self.window.open_paths([source_a])
            self.wait_for_operation()
            old_frame = self.cache_green_video_frame()
            old_sink, old_player = self.window.video_sink, self.window.player
            old_generation = self.window._video_generation
            project_workspace = Workspace()
            project_workspace.load([source_b])
            project_workspace.add_cover('rectangle', [[0, 0], [.5, .5]], 'solid', 25, 0)
            project = Path(self.temp.name) / 'synthetic-video-B.bluraction'
            project_workspace.save_project(project)
            presentations = []
            original = self.window.canvas.set_document

            def present(image, state, *args):
                if state is not self.workspace.page.state or self.workspace.page.source == source_b:
                    presentations.append((image.pixelColor(80, 50), state))
                original(image, state, *args)

            with patch.object(self.window.canvas, 'set_document', side_effect=present):
                self.window.open_project(project)
                self.wait_for_operation()
            self.assertEqual(self.workspace.page.source, source_b)
            self.assertTrue(presentations)
            self.assertTrue(all(color == QColor('blue') for color, _ in presentations))
            self.assertTrue(all(state is self.workspace.page.state for _, state in presentations))
            self.assertEqual(len(self.window.canvas.state['regions']), 1)
            self.assertIsNot(self.window.video_sink, old_sink)
            self.assertIsNot(self.window.player, old_player)
            # Simulate already-queued callbacks without touching deleted QObjects.
            self.window.video_frame_changed(old_frame, old_generation)
            self.window.playback_position_changed(1900, old_generation)
            self.assertEqual(self.window.canvas.image.pixelColor(80, 50), QColor('blue'))
            self.assertEqual(self.workspace.time, 0)
            self.assertTrue(self.window._video_image.isNull())

    def test_failed_media_and_project_open_preserve_video_cached_frame_and_session(self):
        (source_a, _), factory = self.fake_video_sources()
        with patch('platforms.windows.bluraction.video.VideoSource', factory), \
             patch('platforms.windows.bluraction.ui.QMediaPlayer.setSource'):
            self.window.open_paths([source_a])
            self.wait_for_operation()
            self.cache_green_video_frame()
            self.workspace.add_cover('rectangle', [[0, 0], [.5, .5]], 'solid', 25, 0)
            self.window.refresh()
            old_page, old_video = self.workspace.page, self.workspace.video
            old_player, old_sink = self.window.player, self.window.video_sink
            old_generation = self.window._video_generation
            self.window._project_path = Path(self.temp.name) / 'current-project.bluraction'
            invalid_image = Path(self.temp.name) / 'invalid-new.png'
            invalid_image.write_bytes(b'not an image')
            invalid_project = Path(self.temp.name) / 'invalid-new.bluraction'
            invalid_project.write_bytes(b'not a project')
            template_workspace = Workspace()
            template_workspace.load([self.source])
            template = Path(self.temp.name) / 'valid-failing-template.bluraction'
            template_workspace.save_project(template)
            with patch('platforms.windows.bluraction.ui.QMessageBox.question', return_value=QMessageBox.StandardButton.Yes), \
                 patch.object(self.window, 'show_error') as errors:
                self.window.open_paths([invalid_image])
                self.wait_for_operation()
                self.window.open_project(invalid_project)
                self.wait_for_operation()
                with patch('platforms.windows.bluraction.ui.QFileDialog.getOpenFileName', return_value=(str(template), '')), \
                     patch('platforms.windows.bluraction.ui.QFileDialog.getOpenFileNames', return_value=([str(invalid_image)], '')):
                    self.window.actions['template'].trigger()
                    self.wait_for_operation()
                self.assertEqual(errors.call_count, 3)
            self.window.refresh()
            self.assertIs(self.workspace.page, old_page)
            self.assertIs(self.workspace.video, old_video)
            self.assertIs(self.window.player, old_player)
            self.assertIs(self.window.video_sink, old_sink)
            self.assertEqual(self.window._video_generation, old_generation)
            self.assertEqual(self.window.canvas.image.pixelColor(80, 50), QColor('green'))
            self.assertEqual(self.workspace.time, .4)
            self.assertTrue(self.workspace.can_undo)
            self.assertTrue(self.workspace.dirty)
            self.assertEqual(self.window._project_path.name, 'current-project.bluraction')

    def test_media_reload_same_path_and_template_commit_reset_video_cache(self):
        (source_a, source_b), factory = self.fake_video_sources()
        with patch('platforms.windows.bluraction.video.VideoSource', factory), \
             patch('platforms.windows.bluraction.ui.QMediaPlayer.setSource'):
            self.window.open_paths([source_a])
            self.wait_for_operation()
            old_frame = self.cache_green_video_frame()
            old_sink = self.window.video_sink
            old_generation = self.window._video_generation
            self.window.open_paths([source_a])
            self.wait_for_operation()
            self.assertEqual(self.window.canvas.image.pixelColor(80, 50), QColor('red'))
            self.assertIsNot(self.window.video_sink, old_sink)
            self.window.video_frame_changed(old_frame, old_generation)
            self.assertEqual(self.window.canvas.image.pixelColor(80, 50), QColor('red'))
            self.cache_green_video_frame()
            project_workspace = Workspace()
            project_workspace.load([self.source])
            project_workspace.add_drawing('line', [[.1, .1], [.8, .8]])
            project = Path(self.temp.name) / 'synthetic-video-template.bluraction'
            project_workspace.save_project(project)
            with patch('platforms.windows.bluraction.ui.QFileDialog.getOpenFileName', return_value=(str(project), '')), \
                 patch('platforms.windows.bluraction.ui.QFileDialog.getOpenFileNames', return_value=([str(source_b)], '')):
                self.window.actions['template'].trigger()
                self.wait_for_operation()
            self.assertEqual(self.workspace.page.source, source_b)
            self.assertEqual(self.window.canvas.image.pixelColor(80, 50), QColor('blue'))
            self.assertEqual(len(self.window.canvas.state['drawings']), 1)
            self.assertIsNone(self.window._project_path)

    def test_worker_reports_cancellation_and_failures_instead_of_success(self):
        for error in (Cancelled('취소'), ValueError('디스크 오류')):
            def task(cancel, progress):
                raise error
            worker = ExportWorker(task)
            outcomes = []
            worker.finished.connect(outcomes.append)
            worker.run()
            self.assertIsNone(outcomes[0][0])
            self.assertIs(outcomes[0][1], error)

    def test_cancel_worker_keeps_document_busy_until_thread_stops(self):
        def task(cancel, progress):
            deadline = time.monotonic() + 2
            while not cancel() and time.monotonic() < deadline:
                time.sleep(.005)
            if cancel():
                raise Cancelled('취소')
            return []
        self.window.start_export(task)
        self.assertTrue(self.workspace.busy)
        self.assertTrue(self.window.cancel_button.isEnabled())
        event = QCloseEvent()
        self.window.closeEvent(event)
        self.assertFalse(event.isAccepted())
        deadline = time.monotonic() + 3
        while self.workspace.busy and time.monotonic() < deadline:
            APP.processEvents()
            time.sleep(.005)
        self.assertFalse(self.workspace.busy)
        self.assertIsNone(self.window._thread)
        self.assertFalse(self.window.cancel_button.isEnabled())

    def wait_for_operation(self):
        deadline = time.monotonic() + 10
        while self.workspace.busy and time.monotonic() < deadline:
            APP.processEvents()
            time.sleep(.005)
        self.assertFalse(self.workspace.busy, 'Synthetic export worker did not stop')
        self.assertIsNone(self.window._thread)
        self.spin_until(lambda: not self.window.canvas.preview_queue.busy)

    def spin_until(self, predicate):
        deadline = time.monotonic() + 3
        while not predicate() and time.monotonic() < deadline:
            APP.processEvents()
            time.sleep(.005)
        self.assertTrue(predicate(), 'Synthetic worker gate did not advance')

    def wait_for_presented_state(self):
        self.spin_until(lambda: not self.window.canvas.preview_queue.busy
                        and not self.window.canvas.preview_pending
                        and self.window.canvas.state == self.workspace.page.state
                        and self.window.canvas.time == self.workspace.time)

    def dirty_video_session(self):
        from copy import deepcopy
        self.cache_green_video_frame()
        identity = self.workspace.add_cover('rectangle', [[0, 0], [.5, .5]], 'solid', 25, 0)
        self.workspace.add_drawing('line', [[.1, .1], [.8, .8]])
        self.workspace.undo()
        self.workspace.selectionID = identity
        self.window._project_path = Path(self.temp.name) / 'operating-session.bluraction'
        self.window.refresh()
        return (self.workspace.page, self.workspace.video, deepcopy(self.workspace.page.state),
                deepcopy(self.workspace._undo), deepcopy(self.workspace._redo), set(self.workspace.selection_ids),
                self.workspace.time, self.window._video_generation, self.window._project_path)

    def assert_preserved_video_session(self, before):
        page, video, state, undo, redo, selection, playhead, generation, project = before
        self.assertIs(self.window.workspace, self.workspace)
        self.assertIs(self.workspace.page, page)
        self.assertIs(self.workspace.video, video)
        self.assertEqual(self.workspace.page.state, state)
        self.assertEqual(self.workspace._undo, undo)
        self.assertEqual(self.workspace._redo, redo)
        self.assertEqual(self.workspace.selection_ids, selection)
        self.assertEqual(self.workspace.time, playhead)
        self.assertEqual(self.window._video_generation, generation)
        self.assertEqual(self.window._project_path, project)
        self.assertEqual(self.window.canvas.image.pixelColor(80, 50), QColor('green'))
        self.assertTrue(self.workspace.dirty)

    def replacement_image(self):
        replacement = Path(self.temp.name) / 'new-source.png'
        image = QImage(100, 160, QImage.Format.Format_RGBA8888)
        image.fill(QColor('blue'))
        self.assertTrue(image.save(str(replacement)))
        return replacement

    def test_async_open_slow_hash_is_cancellable_and_preserves_dirty_video_session(self):
        from platforms.windows.bluraction import media
        (source_a, _), factory = self.fake_video_sources()
        replacement = self.replacement_image()
        entered = threading.Event()
        real_fingerprint = media.fingerprint

        def gated(path, *args, **kwargs):
            if Path(path) == replacement:
                self.assertIsNot(QThread.currentThread(), APP.thread())
                entered.set()
                deadline = time.monotonic() + 3
                while not kwargs['cancel']() and time.monotonic() < deadline:
                    time.sleep(.005)
                media.check_cancel(kwargs['cancel'])
            return real_fingerprint(path, *args, **kwargs)

        with patch('platforms.windows.bluraction.video.VideoSource', factory), \
             patch('platforms.windows.bluraction.ui.QMediaPlayer.setSource'):
            self.window.open_paths([source_a])
            self.wait_for_operation()
            before = self.dirty_video_session()
            with patch('platforms.windows.bluraction.ui.QMessageBox.question', return_value=QMessageBox.StandardButton.Yes), \
                 patch.object(media, 'fingerprint', side_effect=gated):
                self.window.open_paths([replacement])
                self.assertTrue(self.workspace.busy)
                self.spin_until(entered.is_set)
                self.assert_preserved_video_session(before)
                self.assertTrue(self.window.cancel_button.isEnabled())
                self.assertFalse(self.window.actions['open'].isEnabled())
                self.window.cancel_button.click()
                self.wait_for_operation()
            self.assert_preserved_video_session(before)
            self.assertIn('취소', self.window.statusBar().currentMessage())

    def test_async_open_discards_success_if_cancel_arrives_after_worker_result(self):
        self.window.close()
        self.window = CompletionObservedWindow(self.workspace)
        (source_a, _), factory = self.fake_video_sources()
        replacement = self.replacement_image()
        with patch('platforms.windows.bluraction.video.VideoSource', factory), \
             patch('platforms.windows.bluraction.ui.QMediaPlayer.setSource'):
            self.window.open_paths([source_a])
            self.wait_for_operation()
            before = self.dirty_video_session()
            received = []

            def late_cancel(outcome):
                self.assertIs(QThread.currentThread(), APP.thread())
                self.assertIsNone(outcome[1])
                candidate, image, pixels, actual_time = outcome[0]
                self.assertFalse(image.isNull() or pixels.isNull())
                received.append(candidate.page.source)
                self.window.cancel_operation()

            self.window.completion_observer = late_cancel
            with patch('platforms.windows.bluraction.ui.QMessageBox.question', return_value=QMessageBox.StandardButton.Yes):
                self.window.open_paths([replacement])
                self.wait_for_operation()
            self.window.completion_observer = None
            self.assertEqual(received, [replacement])
            self.assert_preserved_video_session(before)

    def test_async_open_metadata_change_after_worker_result_rejects_gui_commit(self):
        self.window.close()
        self.window = CompletionObservedWindow(self.workspace)
        (source_a, _), factory = self.fake_video_sources()
        replacement = self.replacement_image()
        with patch('platforms.windows.bluraction.video.VideoSource', factory), \
             patch('platforms.windows.bluraction.ui.QMediaPlayer.setSource'):
            self.window.open_paths([source_a])
            self.wait_for_operation()
            before = self.dirty_video_session()
            received = []

            def changed(outcome):
                self.assertIs(QThread.currentThread(), APP.thread())
                self.assertIsNone(outcome[1])
                candidate, image, pixels, actual_time = outcome[0]
                self.assertFalse(image.isNull() or pixels.isNull())
                received.append(candidate.page.source)
                replacement.write_bytes(b'changed after worker success')

            self.window.completion_observer = changed
            with patch('platforms.windows.bluraction.ui.QMessageBox.question', return_value=QMessageBox.StandardButton.Yes), \
                 patch.object(self.window, 'show_error') as error:
                self.window.open_paths([replacement])
                self.wait_for_operation()
                error.assert_called_once()
            self.window.completion_observer = None
            self.assertEqual(received, [replacement])
            self.assert_preserved_video_session(before)

    def test_async_project_save_keeps_workspace_selection_and_both_histories(self):
        from copy import deepcopy
        identity = self.workspace.add_cover('rectangle', [[0, 0], [.5, .5]], 'solid', 25, 0)
        self.workspace.add_drawing('line', [[.1, .1], [.8, .8]])
        self.workspace.undo()
        self.workspace.selectionID = identity
        self.window.refresh()
        before = (self.workspace.page, deepcopy(self.workspace._undo), deepcopy(self.workspace._redo),
                  set(self.workspace.selection_ids), deepcopy(self.workspace.page.state))
        destination = Path(self.temp.name) / 'saved-async.bluraction'
        real_save = Workspace.save_project

        def observed(candidate, path, cancel=None):
            self.assertIsNot(candidate, self.workspace)
            self.assertIsNot(QThread.currentThread(), APP.thread())
            return real_save(candidate, path, cancel=cancel)

        with patch('platforms.windows.bluraction.ui.QFileDialog.getSaveFileName', return_value=(str(destination), '')), \
             patch.object(Workspace, 'save_project', autospec=True, side_effect=observed):
            self.window.save_dialog()
            self.assertTrue(self.workspace.busy)
            self.wait_for_operation()
        self.assertIs(self.window.workspace, self.workspace)
        self.assertIs(self.workspace.page, before[0])
        self.assertEqual((self.workspace._undo, self.workspace._redo, self.workspace.selection_ids,
                          self.workspace.page.state), before[1:])
        self.assertFalse(self.workspace.dirty)
        self.assertEqual(self.window._project_path, destination)
        self.assertTrue(destination.is_file())

    def test_export_dialog_writes_real_new_png_through_worker(self):
        destination = Path(self.temp.name) / 'new-output.png'
        self.workspace.add_cover('rectangle', [[0, 0], [1, 1]], 'solid', 25, 0)
        with patch('platforms.windows.bluraction.ui.QFileDialog.getSaveFileName',
                   return_value=(str(destination), 'PNG 이미지 (*.png)')):
            self.window.export_dialog()
            self.assertTrue(self.workspace.busy)
            self.wait_for_operation()
        output = QImage(str(destination))
        self.assertFalse(output.isNull())
        self.assertEqual(output.size(), QSize(160, 100))
        self.assertEqual(output.pixelColor(80, 50), QColor('black'))

    def test_export_dialog_snapshots_200_page_metadata_without_image_buffers(self):
        original = self.workspace.page
        image = original.image
        self.workspace.pages = [Page(original.source, original.source_sha256, image,
            index, (80, 50), {'regions': [], 'drawings': []}) for index in range(200)]
        captured = []
        destination = Path(self.temp.name) / 'synthetic-metadata.pdf'
        def export(pages, path, cancel, progress):
            captured.extend(pages)
            self.assertEqual(path, destination)
            self.assertEqual(len(pages), 200)
            self.assertTrue(all(page._image is None for page in pages))
            pages[0].state['drawings'].append({'synthetic_snapshot_only': True})
            return [path]
        with patch('platforms.windows.bluraction.ui.QFileDialog.getSaveFileName',
                   return_value=(str(destination), '평탄화 PDF (*.pdf)')), \
             patch('platforms.windows.bluraction.ui.export_documents', side_effect=export):
            self.window.export_dialog()
            self.wait_for_operation()
        self.assertEqual([page.pdf_index for page in captured], list(range(200)))
        self.assertEqual(self.workspace.pages[0].state['drawings'], [])
        self.assertTrue(all(page.point_size == (80, 50) for page in captured))
        self.assertTrue(all(page.source_sha256 == original.source_sha256 for page in captured))
        self.assertTrue(all(page.source_identity == original.source_identity for page in captured))

    def test_real_pdf_export_dialog_decodes_and_flattens_inside_qthread(self):
        fixture = Path(__file__).resolve().parents[2] / 'shared/fixtures/manual-os/synthetic-three-pages.pdf'
        source = Path(self.temp.name) / 'synthetic-source.pdf'
        original_bytes = fixture.read_bytes()
        source.write_bytes(original_bytes)
        self.workspace.load([source])
        self.workspace.add_cover('rectangle', [[0, 0], [1, 1]], 'solid', 25, 0)
        self.window.refresh()
        destination = Path(self.temp.name) / 'new-flattened.pdf'
        with patch('platforms.windows.bluraction.ui.QFileDialog.getSaveFileName',
                   return_value=(str(destination), '평탄화 PDF (*.pdf)')):
            self.window.export_dialog()
            self.wait_for_operation()
        document = QPdfDocument()
        self.assertEqual(document.load(str(destination)), QPdfDocument.Error.None_)
        self.assertEqual(document.pageCount(), 3)
        first = document.render(0, QSize(160, 160))
        self.assertFalse(first.isNull())
        self.assertEqual(first.pixelColor(80, 80), QColor('black'))
        document.close()
        self.assertEqual(source.read_bytes(), original_bytes)

    def test_same_bytes_replaced_source_retains_baseline_and_worker_rejects_export(self):
        baseline = self.workspace.page.source_identity
        destination = Path(self.temp.name) / 'must-not-publish.png'
        def panel(*args):
            replacement = Path(self.temp.name) / 'replacement.png'
            replacement.write_bytes(self.original)
            os.replace(replacement, self.source)
            return str(destination), 'PNG 이미지 (*.png)'
        with patch('platforms.windows.bluraction.ui.QFileDialog.getSaveFileName', side_effect=panel), \
             patch('platforms.windows.bluraction.ui.QMessageBox.warning') as warning:
            self.window.export_dialog()
            self.wait_for_operation()
            warning.assert_called_once()
        self.assertEqual(self.workspace.page.source_identity, baseline)
        self.assertFalse(destination.exists())
        self.assertFalse(self.workspace.busy)

    def test_all_period_eraser_uses_actual_playhead_to_map_moving_geometry(self):
        from types import SimpleNamespace
        self.workspace.add_drawing('rectangle', [[.1, .1], [.3, .3]])
        self.workspace.update_selected(keyframes=[
            {'time': 0, 'rect': [[.1, .1], [.2, .2]]},
            {'time': 2, 'rect': [[.9, .5], [.2, .2]]}])
        self.workspace.video = SimpleNamespace(duration=2)
        self.workspace.time = 1
        self.window._video_source_path = str(self.source)
        self.window._video_source = self.workspace.video
        self.window.erase_from_now.setChecked(False)
        self.window.refresh()
        self.wait_for_presented_state()
        with patch.object(self.workspace, 'erase', wraps=self.workspace.erase) as erase:
            self.window.canvas.erased.emit([[.55, .35]])
            erase.assert_called_once_with([[.55, .35]], .024, 1, from_now=False,
                                           mode='partial', target='all')
        stroke = self.workspace.page.state['drawings'][0]['erasures'][0]
        self.assertNotIn('from', stroke)
        self.assertAlmostEqual(stroke['points'][0][0], .15)
        self.assertAlmostEqual(stroke['points'][0][1], .15)
        self.wait_for_presented_state()
        self.window.erase_from_now.setChecked(True)
        self.window.canvas.erased.emit([[.55, .35]])
        self.assertEqual(self.workspace.page.state['drawings'][0]['erasures'][1]['from'], 1)
        self.workspace.video = None

    def test_missing_named_font_is_preserved_and_blocks_export_until_explicit_apply(self):
        family = 'BlurAction-Synthetic-Unavailable-Font-51E86A'
        self.assertFalse(font_available(family))
        self.assertTrue(font_available(None))
        self.assertTrue(font_available('Sans Serif'))
        self.assertTrue(font_available('Monospace'))
        identity = self.workspace.add_drawing('text', [[.1, .1], [.9, .9]], text='합성 글자', font=family)
        self.window.refresh()
        self.assertEqual(self.window.font.currentText(), family)
        self.assertIn(family, self.window.font_warning.text())
        with patch('platforms.windows.bluraction.ui.QFileDialog.getSaveFileName') as panel, \
             patch('platforms.windows.bluraction.ui.QMessageBox.warning') as warning:
            self.window.export_dialog()
            panel.assert_not_called()
            warning.assert_called_once()
        self.assertEqual(self.workspace.selected()[0]['fontName'], family)
        self.assertFalse(self.workspace.busy)
        installed = QApplication.font().family()
        self.window.font.setCurrentText(installed)
        self.assertEqual(self.window.font.currentText(), installed)
        self.assertEqual(self.workspace.selected()[0]['fontName'], family)
        self.window.refresh()
        self.assertEqual(self.window.font.currentText(), installed, 'Refresh must preserve the unapplied choice')
        self.window.text_apply.click()
        self.assertEqual(self.workspace.selected()[0]['fontName'], installed)
        self.assertEqual(self.window.missing_fonts(), [])
        self.workspace.undo()
        restored = next(item for item in self.workspace.page.state['drawings'] if item['id'] == identity)
        self.assertEqual(restored['fontName'], family)
        self.workspace.selectionID = identity
        self.window.refresh()
        self.assertEqual(self.window.font.currentText(), family)

    def test_hidden_text_with_missing_font_does_not_block_visible_output(self):
        self.workspace.add_drawing('text', [[.1, .1], [.9, .9]], text='합성',
                                   font='BlurAction-Synthetic-Missing-Hidden-Font')
        self.workspace.update_selected(hidden=True)
        self.window.refresh()
        self.assertEqual(self.window.missing_fonts(), [])

    def test_item_eraser_target_selector_deletes_only_intersecting_regions(self):
        for _ in range(2):
            self.workspace.add_cover('rectangle', [[.1, .1], [.5, .5]], 'solid', 25, 0)
            self.workspace.add_drawing('rectangle', [[.1, .1], [.5, .5]], fill=1)
        self.workspace.selection_ids.clear()
        self.window.eraser_mode.setCurrentIndex(self.window.eraser_mode.findData('item'))
        self.window.eraser_target.setCurrentIndex(self.window.eraser_target.findData('regions'))
        self.window.refresh()
        self.wait_for_presented_state()
        self.window.canvas.erased.emit([[.3, .3]])
        self.assertEqual(len(self.workspace.page.state['regions']), 0)
        self.assertEqual(len(self.workspace.page.state['drawings']), 2)
        self.workspace.undo()
        self.assertEqual(len(self.workspace.page.state['regions']), 2)
        self.assertEqual(len(self.workspace.page.state['drawings']), 2)

    def test_recorded_keyframe_time_control_retimes_with_one_undo(self):
        from types import SimpleNamespace
        from copy import deepcopy
        identity = self.workspace.add_drawing('rectangle', [[.1, .1], [.3, .3]])
        frames = [{'time': 0, 'rect': [[.1, .1], [.2, .2]]},
                  {'time': 2, 'rect': [[.7, .5], [.2, .2]]}]
        self.workspace.update_selected(keyframes=frames)
        self.workspace.video = SimpleNamespace(duration=2)
        self.workspace.time = 0
        self.window._video_source_path = str(self.source)
        self.window._video_source = self.workspace.video
        self.window.refresh()
        self.window.keyframes.setCurrentRow(0)
        self.assertEqual(self.window.keyframe_time.value(), 0)
        self.window.keyframe_time.setValue(1)
        self.window.retime_button.click()
        actual = self.workspace.selected()[0]['keyframes']
        self.assertEqual([frame['time'] for frame in actual], [1, 2])
        self.assertEqual([frame['rect'] for frame in actual], [frame['rect'] for frame in frames])
        self.workspace.undo()
        restored = next(item for item in self.workspace.page.state['drawings'] if item['id'] == identity)
        self.assertEqual(restored['keyframes'], frames)
        self.workspace.selectionID = identity
        self.window.refresh()
        self.window.keyframes.setCurrentRow(0)
        before = deepcopy(self.workspace.selected()[0]['keyframes'])
        self.window.keyframe_time.setValue(2)
        with patch('platforms.windows.bluraction.ui.QMessageBox.warning') as warning:
            self.window.retime_button.click()
            warning.assert_called_once()
        self.assertEqual(self.workspace.selected()[0]['keyframes'], before)
        self.workspace.video = None

    def test_item_eraser_from_now_control_preserves_prior_video_interval(self):
        from types import SimpleNamespace
        self.workspace.video = SimpleNamespace(duration=2)
        self.workspace.time = 0
        self.window._video_source_path = str(self.source)
        self.window._video_source = self.workspace.video
        self.workspace.add_cover('rectangle', [[.1, .1], [.6, .6]], 'solid', 25, 0)
        self.workspace.time = 1
        self.window.eraser_mode.setCurrentIndex(self.window.eraser_mode.findData('item'))
        self.window.erase_from_now.setChecked(True)
        self.window.refresh()
        self.wait_for_presented_state()
        self.window.canvas.erased.emit([[.3, .3]])
        regions = self.workspace.page.state['regions']
        self.assertEqual(len(regions), 1)
        self.assertEqual(regions[0]['effect']['timeRange'][0], 0)
        self.assertLess(regions[0]['effect']['timeRange'][1], 1)
        self.assertGreater(regions[0]['effect']['timeRange'][1], .99)
        self.workspace.video = None

    def make_two_page_items_project(self):
        project = Path(self.temp.name) / 'synthetic-two-page.bluraction'
        self.workspace.load([self.source, self.source])
        self.workspace.add_drawing('rectangle', [[.1, .1], [.4, .4]])
        self.workspace.set_page(1)
        self.workspace.add_drawing('arrow', [[.2, .2], [.8, .8]])
        arrow_id = self.workspace.selected()[0]['id']
        self.workspace.save_project(project)
        self.workspace.load([self.source])
        self.window.refresh()
        return project, arrow_id

    def test_duplicate_and_absolute_layer_order_actions_use_engine_transactions(self):
        first = self.workspace.add_drawing('rectangle', [[.1, .1], [.3, .3]])
        self.workspace.add_drawing('ellipse', [[.6, .6], [.9, .9]])
        self.workspace.selectionID = first
        self.window.refresh()
        self.assertEqual(self.window.actions['duplicate'].shortcut().toString(), 'Ctrl+D')
        self.window.actions['duplicate'].trigger()
        drawings = self.workspace.page.state['drawings']
        self.assertEqual(len(drawings), 3)
        self.assertNotEqual(drawings[0]['id'], drawings[2]['id'])
        self.assertNotEqual(drawings[0]['points'], drawings[2]['points'])
        self.workspace.undo()
        self.assertEqual(len(self.workspace.page.state['drawings']), 2)
        self.workspace.selectionID = first
        self.window.refresh()
        self.window.actions['to_front'].trigger()
        self.assertEqual(self.workspace.page.state['drawings'][-1]['id'], first)
        self.window.actions['to_back'].trigger()
        self.assertEqual(self.workspace.page.state['drawings'][0]['id'], first)

    def test_import_items_action_selects_v2_page_and_regenerates_ids_with_undo(self):
        project, imported_id = self.make_two_page_items_project()
        with patch('platforms.windows.bluraction.ui.QFileDialog.getOpenFileName',
                   return_value=(str(project), 'BlurAction 프로젝트 (*.bluraction)')), \
             patch('platforms.windows.bluraction.ui.QInputDialog.getInt', return_value=(2, True)) as page_panel:
            self.window.actions['import_items'].trigger()
        page_panel.assert_called_once()
        self.assertEqual(len(self.workspace.page.state['drawings']), 1)
        imported = self.workspace.page.state['drawings'][0]
        self.assertEqual(imported['kind'], 'arrow')
        self.assertNotEqual(imported['id'], imported_id)
        self.workspace.undo()
        self.assertEqual(self.workspace.page.state['drawings'], [])

    def test_template_action_declining_discard_preserves_current_session(self):
        self.workspace.add_drawing('line', [[.1, .1], [.8, .8]])
        old_page = self.workspace.page
        self.window.refresh()
        with patch('platforms.windows.bluraction.ui.QFileDialog.getOpenFileName') as panel:
            self.window.actions['template'].trigger()
            panel.assert_not_called()
        self.assertIs(self.workspace.page, old_page)

    def test_template_action_explicitly_applies_selected_page_to_new_media(self):
        project, _ = self.make_two_page_items_project()
        replacement = Path(self.temp.name) / 'synthetic-template-target.png'
        image = QImage(100, 160, QImage.Format.Format_RGBA8888)
        image.fill(QColor('blue'))
        self.assertTrue(image.save(str(replacement)))
        self.workspace.add_drawing('line', [[.1, .1], [.3, .3]])
        self.window.refresh()
        with patch('platforms.windows.bluraction.ui.QMessageBox.question', return_value=QMessageBox.StandardButton.Yes), \
             patch('platforms.windows.bluraction.ui.QFileDialog.getOpenFileName', return_value=(str(project), '')), \
             patch('platforms.windows.bluraction.ui.QInputDialog.getInt', return_value=(2, True)), \
             patch('platforms.windows.bluraction.ui.QFileDialog.getOpenFileNames', return_value=([str(replacement)], '')):
            self.window.actions['template'].trigger()
            self.wait_for_operation()
        self.assertEqual(self.workspace.page.source, replacement)
        self.assertEqual([item['kind'] for item in self.workspace.page.state['drawings']], ['arrow'])
        self.assertTrue(self.workspace.dirty)
        self.assertIsNone(self.window._project_path)

    def test_template_menu_applies_valid_project_from_empty_session(self):
        project, _ = self.make_two_page_items_project()
        self.workspace = Workspace()
        self.window.workspace = self.workspace
        self.window.refresh()
        self.assertIsNone(self.workspace.page)
        self.assertTrue(self.window.actions['template'].isEnabled())
        with patch('platforms.windows.bluraction.ui.QFileDialog.getOpenFileName', return_value=(str(project), '')), \
             patch('platforms.windows.bluraction.ui.QInputDialog.getInt', return_value=(2, True)), \
             patch('platforms.windows.bluraction.ui.QFileDialog.getOpenFileNames', return_value=([str(self.source)], '')):
            self.window.actions['template'].trigger()
            self.wait_for_operation()
        self.assertEqual(self.workspace.page.source, self.source)
        self.assertEqual([item['kind'] for item in self.workspace.page.state['drawings']], ['arrow'])
        self.assertTrue(self.workspace.dirty)

    def make_unverified_relink_project(self):
        project = Path(self.temp.name) / 'synthetic-unverified.bluraction'
        self.workspace.add_drawing('rectangle', [[.1, .1], [.3, .3]])
        self.workspace.save_project(project)
        tree = json.loads(project.read_text())
        tree['pages'][0]['mediaPath'] = 'C:\\missing\\synthetic-unverified.png'
        tree['pages'][0].pop('sourceSHA256')
        project.write_text(json.dumps(tree), encoding='utf-8')
        return project

    def test_unverified_relink_decline_preserves_current_workspace(self):
        project = self.make_unverified_relink_project()
        old_page = self.workspace.page
        with patch('platforms.windows.bluraction.ui.QFileDialog.getOpenFileName', return_value=(str(self.source), '')):
            self.window.open_project(project)
            self.wait_for_operation()
        self.assertIs(self.workspace.page, old_page)
        self.assertIsNone(self.window._project_path)
        self.assertIn('증명할 수 없습니다', self.question.call_args.args[2])

    def test_unverified_relink_requires_explicit_acknowledgement_before_load(self):
        project = self.make_unverified_relink_project()
        old_page = self.workspace.page
        def choose(*args):
            self.assertIs(QThread.currentThread(), APP.thread())
            self.assertFalse(self.workspace.busy)
            self.assertIsNone(self.window._thread)
            return str(self.source), ''

        def acknowledge(*args):
            self.assertIs(QThread.currentThread(), APP.thread())
            self.assertFalse(self.workspace.busy)
            self.assertIsNone(self.window._thread)
            return QMessageBox.StandardButton.Yes

        with patch('platforms.windows.bluraction.ui.QFileDialog.getOpenFileName', side_effect=choose), \
             patch('platforms.windows.bluraction.ui.QMessageBox.question', side_effect=acknowledge) as question:
            self.window.open_project(project)
            self.wait_for_operation()
        self.assertIsNot(self.workspace.page, old_page)
        self.assertEqual(self.window._project_path, project)
        self.assertEqual(len(self.workspace.page.state['drawings']), 1)
        self.assertEqual(self.workspace.page.source, self.source)
        self.assertIn('증명할 수 없습니다', question.call_args.args[2])


if __name__ == '__main__':
    unittest.main()
