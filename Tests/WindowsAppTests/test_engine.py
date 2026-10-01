"""Synthetic engine checks. macOS execution is not Windows OS evidence."""
import os
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
from copy import deepcopy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace
import json

from PySide6.QtCore import QSize
from PySide6.QtGui import QColor, QColorSpace, QImage
from PySide6.QtWidgets import QApplication
from PySide6.QtPdf import QPdfDocument
from PIL import Image

from platforms.windows.bluraction.editor import Workspace, MissingSources, UnverifiedSources
from platforms.windows.bluraction.media import (Cancelled, export_image, export_pdf,
    load_pages, safe_stem, save_bytes_new, validate_sources, fresh_target)
from platforms.windows.bluraction.renderer import render, rect_at

APP = QApplication.instance() or QApplication([])


class EngineTests(unittest.TestCase):
    def test_mixed_selection_restyles_only_matching_schema_and_reopens(self):
        workspace = self.workspace
        workspace.add_cover('rectangle', [[.1, .1], [.4, .4]])
        region_id = workspace.selectionID
        workspace.add_drawing('rectangle', [[.2, .2], [.6, .6]], width=.0123456789, fill=.6)
        drawing_id = workspace.selectionID
        baseline = deepcopy(workspace.page.state)
        workspace.selection_ids = {region_id, drawing_id}
        workspace.update_selected(style='solid', blurRadius=400.123, featherRadius=0,
                                  color={'red': .2, 'green': .3, 'blue': .4, 'alpha': 1})
        self.assertEqual(workspace.page.state['drawings'], baseline['drawings'])
        self.assertEqual(workspace.page.state['regions'][0]['effect']['style'], 'solid')
        workspace.undo()
        self.assertEqual(workspace.page.state, baseline)
        workspace.redo()
        region = deepcopy(workspace.page.state['regions'][0])
        workspace.selection_ids = {region_id, drawing_id}
        workspace.update_selected(lineWidth=.25, fillOpacity=.75, red=.9, green=.8, blue=.7, alpha=.6)
        self.assertEqual(workspace.page.state['regions'][0], region)
        self.assertEqual(workspace.page.state['drawings'][0]['lineWidth'], .25)
        workspace.update_selected(name='혼합 선택', hidden=True)
        self.assertEqual(workspace.page.state['regions'][0]['effect']['name'], '혼합 선택')
        self.assertFalse(workspace.page.state['regions'][0]['effect']['enabled'])
        self.assertTrue(workspace.page.state['drawings'][0]['hidden'])
        destination = self.folder / 'mixed-selection.bluraction'
        workspace.save_project(destination)
        reopened = Workspace()
        reopened.load_project(destination)
        self.assertEqual(reopened.page.state, workspace.page.state)
        self.assertEqual(reopened.review_required, [])

    def test_maximum_length_names_duplicate_save_reopen_and_undo_losslessly(self):
        from platforms.windows.bluraction.project_compatibility import grapheme_count
        for name in ('A' * 200, '가' * 200, '👩‍👩‍👧‍👦' * 200):
            with self.subTest(name=name[:15]):
                workspace = Workspace()
                workspace.load([self.source])
                workspace.add_cover('rectangle', [[.1, .1], [.5, .5]], style='solid', feather=0)
                workspace.page.state['regions'][0]['effect']['name'] = name
                before = deepcopy(workspace.page.state)
                workspace.duplicate_selected()
                copied_item = workspace.page.state['regions'][-1]
                self.assertEqual(workspace.selection_ids, {workspace.item_id(copied_item, True)})
                copied = copied_item['effect']['name']
                self.assertEqual(grapheme_count(copied), 200)
                self.assertTrue(copied.endswith(' 사본'))
                self.assertEqual(workspace.page.state['regions'][0]['effect']['name'], name)
                destination = self.folder / f'copy-{len(list(self.folder.iterdir()))}.bluraction'
                workspace.save_project(destination)
                restored = Workspace()
                self.assertEqual(restored.load_project(destination), [])
                self.assertEqual(restored.page.state, workspace.page.state)
                workspace.undo()
                self.assertEqual(workspace.page.state, before)

    def test_every_output_writer_rejects_windows_device_and_stream_names(self):
        before = list(self.folder.iterdir())
        for name in ['CON.png', 'COM¹.jpg', 'LPT³.tiff', 'result.png:stream', 'result.pdf.', 'result.bluraction ']:
            with self.subTest(name=name), self.assertRaises(ValueError):
                save_bytes_new(self.folder / name, b'bytes')
        for name in [r'\\?\C:\result.pdf', r'\\.\NUL', r'\??\C:\result.png']:
            with self.assertRaises(ValueError):
                fresh_target(name)
        self.assertEqual(safe_stem('COM¹'), '_COM¹')
        self.assertEqual(safe_stem('LPT³'), '_LPT³')
        self.assertEqual(list(self.folder.iterdir()), before)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.folder = Path(self.temp.name)
        self.source = self.folder / '가나다 original.png'
        image = QImage(160, 100, QImage.Format.Format_RGBA8888)
        image.fill(QColor('white'))
        self.assertTrue(image.save(str(self.source)))
        self.original = self.source.read_bytes()
        self.workspace = Workspace()
        self.workspace.load([self.source])

    def tearDown(self):
        self.assertEqual(self.source.read_bytes(), self.original)
        self.temp.cleanup()

    def test_bottom_left_solid_cover_preview_and_png_same_pixels(self):
        self.workspace.add_cover('rectangle', [[0, 0], [.5, .5]], 'solid', 25, 0)
        preview = render(self.workspace.page.image, self.workspace.page.state)
        output = self.folder / 'output.png'
        export_image(self.workspace.page, output)
        result = QImage(str(output))
        self.assertEqual(preview.pixelColor(20, 80), QColor('black'))
        self.assertEqual(preview.pixelColor(20, 20), QColor('white'))
        preview_rgba = preview.convertToFormat(QImage.Format.Format_RGBA8888)
        result_rgba = result.convertToFormat(QImage.Format.Format_RGBA8888)
        self.assertEqual(bytes(preview_rgba.constBits()), bytes(result_rgba.constBits()))

    def test_alpha_annotation_is_composited_once(self):
        self.workspace.add_drawing('rectangle', [[.1, .1], [.9, .9]],
            {'red': 1, 'green': 0, 'blue': 0, 'alpha': .5}, .006, 1)
        result = render(self.workspace.page.image, self.workspace.page.state)
        pixel = result.pixelColor(80, 50)
        self.assertGreaterEqual(pixel.green(), 125)
        self.assertLessEqual(pixel.green(), 130)

    def test_still_eraser_ignores_time_and_video_uses_from(self):
        self.workspace.add_cover('rectangle', [[0, 0], [1, 1]], 'solid', 25, 0)
        self.workspace.erase([[.5, .5]], .3, time=5)
        state = self.workspace.page.state
        self.assertEqual(render(self.workspace.page.image, state).pixelColor(80, 50), QColor('white'))
        self.assertEqual(render(self.workspace.page.image, state, time=4).pixelColor(80, 50), QColor('black'))
        self.assertEqual(render(self.workspace.page.image, state, time=5).pixelColor(80, 50), QColor('white'))

    def test_copy_all_keeps_page_edits_and_history_independent(self):
        self.workspace.load([self.source, self.source, self.source])
        self.workspace.add_cover('ellipse', [[.1, .1], [.5, .5]])
        self.workspace.copy_all()
        one = deepcopy(self.workspace.pages[0].state)
        self.workspace.set_page(1)
        self.workspace.add_drawing('line', [[0, 0], [1, 1]])
        self.assertEqual(self.workspace.pages[0].state, one)
        self.assertEqual(self.workspace.pages[2].state, one)
        self.workspace.undo()
        self.assertEqual(self.workspace.pages[1].state, one)
        self.workspace.redo()
        self.assertEqual(len(self.workspace.page.state['drawings']), 1)

    def test_busy_open_and_edit_reject_without_state_change(self):
        old = self.workspace.page
        self.workspace.busy = True
        with self.assertRaises(ValueError):
            self.workspace.load([self.folder / 'missing.png'])
        with self.assertRaises(ValueError):
            self.workspace.add_cover('rectangle', [[0, 0], [1, 1]])
        self.assertIs(self.workspace.page, old)

    def test_pdf_flattened_roundtrip_count_geometry_and_pixels(self):
        self.workspace.add_cover('rectangle', [[0, 0], [.5, .5]], 'solid', 25, 0)
        destination = self.folder / 'flattened.pdf'
        export_pdf(self.workspace.pages, destination)
        pdf = QPdfDocument()
        self.assertEqual(pdf.load(str(destination)), QPdfDocument.Error.None_)
        self.assertEqual(pdf.pageCount(), 1)
        self.assertAlmostEqual(pdf.pagePointSize(0).width(), 80, delta=.5)
        image = pdf.render(0, QSize(160, 100))
        self.assertLess(image.pixelColor(20, 80).red(), 5)
        self.assertGreater(image.pixelColor(20, 20).red(), 250)

    def test_save_reopen_and_explicit_relink_verify_fingerprint(self):
        self.workspace.add_drawing('text', [[.1, .1], [.9, .9]], text='한글\nEnglish')
        project = self.folder / '작업.bluraction'
        self.workspace.save_project(project)
        reopened = Workspace()
        reopened.load_project(project)
        self.assertEqual(reopened.page.state, self.workspace.page.state)
        moved = self.folder / 'moved'
        moved.mkdir()
        location = moved / project.name
        location.write_bytes(project.read_bytes())
        with self.assertRaises(MissingSources):
            reopened.load_project(location)
        reopened.load_project(location, {self.source.name: self.source})
        self.assertEqual(reopened.page.state, self.workspace.page.state)
        wrong = moved / 'wrong.png'
        wrong.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, '지문'):
            reopened.load_project(location, {self.source.name: wrong})

    def test_collision_source_preservation_and_cancel_leave_no_output(self):
        with self.assertRaises(FileExistsError):
            export_image(self.workspace.page, self.source)
        destination = self.folder / 'cancel.pdf'
        with self.assertRaises(Cancelled):
            export_pdf(self.workspace.pages, destination, cancel=lambda: True)
        self.assertFalse(destination.exists())
        self.assertEqual(list(self.folder.glob('.bluraction-*')), [])
        existing = self.folder / 'existing.txt'
        existing.write_bytes(b'keep')
        with self.assertRaises(FileExistsError):
            save_bytes_new(existing, b'replace')
        self.assertEqual(existing.read_bytes(), b'keep')

    def test_changed_source_blocks_export_without_new_output(self):
        source = self.folder / 'other.png'
        source.write_bytes(self.original)
        pages = load_pages([source])
        source.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, '변경'):
            validate_sources(pages)
        with self.assertRaises(ValueError):
            export_pdf(pages, self.folder / 'never.pdf')
        self.assertFalse((self.folder / 'never.pdf').exists())

    def test_mixed_201_pages_reject_before_mutating_workspace(self):
        old = self.workspace.page
        with self.assertRaisesRegex(ValueError, '200'):
            self.workspace.load([self.source] * 201)
        self.assertIs(self.workspace.page, old)

    def test_interpolation_duplicate_time_last_wins_base_before_start(self):
        frames = [{'time': 1, 'rect': [[.1, .2], [.3, .4]]},
                  {'time': 1, 'rect': [[.2, .3], [.4, .5]]},
                  {'time': 3, 'rect': [[.4, .5], [.6, .7]]}]
        self.assertEqual(rect_at([0, 0, 1, 1], frames, .5), [0, 0, 1, 1])
        self.assertEqual(rect_at([0, 0, 1, 1], frames, 1), [.2, .3, .4, .5])
        for got, expected in zip(rect_at([0, 0, 1, 1], frames, 2), [.3, .4, .5, .6]):
            self.assertAlmostEqual(got, expected)

    def test_long_korean_name_preserves_suffix_and_windows_reserved_names(self):
        name = safe_stem('가나다' * 150, '_images')
        self.assertTrue(name.endswith('_images'))
        self.assertLessEqual(len(name.encode()), 240)
        self.assertEqual(safe_stem('CON'), '_CON')

    def test_group_movement_preserves_relative_offsets_and_one_undo(self):
        first = self.workspace.add_cover('rectangle', [[.1, .1], [.3, .3]])
        second = self.workspace.add_drawing('rectangle', [[.6, .6], [.8, .8]])
        self.workspace.selection_ids = {first, second}
        self.workspace.group_selected()
        before = deepcopy(self.workspace.page.state)
        self.workspace.selectionID = first
        self.workspace.move_selected(.1, .1)
        from platforms.windows.bluraction.renderer import bounds, shape_points
        region = self.workspace.page.state['regions'][0]
        drawing = self.workspace.page.state['drawings'][0]
        self.assertAlmostEqual(bounds(shape_points(region)[1])[0], .2)
        self.assertAlmostEqual(bounds(drawing['points'])[0], .7)
        self.workspace.undo()
        self.assertEqual(self.workspace.page.state, before)

    def test_decode_buffers_are_lazy_and_orientation_drives_pdf_geometry(self):
        pages = load_pages([self.source] * 200)
        self.assertTrue(all(page._image is None for page in pages))
        for orientation in range(1, 9):
            source = self.folder / f'orientation-{orientation}.jpg'
            image = Image.new('RGB', (20, 10), 'white')
            exif = Image.Exif()
            exif[274] = orientation
            image.save(source, exif=exif)
            page = load_pages([source])[0]
            expected = (10, 20) if orientation >= 5 else (20, 10)
            self.assertEqual((page.image.width(), page.image.height()), expected)
            self.assertEqual(page.point_size, (expected[0] / 2, expected[1] / 2))

    def test_partial_document_cancel_reports_only_completed_owned_outputs(self):
        from platforms.windows.bluraction.media import export_documents
        output = self.folder / 'partial.pdf'
        with self.assertRaises(Cancelled) as result:
            export_documents(self.workspace.pages, output, cancel=lambda: output.is_file())
        self.assertEqual(result.exception.completed_outputs, [output])
        self.assertTrue(output.is_file())
        self.assertFalse((self.folder / 'partial_images').exists())

    def test_embedded_color_profile_converts_once_to_declared_srgb(self):
        source = QImage(2, 2, QImage.Format.Format_RGBA8888)
        source.fill(QColor(120, 50, 30))
        source.setColorSpace(QColorSpace(QColorSpace.NamedColorSpace.DisplayP3))
        expected = source.convertedToColorSpace(QColorSpace(QColorSpace.NamedColorSpace.SRgb))
        rendered = render(source, {'regions': [], 'drawings': []})
        self.assertEqual(rendered.pixelColor(0, 0), expected.pixelColor(0, 0))
        self.assertEqual(rendered.colorSpace(), expected.colorSpace())

    def test_solid_zero_radius_and_zero_stored_alpha_remain_opaque(self):
        self.workspace.add_cover('rectangle', [[0, 0], [1, 1]], 'solid', 0, 0,
                                 {'red': 0, 'green': 0, 'blue': 0, 'alpha': 0})
        output = self.folder / 'opaque.png'
        export_image(self.workspace.page, output)
        result = QImage(str(output))
        self.assertEqual(result.pixelColor(80, 50), QColor('black'))
        self.assertEqual(result.pixelColor(80, 50).alpha(), 255)

    def test_eraser_target_does_not_change_after_first_item(self):
        self.workspace.add_cover('rectangle', [[0, 0], [1, 1]], 'solid', 0, 0)
        self.workspace.add_cover('ellipse', [[.1, .1], [.9, .9]], 'solid', 0, 0)
        self.workspace.add_drawing('rectangle', [[0, 0], [1, 1]], fill=1)
        self.workspace.selection_ids.clear()
        self.workspace.erase([[.5, .5]], .2, target='regions')
        self.assertEqual([len(p['effect']['erasures']) for p in self.workspace.page.state['regions']], [1, 1])
        self.assertEqual(self.workspace.page.state['drawings'][0]['erasures'], [])

    def test_item_eraser_preserves_earlier_video_and_undo(self):
        self.workspace.video = SimpleNamespace(duration=10)
        self.workspace.time = 0
        self.workspace.add_cover('rectangle', [[0, 0], [1, 1]], 'solid', 0, 0)
        before = deepcopy(self.workspace.page.state)
        self.workspace.erase([[.5, .5]], .1, time=5, mode='item')
        state = self.workspace.page.state
        self.assertEqual(render(self.workspace.page.image, state, 4).pixelColor(80, 50), QColor('black'))
        self.assertEqual(render(self.workspace.page.image, state, 5).pixelColor(80, 50), QColor('white'))
        self.workspace.undo()
        self.assertEqual(self.workspace.page.state, before)

    def test_invalid_resize_and_eraser_do_not_create_undo_or_change_data(self):
        self.workspace.add_cover('rectangle', [[.1, .1], [.3, .3]])
        before = deepcopy(self.workspace.page.state)
        depth = len(self.workspace._undo[0])
        for rect in ([0, 0, -.1, 1], [float('nan'), 0, 1, 1]):
            with self.assertRaises(ValueError):
                self.workspace.resize_selected(rect)
        with self.assertRaises(ValueError):
            self.workspace.erase([[.5, .5]], .1, target='bad')
        self.assertEqual(self.workspace.page.state, before)
        self.assertEqual(len(self.workspace._undo[0]), depth)

    def test_whole_track_shrink_clamps_positive_extent_keeps_line_zero(self):
        from platforms.windows.bluraction.renderer import bounds, shape_points
        self.workspace.add_cover('rectangle', [[.1, .1], [.2, .2]])
        effect = self.workspace.page.state['regions'][0]['effect']
        effect['keyframes'] = [{'time': 1, 'rect': [[.1, .1], [.8, .8]]}]
        self.workspace.resize_selected([.1, .1, .2, .2], time=1)
        base = bounds(shape_points(self.workspace.page.state['regions'][0])[1])
        self.assertAlmostEqual(base[2], 1 / self.workspace.page.point_size[0])
        self.assertGreater(effect['keyframes'][0]['rect'][1][0], 0)
        self.workspace.add_drawing('line', [[.5, .1], [.5, .9]])
        self.workspace.move_selected(.1, .1, time=1)
        self.assertEqual(bounds(self.workspace.page.state['drawings'][0]['points'])[2], 0)

    def test_first_motion_edit_at_start_changes_base_then_later_records(self):
        from platforms.windows.bluraction.renderer import bounds, shape_points
        self.workspace.video = SimpleNamespace(duration=10)
        self.workspace.time = 2
        self.workspace.add_cover('rectangle', [[.1, .1], [.3, .3]])
        self.workspace.record_motion = True
        self.workspace.move_selected(.1, 0, time=2)
        item = self.workspace.page.state['regions'][0]
        self.assertEqual(item['effect']['keyframes'], [])
        self.assertAlmostEqual(bounds(shape_points(item)[1])[0], .2)
        self.workspace.move_selected(.1, 0, time=3)
        self.assertEqual([f['time'] for f in item['effect']['keyframes']], [2, 3])

    def test_filled_freehand_closes_fill_but_keeps_stroke_open(self):
        self.workspace.add_drawing('freehand', [[.2, .2], [.8, .2], [.8, .8]],
            {'red': 0, 'green': 0, 'blue': 0, 'alpha': 1}, .04, .2)
        result = render(self.workspace.page.image, self.workspace.page.state)
        # The closing diagonal has a translucent fill but no opaque stroke.
        self.assertGreater(result.pixelColor(80, 50).red(), 150)
        self.assertLess(result.pixelColor(128, 50).red(), 20)

    def test_text_horizontally_fits_box_and_rounded_background_padding(self):
        self.workspace.add_drawing('text', [[.2, .2], [.8, .8]],
            {'red': 0, 'green': 0, 'blue': 0, 'alpha': 1}, text='W\ni')
        self.workspace.page.state['drawings'][0]['textBackground'] = {'red': 1, 'green': 0, 'blue': 0, 'alpha': 1}
        result = render(self.workspace.page.image, self.workspace.page.state)
        self.assertEqual(result.pixelColor(30, 50), QColor('red'))
        dark = [(x, y) for y in range(20, 48) for x in range(32, 129) if result.pixelColor(x, y).red() < 30]
        self.assertTrue(dark)
        self.assertGreater(max(x for x, y in dark), 115)

    def test_project_decode_race_rejects_new_baseline_and_keeps_open_workspace(self):
        self.workspace.add_cover('rectangle', [[.1, .1], [.3, .3]])
        project = self.folder / 'race.bluraction'
        self.workspace.save_project(project)
        source = self.folder / 'raced.png'
        source.write_bytes(self.original)
        previous = self.workspace.page
        actual_load = load_pages
        def changed_load(paths):
            image = QImage(160, 100, QImage.Format.Format_RGBA8888)
            image.fill(QColor('black'))
            image.save(str(source))
            return actual_load(paths)
        with patch('platforms.windows.bluraction.editor.load_pages', side_effect=changed_load):
            with self.assertRaisesRegex(ValueError, '프로젝트를 여는 동안'):
                self.workspace.load_project(project, {self.source.name: source})
        self.assertIs(self.workspace.page, previous)

    def test_null_and_integral_float_indices_and_media_kind_mismatch(self):
        project = self.folder / 'numeric.bluraction'
        self.workspace.save_project(project)
        tree = json.loads(project.read_text())
        tree['currentIndex'] = 0.0
        tree['pages'][0]['pdfPageIndex'] = None
        project.write_text(json.dumps(tree))
        self.workspace.load_project(project)
        self.assertEqual(self.workspace.index, 0)
        tree['pages'][0]['pdfPageIndex'] = 0.0
        tree['pages'][0]['pdfGeometryVersion'] = 1
        project.write_text(json.dumps(tree))
        previous = self.workspace.page
        with self.assertRaisesRegex(ValueError, '종류'):
            self.workspace.load_project(project)
        self.assertIs(self.workspace.page, previous)

    def test_duplicate_group_keeps_holes_motion_and_originals_one_undo(self):
        first = self.workspace.add_cover('rectangle', [[.1, .1], [.3, .3]])
        second = self.workspace.add_drawing('line', [[.4, .4], [.6, .6]])
        self.workspace.selection_ids = {first, second}
        self.workspace.group_selected()
        region = self.workspace.page.state['regions'][0]
        region['effect']['erasures'] = [{'points': [[.2, .2]], 'width': .1}]
        region['effect']['keyframes'] = [{'time': 1, 'rect': [[.1, .1], [.2, .2]]}]
        before = deepcopy(self.workspace.page.state)
        self.workspace.selectionID = first
        self.workspace.duplicate_selected((.1, -.1))
        after = self.workspace.page.state
        self.assertEqual(after['regions'][0], before['regions'][0])
        self.assertEqual(after['drawings'][0], before['drawings'][0])
        group = after['regions'][1]['effect']['groupID']
        self.assertEqual(group, after['drawings'][1]['groupID'])
        self.assertNotEqual(group, before['regions'][0]['effect']['groupID'])
        self.assertAlmostEqual(after['regions'][1]['effect']['erasures'][0]['points'][0][0], .3)
        self.assertAlmostEqual(after['regions'][1]['effect']['keyframes'][0]['rect'][0][1], 0)
        self.workspace.undo()
        self.assertEqual(self.workspace.page.state, before)

    def test_import_new_identity_clips_times_template_uses_new_source(self):
        self.workspace.add_cover('rectangle', [[.1, .1], [.3, .3]])
        effect = self.workspace.page.state['regions'][0]['effect']
        effect['timeRange'] = [2, 9]
        effect['groupID'] = '11111111-1111-1111-1111-111111111111'
        project = self.folder / 'template.bluraction'
        self.workspace.save_project(project)
        before = deepcopy(self.workspace.page.state)
        self.workspace.video = SimpleNamespace(duration=4)
        self.workspace.import_project_items(project)
        imported = self.workspace.page.state['regions'][1]
        self.assertNotEqual(next(iter(imported['shape'].values()))['id'],
                            next(iter(before['regions'][0]['shape'].values()))['id'])
        self.assertEqual(imported['effect']['timeRange'], [2, 4])
        self.workspace.undo()
        self.assertEqual(self.workspace.page.state, before)
        other = self.folder / 'template-other.png'
        image = QImage(40, 30, QImage.Format.Format_RGBA8888)
        image.fill(QColor('blue'))
        image.save(str(other))
        self.workspace.apply_project_template(project, [other])
        self.assertEqual(self.workspace.page.source, other)
        self.assertEqual(self.workspace.page.state, before)
        self.assertTrue(self.workspace.dirty)
        current = self.workspace.page
        with self.assertRaises(ValueError):
            self.workspace.apply_project_template(project, [self.folder / 'missing.png'])
        self.assertIs(self.workspace.page, current)

    def test_legacy_unfingerprinted_relink_needs_explicit_acknowledgement(self):
        project = self.folder / 'legacy.bluraction'
        tree = {'version': 1, 'mediaPath': 'C:\\synthetic\\original.png', 'regions': [], 'drawings': []}
        project.write_text(json.dumps(tree))
        original_page = self.workspace.page
        with self.assertRaises(UnverifiedSources):
            self.workspace.load_project(project, {tree['mediaPath']: self.source})
        self.assertIs(self.workspace.page, original_page)
        self.workspace.load_project(project, {tree['mediaPath']: self.source}, {tree['mediaPath']})
        self.assertEqual(self.workspace.page.source, self.source)

    def test_large_project_is_rejected_before_read(self):
        from shared.portable_project import MAX_V2_BYTES
        project = self.folder / 'oversize.bluraction'
        with project.open('wb') as stream:
            stream.truncate(MAX_V2_BYTES + 1)
        with patch.object(Path, 'open', side_effect=AssertionError('must not read oversize project')):
            with self.assertRaisesRegex(ValueError, '크기'):
                self.workspace.load_project(project)

    def test_mosaic_grid_origin_partial_tiles_and_fractional_cell_size(self):
        from platforms.windows.bluraction.renderer import mosaic
        import numpy as np
        # Native CoreImage synthetic probe, working/output sRGB. The 13px
        # height deliberately has a partial tile at the top (bottom origin).
        source = np.zeros((13, 19, 4), dtype=np.uint8)
        source[:, :, 0] = np.arange(19) * 10
        source[:, :, 1] = np.arange(13)[:, None] * 15
        source[:, :, 3] = 255
        expected = {
            4: ([15] * 4 + [55] * 4 + [95] * 4 + [135] * 4 + [175] * 3,
                [0] + [38] * 4 + [98] * 4 + [157] * 4),
            4.5: ([18] * 4 + [63] * 5 + [108] * 4 + [152] * 5 + [180],
                  [19] * 4 + [86] * 5 + [154] * 4),
        }
        for cell, (red, green) in expected.items():
            pixels = np.asarray(mosaic(Image.fromarray(source), cell))
            self.assertLessEqual(max(abs(int(a) - b) for a, b in zip(pixels[0, :, 0], red)), 1)
            self.assertLessEqual(max(abs(int(a) - b) for a, b in zip(pixels[:, 0, 1], green)), 1)

    def test_item_eraser_aspect_ratio_matches_visible_brush_and_arrow_head(self):
        self.workspace.add_drawing('line', [[.5, .2], [.5, .8]], width=.02)
        self.workspace.erase([[.555, .5]], .1, mode='item')
        self.assertEqual(len(self.workspace.page.state['drawings']), 1)
        self.workspace.erase([[.54, .5]], .1, mode='item')
        self.assertEqual(self.workspace.page.state['drawings'], [])
        self.workspace.add_drawing('arrow', [[.1, .5], [.9, .5]], width=.08)
        # A point near the outer head, several pixels away from the shaft.
        self.workspace.erase([[.75, .63]], .01, mode='item')
        self.assertEqual(self.workspace.page.state['drawings'], [])

    def test_item_eraser_hollow_rectangle_does_not_hit_empty_center(self):
        self.workspace.add_drawing('rectangle', [[.1, .1], [.9, .9]], width=.02, fill=0)
        self.workspace.erase([[.5, .5]], .1, mode='item')
        self.assertEqual(len(self.workspace.page.state['drawings']), 1)
        self.workspace.erase([[.1, .5]], .1, mode='item')
        self.assertEqual(self.workspace.page.state['drawings'], [])

    def test_template_starts_empty_workspace_and_busy_keeps_existing(self):
        self.workspace.add_cover('rectangle', [[.1, .1], [.3, .3]])
        project = self.folder / 'start-template.bluraction'
        self.workspace.save_project(project)
        fresh = Workspace()
        fresh.apply_project_template(project, [self.source])
        self.assertEqual(fresh.page.state, self.workspace.page.state)
        page = fresh.page
        fresh.busy = True
        with self.assertRaises(ValueError):
            fresh.apply_project_template(project, [self.source])
        self.assertIs(fresh.page, page)

    def test_project_total_source_budget_checked_before_any_hash(self):
        tree = {'version': 2, 'title': 'oversize', 'currentIndex': 0, 'pages': []}
        for index in range(9):
            source = self.folder / f'sparse-{index}.png'
            with source.open('wb') as out:
                out.truncate(128 * 1024 ** 2)
            tree['pages'].append({'mediaPath': source.name, 'sourceSHA256': '0' * 64,
                                 'regions': [], 'drawings': []})
        project = self.folder / 'too-many-bytes.bluraction'
        project.write_text(json.dumps(tree))
        page = self.workspace.page
        with patch('platforms.windows.bluraction.editor.fingerprint', side_effect=AssertionError('must not hash')):
            with self.assertRaisesRegex(ValueError, '1GB'):
                self.workspace.load_project(project)
        self.assertIs(self.workspace.page, page)

    def test_zero_mosaic_uses_minimum_tile_and_full_frame_feather_clamps(self):
        gradient = QImage(20, 10, QImage.Format.Format_RGBA8888)
        for y in range(10):
            for x in range(20):
                gradient.setPixelColor(x, y, QColor(x * 10, y * 20, 0))
        self.workspace.add_cover('rectangle', [[0, 0], [1, 1]], 'mosaic', 0, 0)
        result = render(gradient, self.workspace.page.state)
        self.assertNotEqual(result.pixelColor(0, 0), gradient.pixelColor(0, 0))
        self.workspace.update_selected(style='solid', color={'red': 0, 'green': 0, 'blue': 0, 'alpha': 0}, featherRadius=12)
        result = render(self.workspace.page.image, self.workspace.page.state)
        for x, y in ((0, 0), (159, 0), (0, 99), (159, 99), (80, 50)):
            self.assertEqual(result.pixelColor(x, y), QColor('black'))


if __name__ == '__main__':
    unittest.main()
