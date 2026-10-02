"""Real Qt export lifetime checks; a Mac run is not Windows sharing evidence.

Only authored images are read. QFile references are intentionally retained to
observe the owned handle; writer/painter references are weak, so observation
does not extend native writer lifetime. No emulated Windows open-file rules.
"""
import os
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')

from contextlib import ExitStack
from copy import deepcopy
import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import weakref

from PySide6.QtCore import QFile, QSize
from PySide6.QtGui import QColor, QImage, QImageWriter, QPainter, QPdfWriter
from PySide6.QtPdf import QPdfDocument
from PySide6.QtWidgets import QApplication
import shiboken6

from platforms.windows.bluraction import media
from platforms.windows.bluraction.editor import Workspace

APP = QApplication.instance() or QApplication([])


class QtLifetimeObservation:
    """Capture real Qt devices and non-owning writer/painter observations."""
    def __init__(self, case, *, fault=None, cleanup_faults=()):
        self.case, self.fault = case, fault
        self.cleanup_faults = frozenset(cleanup_faults)
        self.devices, self.writers, self.painters = [], [], []
        self.events = []
        self.wrote = False
        self.validations = 0
        self.publications = 0
        self.unlinks = 0
        self._stack = ExitStack()

    def closed(self, stage):
        self.case.assertTrue(self.devices, stage + ': owned QFile not observed')
        for device in self.devices:
            self.case.assertTrue(shiboken6.isValid(device), stage + ': retained device invalid')
            self.case.assertFalse(device.isOpen(), stage + ': owned QFile still open')
        # A weak observer cannot keep a writer alive. Check this at the commit
        # boundaries rather than deleting Qt objects from the test.
        for reference in self.writers:
            writer = reference()
            self.case.assertTrue(writer is None or not shiboken6.isValid(writer),
                                 stage + ': local native writer still alive')
        for reference in self.painters:
            painter = reference()
            if painter is not None and shiboken6.isValid(painter):
                self.case.assertFalse(painter.isActive(), stage + ': painter still active')
        self.events.append(stage)

    def __enter__(self):
        observation = self

        class ObservedFile(QFile):
            def __init__(self, *args):
                super().__init__(*args)
                observation.devices.append(self)

            def open(self, *args):
                if observation.fault == 'open':
                    observation.events.append('open-fault')
                    return False
                return super().open(*args)

            def flush(self):
                # The real writer must have gone out of scope before flushing
                # the device; otherwise PDF finalization can follow the flush.
                for reference in observation.writers:
                    writer = reference()
                    observation.case.assertTrue(writer is None or not shiboken6.isValid(writer),
                                                'writer must be released before QFile.flush')
                result = super().flush()
                observation.events.append('real-flush')
                return False if observation.fault == 'flush' else result

            def close(self):
                super().close()
                observation.events.append('device-close')
                if 'close' in observation.cleanup_faults:
                    raise OSError('injected cleanup error after real QFile.close')

        class ObservedImageWriter(QImageWriter):
            def __init__(self, device, *args):
                observation.case.assertIsInstance(device, QFile)
                observation.case.assertTrue(device.isOpen())
                super().__init__(device, *args)
                observation.writers.append(weakref.ref(self))

            def write(self, image):
                result = super().write(image)
                observation.wrote = True
                observation.events.append('real-image-write')
                observation.case.assertTrue(result, self.errorString())
                return False if observation.fault == 'write' else result

        class ObservedPdfWriter(QPdfWriter):
            def __init__(self, device, *args):
                observation.case.assertIsInstance(device, QFile)
                observation.case.assertTrue(device.isOpen())
                super().__init__(device, *args)
                observation.writers.append(weakref.ref(self))

            def newPage(self):
                result = super().newPage()
                observation.wrote = True
                observation.events.append('real-pdf-newpage')
                observation.case.assertTrue(result)
                return False if observation.fault == 'write' else result

        class ObservedPainter(QPainter):
            def __init__(self, *args):
                super().__init__(*args)
                observation.painters.append(weakref.ref(self))

            def end(self):
                result = super().end()
                observation.events.append('real-painter-end')
                if 'painter-end' in observation.cleanup_faults:
                    raise OSError('injected cleanup error after real QPainter.end')
                return result

        real_validate, real_publish, real_unlink = media.validate_sources, media.publish_new, Path.unlink

        def validate(pages, cancel=None):
            observation.validations += 1
            if observation.devices:
                observation.closed('before-post-write-validation')
                if observation.fault == 'validation':
                    raise OSError('injected post-write validation failure')
            return real_validate(pages, cancel)

        def publish(temporary, destination):
            observation.closed('before-publish')
            observation.publications += 1
            if observation.fault == 'collision':
                with Path(destination).open('xb') as output:
                    output.write(b'rival output: must survive')
            if observation.fault == 'publish':
                raise OSError('injected publication failure')
            return real_publish(temporary, destination)

        def unlink(path, *args, **kwargs):
            if path.name.startswith('.bluraction-'):
                observation.closed('before-owned-temp-unlink')
                observation.unlinks += 1
                if 'unlink' in observation.cleanup_faults:
                    raise OSError('injected owned-temp unlink failure; file retained')
            return real_unlink(path, *args, **kwargs)

        try:
            self._stack.enter_context(patch.object(media, 'QFile', ObservedFile))
            self._stack.enter_context(patch.object(media, 'QImageWriter', ObservedImageWriter))
            self._stack.enter_context(patch.object(media, 'QPdfWriter', ObservedPdfWriter))
            self._stack.enter_context(patch.object(media, 'QPainter', ObservedPainter))
            self._stack.enter_context(patch.object(media, 'validate_sources', validate))
            self._stack.enter_context(patch.object(media, 'publish_new', publish))
            self._stack.enter_context(patch.object(Path, 'unlink', unlink))
            return self
        except BaseException:
            self._stack.close()
            raise

    def __exit__(self, *error):
        return self._stack.__exit__(*error)


class ExportLifetimeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        self.sources = []
        for index, (width, height) in enumerate(((160, 100), (120, 80))):
            source = self.folder / f'authored-{index}.png'
            image = QImage(width, height, QImage.Format.Format_RGBA8888)
            image.fill(QColor('white'))
            self.assertTrue(image.save(str(source), 'PNG'))
            self.sources.append(source)
        self.source_bytes = {source: source.read_bytes() for source in self.sources}
        self.source_sha = {source: hashlib.sha256(data).hexdigest()
                           for source, data in self.source_bytes.items()}
        self.workspace = Workspace()
        self.workspace.load(self.sources)
        for index in range(2):
            self.workspace.index = index
            self.workspace.add_cover('rectangle', [[0, 0], [.5, .5]], 'solid', 0, 0)
        self.workspace.index = 0
        self.pages = self.workspace.pages
        self.states = deepcopy([page.state for page in self.pages])
        self.source_pixels = [bytes(page.image.constBits()) for page in self.pages]

    def tearDown(self):
        for source in self.sources:
            self.assertEqual(source.read_bytes(), self.source_bytes[source])
            self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), self.source_sha[source])
        self.assertEqual([page.state for page in self.pages], self.states)
        self.assertEqual([bytes(page.image.constBits()) for page in self.pages], self.source_pixels)
        self.assertEqual(list(self.folder.glob('.bluraction-*')), [])

    def export(self, kind, destination, *, cancel=None, progress=None):
        if kind == 'pdf':
            media.export_pdf(self.pages, destination, cancel=cancel, progress=progress)
        else:
            media.export_image(self.pages[0], destination, format=kind, quality=100, cancel=cancel)

    def assert_boundary_observed(self, observation, *, publication):
        observation.closed('after-export-call')
        self.assertEqual(observation.unlinks, 1)
        self.assertEqual(observation.publications, publication)
        self.assertIn('device-close', observation.events)

    def test_actual_png_jpeg_tiff_roundtrip_and_closed_before_commit(self):
        for kind in ('png', 'jpeg', 'tiff'):
            with self.subTest(format=kind):
                destination = self.folder / ('actual.' + kind)
                with QtLifetimeObservation(self) as observation:
                    self.export(kind, destination)
                    self.assert_boundary_observed(observation, publication=1)
                result = QImage(str(destination))
                self.assertFalse(result.isNull(), f'actual {kind} output did not reopen')
                self.assertEqual(result.size(), QSize(160, 100))
                self.assertEqual(result.pixelColor(20, 80), QColor('black'))
                self.assertEqual(result.pixelColor(20, 20), QColor('white'))
                if kind != 'jpeg':
                    expected = media.render(self.pages[0].image, self.pages[0].state)
                    result_rgba = result.convertToFormat(QImage.Format.Format_RGBA8888)
                    expected_rgba = expected.convertToFormat(QImage.Format.Format_RGBA8888)
                    self.assertEqual(bytes(result_rgba.constBits()), bytes(expected_rgba.constBits()))

    def test_actual_two_page_pdf_finalized_readable_and_devices_closed(self):
        destination = self.folder / 'actual.pdf'
        with QtLifetimeObservation(self) as observation:
            self.export('pdf', destination)
            self.assert_boundary_observed(observation, publication=1)
        document = QPdfDocument()
        try:
            self.assertEqual(document.load(str(destination)), QPdfDocument.Error.None_)
            self.assertEqual(document.pageCount(), 2)
            for index, size in enumerate((QSize(160, 100), QSize(120, 80))):
                points = document.pagePointSize(index)
                self.assertEqual((points.width(), points.height()),
                                 (size.width() / 2, size.height() / 2))
                image = document.render(index, size)
                self.assertFalse(image.isNull())
                self.assertEqual(image.pixelColor(size.width() // 8, size.height() * 4 // 5), QColor('black'))
                self.assertEqual(image.pixelColor(size.width() // 8, size.height() // 5), QColor('white'))
        finally:
            document.close()

    def test_actual_image_write_then_reported_failure_closes_and_cleans(self):
        destination = self.folder / 'write-failure.png'
        with QtLifetimeObservation(self, fault='write') as observation:
            with self.assertRaisesRegex(ValueError, '이미지 저장 실패'):
                self.export('png', destination)
            self.assertTrue(observation.wrote)
            self.assert_boundary_observed(observation, publication=0)
        self.assertFalse(destination.exists())

    def test_actual_pdf_page_write_then_failure_closes_and_cleans(self):
        destination = self.folder / 'write-failure.pdf'
        with QtLifetimeObservation(self, fault='write') as observation:
            with self.assertRaisesRegex(ValueError, 'PDF 페이지 저장'):
                self.export('pdf', destination)
            self.assertTrue(observation.wrote)
            self.assert_boundary_observed(observation, publication=0)
        self.assertFalse(destination.exists())

    def test_qfile_flush_failure_never_publishes_and_closes_both_writers(self):
        for kind in ('png', 'pdf'):
            with self.subTest(format=kind):
                destination = self.folder / ('flush-failure.' + kind)
                with QtLifetimeObservation(self, fault='flush') as observation:
                    with self.assertRaisesRegex(ValueError, '저장 마무리 실패'):
                        self.export(kind, destination)
                    self.assertIn('real-flush', observation.events)
                    self.assert_boundary_observed(observation, publication=0)
                self.assertFalse(destination.exists())

    def test_qfile_open_failure_closes_owned_device_and_removes_temp(self):
        for kind in ('png', 'pdf'):
            with self.subTest(format=kind):
                destination = self.folder / ('open-failure.' + kind)
                with QtLifetimeObservation(self, fault='open') as observation:
                    with self.assertRaisesRegex(ValueError, '파일 열기 실패'):
                        self.export(kind, destination)
                    self.assertEqual(observation.writers, [])
                    self.assert_boundary_observed(observation, publication=0)
                self.assertFalse(destination.exists())

    def test_cancellation_after_actual_image_encoding_closes_before_cleanup(self):
        destination = self.folder / 'cancelled.png'
        with QtLifetimeObservation(self) as observation:
            with self.assertRaises(media.Cancelled):
                self.export('png', destination, cancel=lambda: observation.wrote)
            self.assertTrue(observation.wrote)
            self.assert_boundary_observed(observation, publication=0)
        self.assertFalse(destination.exists())

    def test_cancellation_during_active_pdf_painting_closes_before_cleanup(self):
        destination = self.folder / 'cancelled.pdf'
        requested = False
        def progress(value):
            nonlocal requested
            self.assertEqual(value, .5)
            requested = True
        with QtLifetimeObservation(self) as observation:
            with self.assertRaises(media.Cancelled):
                self.export('pdf', destination, cancel=lambda: requested, progress=progress)
            self.assertTrue(requested)
            self.assert_boundary_observed(observation, publication=0)
        self.assertFalse(destination.exists())

    def test_second_pdf_render_failure_ends_painting_and_closes(self):
        destination = self.folder / 'paint-failure.pdf'
        real_render = media.render
        calls = 0
        def render(image, state):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError('injected second-page render failure')
            return real_render(image, state)
        with QtLifetimeObservation(self) as observation, patch.object(media, 'render', render):
            with self.assertRaisesRegex(OSError, 'second-page render failure'):
                self.export('pdf', destination)
            self.assertEqual(calls, 2)
            self.assert_boundary_observed(observation, publication=0)
        self.assertFalse(destination.exists())

    def test_post_write_validation_failure_never_publishes_closed_temp(self):
        for kind in ('png', 'pdf'):
            with self.subTest(format=kind):
                destination = self.folder / ('validation-failure.' + kind)
                with QtLifetimeObservation(self, fault='validation') as observation:
                    with self.assertRaisesRegex(OSError, 'post-write validation failure'):
                        self.export(kind, destination)
                    self.assertEqual(observation.validations, 2)
                    self.assert_boundary_observed(observation, publication=0)
                self.assertFalse(destination.exists())

    def test_late_publication_collision_preserves_rival_and_cleans_closed_temp(self):
        for kind in ('png', 'pdf'):
            with self.subTest(format=kind):
                destination = self.folder / ('rival.' + kind)
                with QtLifetimeObservation(self, fault='collision') as observation:
                    with self.assertRaises(FileExistsError):
                        self.export(kind, destination)
                    self.assert_boundary_observed(observation, publication=1)
                self.assertEqual(destination.read_bytes(), b'rival output: must survive')

    def test_publication_exception_cleans_closed_temp_without_output(self):
        for kind in ('png', 'pdf'):
            with self.subTest(format=kind):
                destination = self.folder / ('publish-failure.' + kind)
                with QtLifetimeObservation(self, fault='publish') as observation:
                    with self.assertRaisesRegex(OSError, 'injected publication failure'):
                        self.export(kind, destination)
                    self.assert_boundary_observed(observation, publication=1)
                self.assertFalse(destination.exists())

    def assert_retained_owned_temp(self, observation, primary, destination, required_notes):
        """Inspect an injected unlink failure, then clean only its owned file.

        Cleanup is outside the injected Path.unlink patch. An actual Windows
        native unlink failure remains the host's result, never emulated here.
        """
        self.assertFalse(destination.exists())
        self.assert_boundary_observed(observation, publication=0)
        notes = '\n'.join(getattr(primary, '__notes__', ()))
        for note in required_notes:
            self.assertIn(note, notes)
        names = [Path(device.fileName()) for device in observation.devices]
        self.assertEqual(len(names), 1)
        owned = names[0]
        self.assertEqual(owned.parent, self.folder)
        self.assertTrue(owned.name.startswith('.bluraction-'))
        self.assertTrue(owned.is_file())
        self.assertGreater(owned.stat().st_size, 0)
        return owned

    def test_write_primary_survives_actual_close_then_cleanup_and_unlink_errors(self):
        destination = self.folder / 'double-write.png'
        observed_primary = []
        real_write = media._write_qt_image_candidate
        def write(*args):
            try:
                return real_write(*args)
            except ValueError as error:
                # Observe the product's actual write-false error after its
                # finally. Raising inside a Python writer override would keep
                # that writer's self alive in the test-created traceback.
                observed_primary.append(error)
                raise
        owned = None
        try:
            with QtLifetimeObservation(self, fault='write', cleanup_faults=('close', 'unlink')) as observation, \
                    patch.object(media, '_write_qt_image_candidate', write):
                with self.assertRaisesRegex(ValueError, '이미지 저장 실패') as caught:
                    self.export('png', destination)
                self.assertEqual(len(observed_primary), 1)
                self.assertIs(caught.exception, observed_primary[0])
                owned = self.assert_retained_owned_temp(observation, caught.exception, destination,
                    ('이미지 저장 장치 닫기 실패', '이미지 임시 파일 정리 실패'))
            self.assertFalse(QImage(str(owned)).isNull())
        finally:
            if owned is not None:
                owned.unlink()

    def test_render_primary_survives_actual_painter_end_close_and_unlink_errors(self):
        destination = self.folder / 'double-render.pdf'
        primary = RuntimeError('primary second-page render exception')
        real_render = media.render
        calls = 0
        def render(image, state):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise primary
            return real_render(image, state)
        owned = None
        try:
            with QtLifetimeObservation(self, cleanup_faults=('painter-end', 'close', 'unlink')) as observation, \
                    patch.object(media, 'render', render):
                with self.assertRaises(RuntimeError) as caught:
                    self.export('pdf', destination)
                self.assertIs(caught.exception, primary)
                self.assertEqual(calls, 2)
                self.assertIn('real-painter-end', observation.events)
                owned = self.assert_retained_owned_temp(observation, primary, destination,
                    ('PDF 그리기 장치 마무리 실패', 'PDF 저장 장치 닫기 실패', 'PDF 임시 파일 정리 실패'))
        finally:
            if owned is not None:
                owned.unlink()

    def test_cancel_primary_identity_survives_close_and_unlink_errors(self):
        destination = self.folder / 'double-cancel.pdf'
        requested = False
        observed_primary = []
        real_check = media.check_cancel
        def check(cancel):
            try:
                return real_check(cancel)
            except media.Cancelled as error:
                observed_primary.append(error)
                raise
        def progress(value):
            nonlocal requested
            self.assertEqual(value, .5)
            requested = True
        owned = None
        try:
            with QtLifetimeObservation(self, cleanup_faults=('close', 'unlink')) as observation, \
                    patch.object(media, 'check_cancel', check):
                with self.assertRaises(media.Cancelled) as caught:
                    self.export('pdf', destination, cancel=lambda: requested, progress=progress)
                self.assertEqual(len(observed_primary), 1)
                self.assertIs(caught.exception, observed_primary[0])
                owned = self.assert_retained_owned_temp(observation, caught.exception, destination,
                    ('PDF 저장 장치 닫기 실패', 'PDF 임시 파일 정리 실패'))
        finally:
            if owned is not None:
                owned.unlink()


if __name__ == '__main__':
    unittest.main()
