"""Real QObject/queued worker integration; not actual Windows performance QA."""
import os
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
from copy import deepcopy
import threading
import time
import unittest
from unittest.mock import patch

from PySide6.QtCore import QObject, QThread, Slot
from PySide6.QtGui import QColor, QImage
from PySide6.QtWidgets import QApplication

from platforms.windows.bluraction import renderer
from platforms.windows.bluraction.preview_worker import PreviewQueue, PreviewRequest
from platforms.windows.bluraction.ui import EditorCanvas

APP = QApplication.instance() or QApplication([])


def image(color):
    result = QImage(48, 32, QImage.Format.Format_RGBA8888)
    result.fill(QColor(color))
    result.setPixelColor(0, 0, QColor('green'))
    return result


class Receiver(QObject):
    def __init__(self):
        super().__init__()
        self.results, self.threads = [], []

    @Slot(object)
    def received(self, result):
        self.results.append(result)
        self.threads.append(QThread.currentThread())


class PreviewWorkerTests(unittest.TestCase):
    def setUp(self):
        self.queue = PreviewQueue()
        self.receiver = Receiver()
        self.queue.completed.connect(self.receiver.received)
        self.release = threading.Event()

    def spin(self, predicate):
        deadline = time.monotonic() + 5
        while not predicate() and time.monotonic() < deadline:
            APP.processEvents()
            time.sleep(.005)
        self.assertTrue(predicate())

    def tearDown(self):
        self.release.set()
        self.queue.shutdown()
        self.spin(lambda: not self.queue.busy)

    def request(self, key, color='white', state=None, time_=None):
        return PreviewRequest(key, image(color), deepcopy(state or {'regions': [], 'drawings': []}), time_)

    def test_actual_full_resolution_worker_matches_same_renderer_and_gui_affinity(self):
        for style in ['blur', 'mosaic', 'solid']:
            state = {'regions': [{'shape': {'rectangle': {'id': 'r', 'origin': [.1, .1], 'size': [.8, .8]}},
                     'effect': {'style': style, 'enabled': True, 'blurRadius': 7.25,
                                'featherRadius': 2.5, 'timeRange': [.1, .9]}}], 'drawings': []}
            source = self.request(style, 'red', state, .5)
            expected = renderer.render(source.image, state, .5)
            original = bytes(source.image.constBits())
            self.queue.submit(source)
            self.spin(lambda: not self.queue.busy)
            _, actual_image, actual_time, actual, error = self.receiver.results[-1]
            self.assertIsNone(error)
            self.assertEqual(actual.size(), source.image.size())
            self.assertEqual(bytes(actual.constBits()), bytes(expected.constBits()))
            self.assertEqual(bytes(actual_image.constBits()), original)
            self.assertEqual(actual_time, .5)
            self.assertIs(self.receiver.threads[-1], APP.thread())

    def test_running_one_latest_pending_only_and_thread_execution(self):
        entered, threads = threading.Event(), []
        actual = renderer.render
        def slow(source, state, time_):
            threads.append(QThread.currentThread())
            if not entered.is_set():
                entered.set()
                self.release.wait(3)
            return actual(source, state, time_)
        with patch('platforms.windows.bluraction.preview_worker.renderer.render', side_effect=slow):
            first = self.request('first')
            self.queue.submit(first)
            self.spin(entered.is_set)
            for number in range(100):
                self.queue.submit(self.request(number))
            self.assertIs(self.queue.active, first)
            self.assertEqual(self.queue.pending.context, 99)
            self.release.set()
            self.spin(lambda: not self.queue.busy)
        self.assertEqual([row[0].context for row in self.receiver.results], ['first', 99])
        self.assertEqual(len(threads), 2)
        self.assertTrue(all(thread is not APP.thread() for thread in threads))

    def test_close_drops_pending_and_late_result_without_joining_gui(self):
        entered = threading.Event()
        actual = renderer.render
        def slow(*args):
            entered.set()
            self.release.wait(3)
            return actual(*args)
        with patch('platforms.windows.bluraction.preview_worker.renderer.render', side_effect=slow):
            self.queue.submit(self.request('old'))
            self.spin(entered.is_set)
            self.queue.submit(self.request('pending'))
            self.queue.shutdown()
            self.assertTrue(self.queue.busy)
            self.assertIsNone(self.queue.pending)
            self.release.set()
            self.spin(lambda: not self.queue.busy)
        self.assertEqual(self.receiver.results, [])

    def test_canvas_old_source_result_cannot_paint_new_state_or_accept_gesture(self):
        canvas = EditorCanvas()
        entered = threading.Event()
        actual = renderer.render
        def slow(*args):
            if not entered.is_set():
                entered.set()
                self.release.wait(3)
            return actual(*args)
        try:
            with patch('platforms.windows.bluraction.preview_worker.renderer.render', side_effect=slow):
                canvas.preview_context = 'old'
                canvas.set_document(image('red'), {'regions': [], 'drawings': []}, time=.1)
                self.spin(entered.is_set)
                canvas.preview_context = 'new'
                canvas.set_document(image('blue'), {'regions': [], 'drawings': []}, time=.2)
                self.assertTrue(canvas.busy)
                self.assertTrue(canvas._preview.isNull())
                self.release.set()
                self.spin(lambda: not canvas.preview_queue.busy)
            self.assertEqual(canvas._accepted_context, 'new')
            self.assertEqual(canvas.image.pixelColor(20, 20), QColor('blue'))
            self.assertEqual(canvas.time, .2)
            self.assertFalse(canvas.preview_pending)
        finally:
            self.release.set()
            canvas.close()
            self.spin(lambda: not canvas.preview_queue.busy)
