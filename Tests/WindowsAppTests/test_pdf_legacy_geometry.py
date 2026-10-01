"""Mac-compatible numeric policy + optional actual pypdf/Qt metadata tests.

No backend test is silently substituted with fake parsed geometry. Missing
pypdf 6.19.0 or Qt reports an explicit unittest skip; that is not native Windows
or PDF backend approval. All files generated below are temporary fixtures.
"""
import importlib.util
import math
import os
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from platforms.windows.bluraction import pdf_geometry as geometry


def common_fixtures():
    # Same raw boxes/rotation matrix as the Mac PDFGeometryProbe's 12 pages.
    definitions = [('zero', (0, 0, 100, 160), (0, 0, 100, 160)),
                   ('inset', (0, 0, 120, 180), (10, 20, 110, 160)),
                   ('nonzero', (30, 40, 150, 220), (40, 60, 140, 200))]
    for label, media, crop in definitions:
        for rotation in (0, 90, 180, 270):
            width, height = crop[2] - crop[0], crop[3] - crop[1]
            size = (height, width) if rotation in (90, 270) else (width, height)
            review = label != 'zero' or rotation in (90, 270)
            yield label + '-r' + str(rotation), media, crop, rotation, size, review


class NumericGeometryTests(unittest.TestCase):
    def test_twelve_common_cases_match_mac_policy(self):
        fixtures = list(common_fixtures())
        self.assertEqual(len(fixtures), 12)
        for label, media, crop, rotation, size, review in fixtures:
            with self.subTest(label=label):
                result = geometry.analyze_geometry(media, crop, rotation, 1, size)
                self.assertEqual(result.legacy_edits_need_review, review)
                self.assertEqual(result.displayed_point_size, size)

    def test_zero_origin_square_rotations_and_180_are_safe(self):
        for rotation in (0, 90, 180, 270, -90, 360):
            result = geometry.analyze_geometry((0, 0, 100, 100), (0, 0, 100, 100), rotation, 1, (100, 100))
            self.assertFalse(result.legacy_edits_need_review)

    def test_origin_epsilon_does_not_hide_real_crop_shift(self):
        for origin, expected in [(0.0000005, False), (0.000002, True)]:
            result = geometry.analyze_geometry((0, 0, 110, 160), (origin, 0, 100 + origin, 160), 0, 1, (100, 160))
            self.assertEqual(result.legacy_edits_need_review, expected)

    def test_ambiguous_or_invalid_geometry_is_never_approved(self):
        valid = ((0, 0, 100, 160), (0, 0, 100, 160), 0, 1, (100, 160))
        changes = [(0, (0, 0, math.inf, 160)), (1, (0, 0, 100, 160, 2)),
                   (1, (0, 0, 0, 160)), (1, (-1, 0, 100, 160)),
                   (1, (0, 0, 101, 160)), (2, 45), (2, 90.0), (2, True),
                   (3, 0), (3, 2), (3, math.nan), (4, (160, 100)),
                   (4, (0, 160)), (4, (True, 160)), (4, None)]
        for index, changed in changes:
            values = list(valid); values[index] = changed
            with self.subTest(index=index, value=changed):
                with self.assertRaises(geometry.PDFGeometryError):
                    geometry.analyze_geometry(*values)

    def test_qt_rounding_tolerance_is_separate_from_mac_review_epsilon(self):
        result = geometry.analyze_geometry((0, 0, 100, 160), (0, 0, 100, 160), 0, 1, (100.00001, 160.00001))
        self.assertFalse(result.legacy_edits_need_review)
        with self.assertRaises(geometry.PDFGeometryError):
            geometry.analyze_geometry((0, 0, 100, 160), (0, 0, 100, 160), 0, 1, (100.1, 160))

    def test_missing_dependency_is_explicit_not_a_qt_guess(self):
        with patch.object(geometry.importlib, 'import_module', side_effect=ImportError('controlled missing backend')):
            with self.assertRaisesRegex(geometry.PDFGeometryDependencyError, 'pypdf 6.19.0'):
                geometry._backend()


class ActualPDFMetadataTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if importlib.util.find_spec('pypdf') is None:
            raise unittest.SkipTest('Actual PDF metadata proof unavailable: pypdf 6.19.0 installation awaits approval')
        import pypdf
        if pypdf.__version__ != '6.19.0':
            raise unittest.SkipTest('Actual PDF metadata proof requires reviewed pypdf 6.19.0')
        if importlib.util.find_spec('PySide6') is None:
            raise unittest.SkipTest('Actual Qt PDF display-size proof unavailable: PySide6 missing')
        from PySide6.QtGui import QGuiApplication
        cls.app = QGuiApplication.instance() or QGuiApplication([])
        cls.pypdf = pypdf

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.folder = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def write_fixture(self, name='matrix.pdf', mutate=None, encrypt=False):
        from pypdf.generic import FloatObject, NameObject, NumberObject, RectangleObject
        writer = self.pypdf.PdfWriter()
        for _, media, crop, rotation, _, _ in common_fixtures():
            page = writer.add_blank_page(width=media[2] - media[0], height=media[3] - media[1])
            page[NameObject('/MediaBox')] = RectangleObject(media)
            page[NameObject('/CropBox')] = RectangleObject(crop)
            page[NameObject('/Rotate')] = NumberObject(rotation)
            page[NameObject('/UserUnit')] = FloatObject(1)
        if mutate:
            mutate(writer)
        if encrypt:
            writer.encrypt('controlled-fixture-password')
        path = self.folder / name
        with path.open('wb') as stream:
            writer.write(stream)
        writer.close()
        return path

    def qt_sizes(self, path):
        from PySide6.QtPdf import QPdfDocument
        document = QPdfDocument()
        self.assertEqual(document.load(str(path)), QPdfDocument.Error.None_)
        try:
            return [(document.pagePointSize(index).width(), document.pagePointSize(index).height())
                    for index in range(document.pageCount())]
        finally:
            document.close()

    def test_actual_backend_twelve_common_raw_cases_crosscheck_qt(self):
        from platforms.windows.bluraction import media
        path = self.write_fixture()
        identity = media._capture_identity(path)
        digest = media.fingerprint(path)
        result = geometry.inspect_pdf_geometry(path, self.qt_sizes(path), expected_identity=identity, expected_sha256=digest)
        self.assertEqual(len(result), 12)
        for actual, (_, raw_media, raw_crop, rotation, size, review) in zip(result, common_fixtures()):
            self.assertEqual(actual.media_box, raw_media)
            self.assertEqual(actual.crop_box, raw_crop)
            self.assertEqual(actual.rotation, rotation)
            self.assertEqual(actual.displayed_point_size, size)
            self.assertEqual(actual.legacy_edits_need_review, review)
        self.assertEqual(media._capture_identity(path), identity)
        self.assertEqual(media.fingerprint(path), digest)

    def test_actual_backend_inherited_boxes_and_rotate(self):
        from pypdf.generic import NameObject, NumberObject, RectangleObject
        def inherited(writer):
            for page in writer.pages:
                for key in ('/MediaBox', '/CropBox', '/Rotate'):
                    del page[NameObject(key)]
            root = writer.root_object['/Pages']
            root[NameObject('/MediaBox')] = RectangleObject((0, 0, 100, 160))
            root[NameObject('/CropBox')] = RectangleObject((0, 0, 100, 160))
            root[NameObject('/Rotate')] = NumberObject(180)
        path = self.write_fixture(mutate=inherited)
        result = geometry.inspect_pdf_geometry(path, self.qt_sizes(path))
        self.assertTrue(all(page.rotation == 180 and not page.legacy_edits_need_review for page in result))

    def test_actual_encrypted_pdf_refused_without_decrypting(self):
        path = self.write_fixture(encrypt=True)
        with self.assertRaises(geometry.PDFGeometryError):
            geometry.inspect_pdf_geometry(path, [(100, 160)] * 12)

    def test_actual_userunit_and_bad_page_count_fail_closed(self):
        from pypdf.generic import FloatObject, NameObject, NumberObject
        path = self.write_fixture(name='unit.pdf', mutate=lambda writer: writer.pages[0].__setitem__(NameObject('/UserUnit'), FloatObject(2)))
        with self.assertRaises(geometry.PDFGeometryError):
            geometry.inspect_pdf_geometry(path, [(100, 160)] * 12)
        path = self.write_fixture(name='count.pdf', mutate=lambda writer: writer.root_object['/Pages'].__setitem__(NameObject('/Count'), NumberObject(201)))
        with self.assertRaises(geometry.PDFGeometryError):
            geometry.inspect_pdf_geometry(path, [(100, 160)] * 12)

    def test_source_change_after_raw_decode_is_rejected(self):
        path = self.write_fixture()
        qt_sizes = self.qt_sizes(path)
        original = geometry.analyze_geometry
        changed = False
        def replace(*args):
            nonlocal changed
            result = original(*args)
            if not changed:
                path.write_bytes(path.read_bytes() + b'\n% controlled mutation\n')
                changed = True
            return result
        with patch.object(geometry, 'analyze_geometry', replace):
            with self.assertRaises(ValueError):
                geometry.inspect_pdf_geometry(path, qt_sizes)

    def test_invalid_bytes_page_size_mismatch_and_cancel_are_refused(self):
        from platforms.windows.bluraction import media
        invalid = self.folder / 'invalid.pdf'; invalid.write_bytes(b'not a PDF')
        with self.assertRaises(geometry.PDFGeometryError):
            geometry.inspect_pdf_geometry(invalid, [(100, 160)])
        valid = self.write_fixture()
        with self.assertRaises(geometry.PDFGeometryError):
            geometry.inspect_pdf_geometry(valid, [(160, 100)] * 12)
        with self.assertRaises(media.Cancelled):
            geometry.inspect_pdf_geometry(valid, self.qt_sizes(valid), cancel=lambda: True)

    def test_oversized_input_and_old_identity_are_rejected_before_metadata_open(self):
        from platforms.windows.bluraction import media
        large = self.folder / 'oversized.pdf'
        with large.open('wb') as stream:
            stream.truncate(geometry.MAX_PDF_BYTES + 1)
        with patch.object(geometry.os, 'open', side_effect=AssertionError('oversized PDF opened')):
            with self.assertRaises(geometry.PDFGeometryError):
                geometry.inspect_pdf_geometry(large, [(100, 160)])
        path = self.write_fixture()
        baseline = media._capture_identity(path)
        path.write_bytes(path.read_bytes() + b'\n% baseline changed\n')
        with patch.object(geometry.os, 'open', side_effect=AssertionError('changed baseline PDF opened')):
            with self.assertRaises(geometry.PDFGeometryError):
                geometry.inspect_pdf_geometry(path, [(100, 160)] * 12, expected_identity=baseline)


if __name__ == '__main__':
    unittest.main()
