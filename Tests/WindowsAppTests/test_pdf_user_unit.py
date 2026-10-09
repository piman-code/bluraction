"""Actual PDF unit, crop, rotation, export and project regression checks."""
import os
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
from pathlib import Path
import tempfile
import unittest

from PySide6.QtWidgets import QApplication
from pypdf import PdfReader, PdfWriter
from pypdf.generic import (DecodedStreamObject, FloatObject, NameObject,
                           RectangleObject)

from platforms.windows.bluraction.editor import Workspace
from platforms.windows.bluraction.media import export_image, export_pdf, load_pages
from platforms.windows.bluraction.pdf_geometry import PDFGeometryError, inspect_pdf_geometry

APP = QApplication.instance() or QApplication([])


class PDFUserUnitTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def fixture(self, name, units, *, crop=False, rotation=0, parent_unit=None):
        writer = PdfWriter()
        for unit in units:
            page = writer.add_blank_page(300, 200)
            if crop:
                page.cropbox = RectangleObject([50, 30, 250, 150])
            page.rotate(rotation)
            if unit is not None:
                page[NameObject('/UserUnit')] = FloatObject(unit)
            content = DecodedStreamObject()
            content.set_data(b'1 1 1 rg 0 0 300 200 re f')
            page[NameObject('/Contents')] = writer._add_object(content)
        if parent_unit is not None:
            writer.pages[0]['/Parent'][NameObject('/UserUnit')] = FloatObject(parent_unit)
        path = self.root / name
        with path.open('wb') as stream:
            writer.write(stream)
        return path

    def test_physical_sizes_and_cover_pixels_survive_crop_rotation_and_export(self):
        for crop in (False, True):
            for rotation in (0, 90, 180, 270):
                for unit in (.5, 1, 2):
                    with self.subTest(crop=crop, rotation=rotation, unit=unit):
                        stem = f'{crop}-{rotation}-{unit}'
                        source = self.fixture(stem + '.pdf', [unit], crop=crop, rotation=rotation)
                        before = source.read_bytes()
                        expected = [200 if crop else 300, 120 if crop else 200]
                        if rotation in (90, 270):
                            expected.reverse()
                        expected = tuple(value * unit for value in expected)
                        workspace = Workspace()
                        workspace.load([source])
                        page = workspace.pages[0]
                        self.assertEqual(page.point_size, expected)
                        self.assertEqual((page.image.width(), page.image.height()),
                                         tuple(round(value * 2) for value in expected))
                        workspace.add_cover('rectangle', [[.1, .1], [.3, .3]],
                                            style='solid', radius=0, feather=0)
                        image_path = self.root / (stem + '.png')
                        export_image(page, image_path)
                        from PySide6.QtGui import QImage
                        image = QImage(str(image_path))
                        pixel = image.pixelColor(round(image.width() * .2), round(image.height() * .8))
                        self.assertEqual((pixel.red(), pixel.green(), pixel.blue(), pixel.alpha()),
                                         (0, 0, 0, 255))
                        output = self.root / (stem + '-output.pdf')
                        export_pdf([page], output)
                        result = PdfReader(output).pages[0]
                        self.assertAlmostEqual(float(result.mediabox.width), expected[0], places=2)
                        self.assertAlmostEqual(float(result.mediabox.height), expected[1], places=2)
                        self.assertEqual(result.user_unit, 1)
                        project = self.root / (stem + '.bluraction')
                        workspace.save_project(project)
                        reopened = Workspace()
                        reopened.load_project(project)
                        self.assertEqual(reopened.pages[0].point_size, expected)
                        self.assertEqual(reopened.pages[0].state, page.state)
                        self.assertEqual(source.read_bytes(), before)

    def test_units_are_page_local_and_parent_unit_is_not_inherited(self):
        source = self.fixture('mixed.pdf', [2, None, .5], parent_unit=4)
        pages = load_pages([source])
        self.assertEqual([page.point_size for page in pages], [(600, 400), (300, 200), (150, 100)])

    def test_unpainted_pdf_paper_is_white_in_preview_exports_and_reopened_project(self):
        writer = PdfWriter()
        page = writer.add_blank_page(100, 100)
        content = DecodedStreamObject()
        # Ordinary PDF producers do not paint the paper. Keep black ink and
        # a colored element to catch both transparency and color regressions.
        content.set_data(b'0 0 0 rg 10 10 20 20 re f 0 0 1 rg 60 60 20 20 re f')
        page[NameObject('/Contents')] = writer._add_object(content)
        source = self.root / 'unpainted-paper.pdf'
        with source.open('wb') as stream:
            writer.write(stream)
        before = source.read_bytes()
        workspace = Workspace()
        workspace.load([source])
        from platforms.windows.bluraction.renderer import render
        from PySide6.QtCore import QSize
        from PySide6.QtGui import QImage
        from PySide6.QtPdf import QPdfDocument
        def pixels(image, color_tolerance=0):
            self.assertEqual(image.pixelColor(5, 5).getRgb(), (255, 255, 255, 255))
            self.assertEqual(image.pixelColor(40, 160).getRgb(), (0, 0, 0, 255))
            blue = image.pixelColor(140, 60).getRgb()
            self.assertEqual(blue[3], 255)
            for actual, expected in zip(blue[:3], (0, 0, 255)):
                self.assertLessEqual(abs(actual - expected), color_tolerance)
        pixels(workspace.page.image)
        pixels(render(workspace.page.image, workspace.page.state))
        project = self.root / 'paper.bluraction'
        workspace.save_project(project)
        reopened = Workspace()
        reopened.load_project(project)
        pixels(reopened.page.image)
        png = self.root / 'paper.png'
        export_image(reopened.page, png)
        pixels(QImage(str(png)))
        output = self.root / 'paper-output.pdf'
        export_pdf(reopened.pages, output)
        document = QPdfDocument()
        try:
            self.assertEqual(document.load(str(output)), QPdfDocument.Error.None_)
            # QPdfWriter's image compression can round a color byte by one.
            pixels(document.render(0, QSize(200, 200)), color_tolerance=2)
        finally:
            document.close()
        self.assertEqual(source.read_bytes(), before)

    def test_transparent_png_keeps_its_alpha(self):
        from PySide6.QtGui import QColor, QImage
        source = self.root / 'transparent.png'
        image = QImage(10, 10, QImage.Format.Format_ARGB32)
        image.fill(QColor(255, 0, 0, 64))
        self.assertTrue(image.save(str(source)))
        loaded = load_pages([source])[0].image
        self.assertEqual(loaded.pixelColor(5, 5).getRgb(), (255, 0, 0, 64))

    def test_scaled_legacy_geometry_still_requires_review(self):
        source = self.fixture('legacy.pdf', [2])
        with self.assertRaisesRegex(PDFGeometryError, 'UserUnit'):
            inspect_pdf_geometry(source, [(300, 200)])

    def test_invalid_or_oversized_physical_units_reject_before_render(self):
        for unit in (0, -1, .000001, 1000, 1_000_000):
            with self.subTest(unit=unit):
                source = self.fixture(f'invalid-{unit}.pdf', [unit])
                with self.assertRaises(ValueError):
                    load_pages([source])
