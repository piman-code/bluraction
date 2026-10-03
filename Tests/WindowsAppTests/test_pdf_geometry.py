"""Public twelve-case Qt/PDFium geometry integration; no Windows OS claim.

Generate the controlled assets with GeneratePDFGeometry.swift before running.
Missing generation is an error, not a skipped successful proof. The parent
serializes generation/testing; this file installs no runtime or dependency.
"""
import os
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
from copy import deepcopy
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import tempfile
import unittest

from PySide6.QtWidgets import QApplication

from platforms.windows.bluraction.editor import Workspace
from platforms.windows.bluraction.media import export_pdf, load_pages
from platforms.windows.bluraction.renderer import render
from shared.portable_project import PortableProject

APP = QApplication.instance() or QApplication([])
ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(os.environ.get('BLURACTION_PDF_GEOMETRY_DIR',
                              ROOT / 'shared' / 'fixtures' / 'pdf-geometry' / 'generated')).absolute()
FAMILIES = {
    'zero': ([0, 0, 100, 160], [0, 0, 100, 160]),
    'inset': ([0, 0, 120, 180], [10, 20, 100, 140]),
    'nonzero': ([30, 40, 120, 180], [40, 60, 100, 140]),
}


class PDFGeometryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        manifest_path = FIXTURES / 'manifest.json'
        if not manifest_path.is_file():
            raise AssertionError(f'Generate the twelve public PDF fixtures first; missing {manifest_path}')
        if manifest_path.stat().st_size > 128 * 1024:
            raise AssertionError('Synthetic geometry manifest exceeds its bounded fixture size')
        cls.manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
        if cls.manifest.get('schemaVersion') != 1 or cls.manifest.get('renderDpi') != 144:
            raise AssertionError('Unexpected public PDF geometry manifest contract')
        cls.cases = cls.manifest['cases']
        expected = {f'{family}-r{rotation}' for family in FAMILIES for rotation in (0, 90, 180, 270)}
        if len(cls.cases) != 12 or {case['id'] for case in cls.cases} != expected:
            raise AssertionError('Geometry fixtures must contain exactly the twelve Mac regression cases')
        for case in cls.cases:
            if case['file'] != case['id'] + '.pdf':
                raise AssertionError('Synthetic fixture names must not escape their generated directory')
        template_path = ROOT / 'shared' / 'fixtures' / 'swift-v2-rich.bluraction'
        cls.swift_template = json.loads(template_path.read_text(encoding='utf-8'))

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.output = Path(self.temp.name)
        self.sources = {}
        for case in self.cases:
            source = FIXTURES / case['file']
            self.assertFalse(source.is_symlink(), 'Only generated regular synthetic PDFs are test inputs')
            self.assertLess(source.stat().st_size, 512 * 1024, 'Synthetic PDFs must remain small')
            self.sources[source] = source.read_bytes()
            self.assertEqual(hashlib.sha256(self.sources[source]).hexdigest(), case['sourceSHA256'])

    def tearDown(self):
        try:
            for source, before in self.sources.items():
                self.assertEqual(source.read_bytes(), before, 'Synthetic source bytes must not change')
        finally:
            self.temp.cleanup()

    @staticmethod
    def expected_display(point, crop, rotation):
        x, y = point
        width, height = crop[2:]
        if rotation == 90:
            return [y, width - x]
        if rotation == 180:
            return [width - x, height - y]
        if rotation == 270:
            return [height - y, x]
        return [x, y]

    def assert_manifest_case(self, case):
        family = case['id'].split('-r')[0]
        media, crop = FAMILIES[family]
        self.assertEqual(case['mediaBox'], media)
        self.assertEqual(case['cropBox'], crop)
        rotation = int(case['id'].split('-r')[1])
        self.assertEqual(case['rotation'], rotation)
        size = crop[2:] if rotation % 180 == 0 else crop[2:][::-1]
        self.assertEqual(case['displayPointSize'], size)
        self.assertEqual(case['expectedPixelSize144dpi'], [value * 2 for value in size])
        self.assertEqual([item['rgb'] for item in case['corners']],
                         [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0]])
        self.assertEqual(len(case['corners']), 4)
        self.assertEqual(len(case['borders']), 4)
        width, height = crop[2:]
        self.assertEqual([item['cropPoint'] for item in case['corners']],
                         [[8, 8], [width - 8, 8], [8, height - 8], [width - 8, height - 8]])
        self.assertEqual(case['annotation']['cropPoint'], [width / 2, height / 2])
        self.assertEqual(case['annotation']['rgb'], [255, 0, 255])
        self.assertEqual([item['cropPoint'] for item in case['borders']],
                         [[width / 2, 1], [width / 2, height - 1], [1, height / 2], [width - 1, height / 2]])
        self.assertTrue(all(item['rgb'] == [90, 90, 90] for item in case['borders']))
        for marker in [*case['corners'], *case['borders'], case['annotation']]:
            self.assertEqual(marker['displayPoint'], self.expected_display(marker['cropPoint'], crop, rotation))
        mac_review = crop[0] != 0 or crop[1] != 0 or crop[2:] != size
        self.assertEqual(case['macLegacyEditedRequiresReview'], mac_review)
        self.assertIs(case['portableCurrentLegacyEditedRequiresReview'], True)

    def assert_geometry(self, page, image, case):
        self.assert_manifest_case(case)
        width, height = case['displayPointSize']
        self.assertAlmostEqual(page.point_size[0], width, delta=.01)
        self.assertAlmostEqual(page.point_size[1], height, delta=.01)
        self.assertEqual((image.width(), image.height()), tuple(case['expectedPixelSize144dpi']))
        self.assertAlmostEqual(image.width() / image.height(), width / height, places=7)

    def assert_rgb(self, image, point, size, expected, tolerance=4):
        # Product/project points are bottom-left; QImage scanlines are top-left.
        x = min(image.width() - 1, max(0, math.floor(point[0] / size[0] * image.width())))
        y = image.height() - 1 - min(image.height() - 1, max(0, math.floor(point[1] / size[1] * image.height())))
        color = image.pixelColor(x, y)
        actual = [color.red(), color.green(), color.blue()]
        self.assertTrue(all(abs(value - target) <= tolerance for value, target in zip(actual, expected)),
                        f'point={point}, image pixel={(x, y)}, expected={expected}, actual={actual}')
        self.assertGreaterEqual(color.alpha(), 250)

    def assert_original_markers(self, image, case):
        size = case['displayPointSize']
        for marker in case['corners'] + [case['annotation']]:
            self.assert_rgb(image, marker['displayPoint'], size, marker['rgb'])
        for border in case['borders']:
            self.assert_rgb(image, border['displayPoint'], size, border['rgb'], tolerance=14)

    def apply_corner_covers(self, workspace, case):
        width, height = case['displayPointSize']
        for marker in case['corners']:
            x, y = marker['displayPoint']
            workspace.add_cover('rectangle', [[(x - 8) / width, (y - 8) / height],
                                               [(x + 8) / width, (y + 8) / height]],
                                style='solid', feather=0)
        workspace.add_drawing('rectangle', [[.7, .65], [.8, .75]],
                              color={'red': 0, 'green': 1, 'blue': 1, 'alpha': 1}, width=.002, fill=1)

    def assert_edited_markers(self, image, case, tolerance=4):
        size = case['displayPointSize']
        for marker in case['corners']:
            point = marker['displayPoint']
            self.assert_rgb(image, point, size, [0, 0, 0], tolerance)
            # A white point just beyond the cover toward the page center must
            # remain uncovered; a shifted/oversized black mask cannot pass.
            outside = [point[0] + (20 if point[0] < size[0] / 2 else -20), point[1]]
            self.assert_rgb(image, outside, size, [255, 255, 255], tolerance)
        for border in case['borders']:
            self.assert_rgb(image, border['displayPoint'], size, border['rgb'], tolerance=max(14, tolerance))
        annotation = case['annotation']
        self.assert_rgb(image, annotation['displayPoint'], size, annotation['rgb'], tolerance)
        self.assert_rgb(image, [size[0] * .75, size[1] * .7], size, [0, 255, 255], tolerance)

    def test_all_twelve_geometry_corner_covers_project_roundtrip_and_flattened_pdf(self):
        workspace = Workspace()
        # Workspace.load calls actual media.load_pages, never a mock decoder.
        workspace.load([FIXTURES / case['file'] for case in self.cases])
        self.assertEqual(len(workspace.pages), 12)
        for index, case in enumerate(self.cases):
            with self.subTest(stage='source-preview', case=case['id']):
                workspace.set_page(index)
                image = workspace.page.image
                self.assert_geometry(workspace.page, image, case)
                self.assert_original_markers(image, case)
                self.apply_corner_covers(workspace, case)
                self.assert_edited_markers(render(image, workspace.page.state), case)

        project_path = self.output / 'twelve-fixed-pages.bluraction'
        workspace.save_project(project_path)
        project_before = project_path.read_bytes()
        saved = json.loads(project_before)
        self.assertTrue(all(entry['pdfGeometryVersion'] == 1 for entry in saved['pages']))
        restored = Workspace()
        restored.load_project(project_path)
        self.assertEqual(restored.index, workspace.index)
        self.assertEqual([page.state for page in restored.pages], [page.state for page in workspace.pages])
        destination = self.output / 'twelve-covered-pages.pdf'
        export_pdf(restored.pages, destination)
        reopened = load_pages([destination])
        self.assertEqual(len(reopened), 12)
        for page, case in zip(reopened, self.cases):
            with self.subTest(stage='exported-pdf', case=case['id']):
                image = page.image
                self.assert_geometry(page, image, case)
                self.assert_edited_markers(image, case, tolerance=12)
        self.assertEqual(project_path.read_bytes(), project_before)

    def project_tree(self, case, geometry=1, empty=False):
        # Reuse the genuine Mac Codable fixture. Only media references/geometry
        # markers are changed; rich edit representations are not invented here.
        tree = deepcopy(self.swift_template)
        entry = deepcopy(tree['pages'][1])
        entry.update(mediaPath=str(FIXTURES / case['file']), pdfPageIndex=0, sourceSHA256=case['sourceSHA256'])
        if geometry is None:
            entry.pop('pdfGeometryVersion', None)
        else:
            entry['pdfGeometryVersion'] = geometry
        if empty:
            entry['regions'], entry['drawings'] = [], []
        tree.update(currentIndex=0, pages=[entry])
        return tree

    def write_project(self, name, tree):
        path = self.output / name
        with path.open('xb') as out:
            out.write(json.dumps(tree, ensure_ascii=False, allow_nan=False).encode('utf-8'))
        return path

    def test_legacy_edited_pdf_raw_policy_or_missing_backend_preserves_existing_workspace(self):
        workspace = Workspace()
        workspace.load([FIXTURES / self.cases[0]['file']])
        workspace.add_cover('rectangle', [[.3, .3], [.4, .4]], style='solid', feather=0)
        old_pages, old_state, old_dirty = workspace.pages, deepcopy(workspace.page.state), workspace.dirty
        allowed_on_mac = []
        raw_backend = False
        if importlib.util.find_spec('pypdf') is not None:
            import pypdf
            raw_backend = pypdf.__version__ == '6.19.0'
        for case in self.cases:
            self.assert_manifest_case(case)
            if not case['macLegacyEditedRequiresReview']:
                allowed_on_mac.append(case['id'])
            for drawing_only in (False, True):
                with self.subTest(case=case['id'], drawing_only=drawing_only):
                    tree = self.project_tree(case, geometry=None)
                    if drawing_only:
                        tree['pages'][0]['regions'] = []
                    project = PortableProject(tree)
                    self.assertTrue(any('legacy edited PDF' in reason for reason in project.required_reviews))
                    path = self.write_project(f"{case['id']}-legacy-{drawing_only}.bluraction", tree)
                    before = path.read_bytes()
                    if raw_backend and not case['macLegacyEditedRequiresReview']:
                        restored = Workspace()
                        self.assertEqual(restored.load_project(path), [])
                        self.assertEqual(restored.page.state,
                                         {key: tree['pages'][0][key] for key in ('regions', 'drawings')})
                        self.assert_geometry(restored.page, restored.page.image, case)
                    else:
                        with self.assertRaisesRegex(ValueError, '호환 검토'):
                            workspace.load_project(path)
                        self.assertIs(workspace.pages, old_pages)
                        self.assertEqual(workspace.page.state, old_state)
                        self.assertEqual(workspace.dirty, old_dirty)
                    self.assertEqual(path.read_bytes(), before)
        self.assertEqual(set(allowed_on_mac), {'zero-r0', 'zero-r180'},
                         'Raw backend must permit the same two safe Mac legacy cases; missing backend blocks explicitly')

    def test_empty_legacy_and_fixed_marked_edited_projects_open_all_twelve_cases(self):
        for case in self.cases:
            for geometry, empty in ((None, True), (1, False)):
                with self.subTest(case=case['id'], geometry=geometry, empty=empty):
                    tree = self.project_tree(case, geometry, empty)
                    self.assertEqual(PortableProject(tree).required_reviews, ())
                    path = self.write_project(f"{case['id']}-accepted-{geometry}.bluraction", tree)
                    before = path.read_bytes()
                    workspace = Workspace()
                    self.assertEqual(workspace.load_project(path), [])
                    self.assertEqual(workspace.page.state,
                                     {'regions': tree['pages'][0]['regions'], 'drawings': tree['pages'][0]['drawings']})
                    self.assert_geometry(workspace.page, workspace.page.image, case)
                    resaved = self.output / (path.stem + '-resaved.bluraction')
                    workspace.save_project(resaved)
                    self.assertEqual(json.loads(resaved.read_bytes())['pages'][0]['pdfGeometryVersion'], 1)
                    again = Workspace()
                    again.load_project(resaved)
                    self.assertEqual(again.page.state, workspace.page.state)
                    self.assertEqual(path.read_bytes(), before)

    def test_unknown_pdf_geometry_version_rejects_before_workspace_replacement(self):
        workspace = Workspace()
        workspace.load([FIXTURES / self.cases[0]['file']])
        previous = workspace.pages
        for case in self.cases:
            with self.subTest(case=case['id']):
                path = self.write_project(case['id'] + '-unknown.bluraction', self.project_tree(case, geometry=2))
                before = path.read_bytes()
                with self.assertRaisesRegex(ValueError, 'pdfGeometryVersion'):
                    workspace.load_project(path)
                self.assertIs(workspace.pages, previous)
                self.assertEqual(path.read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
