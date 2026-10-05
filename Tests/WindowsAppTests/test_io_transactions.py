"""Actual local files and cancellation; fake HEIC bytes are not codec proof."""
import os
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
from copy import deepcopy
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch

from PySide6.QtGui import QColor, QImage
from PySide6.QtWidgets import QApplication
from platforms.windows.bluraction.editor import Workspace
from platforms.windows.bluraction import media, heif_codec

APP = QApplication.instance() or QApplication([])


class IOTransactionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.folder = Path(self.temp.name)
        self.source = self.folder / 'original.png'
        image = QImage(40, 30, QImage.Format.Format_RGBA8888)
        image.fill(QColor('white'))
        self.assertTrue(image.save(str(self.source)))
        self.original = self.source.read_bytes()
        self.workspace = Workspace()
        self.workspace.load([self.source])
        self.workspace.add_cover('rectangle', [[0, 0], [.5, .5]], style='solid', feather=0)

    def tearDown(self):
        self.assertEqual(self.source.read_bytes(), self.original)
        self.temp.cleanup()

    def test_cancelled_open_project_and_template_keep_dirty_session_and_histories(self):
        saved = self.folder / 'previous.bluraction'
        self.workspace.clone_for_io().save_project(saved)
        old_pages = self.workspace.pages
        before = deepcopy(self.workspace.__dict__)
        cancel = threading.Event(); cancel.set()
        operations = [lambda: self.workspace.load([self.source], cancel=cancel.is_set),
                      lambda: self.workspace.load_project(saved, cancel=cancel.is_set),
                      lambda: self.workspace.apply_project_template(saved, [self.source], cancel=cancel.is_set)]
        for operation in operations:
            with self.assertRaises(media.Cancelled):
                operation()
            self.assertIs(self.workspace.pages, old_pages)
            self.assertEqual(self.workspace.page.state, before['pages'][0].state)
            self.assertEqual(self.workspace._undo, before['_undo'])
            self.assertEqual(self.workspace._redo, before['_redo'])
            self.assertEqual(self.workspace.selection_ids, before['selection_ids'])
            self.assertTrue(self.workspace.dirty)

    def test_cancel_after_project_private_write_never_publishes_or_marks_saved(self):
        cancel = threading.Event()
        target = self.folder / 'cancelled.bluraction'
        before = deepcopy(self.workspace.page.state)
        real_sync = media.os.fsync
        def sync_then_cancel(descriptor):
            real_sync(descriptor)
            cancel.set()
        with patch.object(media.os, 'fsync', side_effect=sync_then_cancel):
            with self.assertRaises(media.Cancelled):
                self.workspace.save_project(target, cancel=cancel.is_set)
        self.assertFalse(target.exists())
        self.assertEqual(self.workspace.page.state, before)
        self.assertTrue(self.workspace.dirty)
        self.assertIsNone(self.workspace._project_tree)
        self.assertFalse(list(self.folder.glob('.bluraction-*')))

    def test_adopt_rechecks_identity_without_io_and_preserves_current_on_change(self):
        replacement = self.folder / 'replacement.png'
        replacement.write_bytes(self.original)
        candidate = Workspace(); candidate.load([replacement])
        pages, state = self.workspace.pages, deepcopy(self.workspace.page.state)
        replacement.write_bytes(self.original + b'changed after worker result')
        with self.assertRaises(ValueError), patch.object(media, 'fingerprint', side_effect=AssertionError('GUI hash')):
            self.workspace.adopt(candidate)
        self.assertIs(self.workspace.pages, pages)
        self.assertEqual(self.workspace.page.state, state)
        replacement.write_bytes(self.original)
        candidate.load([replacement])
        with patch.object(media, 'fingerprint', side_effect=AssertionError('GUI hash')):
            self.workspace.adopt(candidate)
        self.assertEqual(self.workspace.page.source, replacement)
        self.assertFalse(self.workspace.dirty)

    def test_io_clone_has_independent_edits_without_decoding_all_pages(self):
        with patch.object(media, 'page_image', side_effect=AssertionError('Decoded during metadata snapshot')):
            candidate = self.workspace.clone_for_io()
        self.assertIsNone(candidate.page._image)
        candidate.page.state['regions'][0]['effect']['name'] = 'worker only'
        self.assertNotIn('name', self.workspace.page.state['regions'][0]['effect'])
        self.assertTrue(self.workspace.can_undo)

    def test_fake_heic_pipeline_uses_flattened_pixels_and_late_cancel_guard(self):
        source = self.folder / 'fake-primary.heic'
        source.write_bytes(b'policy fake HEIC, not an encoded media file')
        image = self.workspace.page.image
        header = heif_codec.HeifMetadata((40, 30), 8, False, 2)
        with patch.object(heif_codec, 'inspect_heif', return_value=header), \
             patch.object(heif_codec, 'read_heif', return_value=image):
            workspace = Workspace(); workspace.load([source])
            workspace.add_cover('rectangle', [[0, 0], [.5, .5]], style='solid', feather=0)
            cancel = threading.Event()
            def encode_then_cancel(rendered, quality):
                self.assertEqual(rendered.pixelColor(5, 25), QColor('black'))
                self.assertEqual(rendered.pixelColor(35, 5), QColor('white'))
                cancel.set()
                return b'fake bytes only'
            with patch.object(heif_codec, 'encode_heic', side_effect=encode_then_cancel):
                with self.assertRaises(media.Cancelled):
                    media.export_image(workspace.page, self.folder / 'cancelled.heic', 'heic', cancel=cancel.is_set)
        self.assertFalse((self.folder / 'cancelled.heic').exists())
        self.assertEqual(source.read_bytes(), b'policy fake HEIC, not an encoded media file')
        self.assertFalse(list(self.folder.glob('.bluraction-*')))


if __name__ == '__main__':
    unittest.main()
