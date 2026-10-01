"""Temporary legacy shift protection, not actual PyAV/Windows compatibility.

Policy checks use JSON states. Transaction checks invoke real Workspace load/save
with regular synthetic files and explicitly fake video decoding/exact origins.
"""
from copy import deepcopy
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from platforms.windows.bluraction.video_project_compatibility import (
    VideoTimelineReview, require_legacy_video_timing_compatible,
)


def region(kind='rectangle'):
    geometry = {'id': '00000000-0000-0000-0000-000000000001'}
    if kind == 'polygon':
        geometry['points'] = [[.1, .1], [.8, .1], [.4, .8]]
    else:
        geometry.update(origin=[.1, .1], size=[.7, .7])
    return {'shape': {kind: geometry}, 'effect': {
        'blurRadius': 0, 'featherRadius': 0, 'timeRange': [0, 0],
        'enabled': True, 'style': 'solid', 'keyframes': [], 'erasures': []}}


def drawing(kind='line'):
    return {'id': '00000000-0000-0000-0000-000000000002', 'kind': kind,
        'points': [[.1, .1], [.8, .8]], 'red': 1, 'green': 0, 'blue': 0,
        'alpha': 1, 'lineWidth': .01, 'fillOpacity': 0,
        'timeRange': [0, 0], 'keyframes': [], 'erasures': [], 'text': '합성'}


def encoded(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode('utf-8')


class VideoTimingPolicyTests(unittest.TestCase):
    def rejected_without_mutation(self, state, origin):
        before = encoded(state)
        with self.assertRaisesRegex(VideoTimelineReview, '시간축 호환 검토'):
            require_legacy_video_timing_compatible(state, origin)
        self.assertEqual(encoded(state), before)

    def test_explicit_region_periods_and_single_frame_for_all_cover_shapes(self):
        for shape in ('rectangle', 'ellipse', 'polygon'):
            for interval in ([0, 1], [.5, .5], [.25, 1.25]):
                item = region(shape)
                item['effect']['timeRange'] = interval
                for origin in (Fraction(1, 2), Fraction(-1, 2), None):
                    with self.subTest(shape=shape, interval=interval, origin=origin):
                        self.rejected_without_mutation({'regions': [item], 'drawings': []}, origin)

    def test_drawing_periods_cover_pen_shapes_arrow_and_text(self):
        for kind in ('freehand', 'line', 'rectangle', 'ellipse', 'arrow', 'text'):
            item = drawing(kind)
            item['timeRange'] = [0, 1.5]
            with self.subTest(kind=kind):
                self.rejected_without_mutation({'regions': [], 'drawings': [item]}, Fraction(1, 2))

    def test_any_motion_keyframe_is_temporal_even_at_zero_and_same_rectangle(self):
        for is_region in (True, False):
            item = region() if is_region else drawing()
            props = item['effect'] if is_region else item
            props['keyframes'] = [{'time': 0, 'rect': [[.1, .1], [.7, .7]]}]
            state = {'regions': [item] if is_region else [], 'drawings': [] if is_region else [item]}
            self.rejected_without_mutation(state, Fraction(-1, 10))

    def test_nonnull_erasure_from_including_zero_is_temporal(self):
        for is_region in (True, False):
            for start in (0, .5):
                item = region() if is_region else drawing()
                props = item['effect'] if is_region else item
                props['erasures'] = [{'points': [[.3, .3]], 'width': .1, 'from': start}]
                state = {'regions': [item] if is_region else [], 'drawings': [] if is_region else [item]}
                with self.subTest(region=is_region, start=start):
                    self.rejected_without_mutation(state, None)

    def test_schema_valid_null_erasure_cutoff_is_all_time_not_a_shift_hold(self):
        from shared.portable_project import PortableProject, dump_project, load_project
        cover, annotation = region(), drawing()
        for props in (cover['effect'], annotation):
            props['erasures'] = [{'points': [[.2, .2]], 'width': .1, 'from': None}]
        state = {'regions': [cover], 'drawings': [annotation]}
        payload = dump_project(PortableProject({'version': 1, 'mediaPath': 'synthetic.mp4', **state}))
        decoded = load_project(payload).to_dict()
        before = encoded(decoded)
        self.assertIsNone(require_legacy_video_timing_compatible(decoded, Fraction(1, 2)))
        self.assertEqual(encoded(decoded), before)
        for props in (decoded['regions'][0]['effect'], decoded['drawings'][0]):
            self.assertIn('from', props['erasures'][0])
            self.assertIsNone(props['erasures'][0]['from'])

    def test_hidden_disabled_locked_temporal_edits_are_not_silently_ignored(self):
        cover, annotation = region(), drawing()
        cover['effect'].update(timeRange=[.5, 1], enabled=False, locked=True)
        annotation.update(timeRange=[.5, 1], hidden=True, locked=True)
        for state in ({'regions': [cover], 'drawings': []}, {'regions': [], 'drawings': [annotation]}):
            self.rejected_without_mutation(state, Fraction(1, 2))

    def test_unknown_nonexact_and_nonzero_origin_require_review(self):
        item = region()
        item['effect']['timeRange'] = [.5, 1]
        state = {'regions': [item], 'drawings': []}
        class InheritedFraction(Fraction):
            pass
        for origin in (None, 0, 0.0, False, '0', float('nan'), float('inf'),
                       Fraction(1, 10**12), Fraction(-1, 10**12), InheritedFraction(0)):
            with self.subTest(origin=origin):
                self.rejected_without_mutation(state, origin)

    def test_exact_zero_passes_only_narrow_guard_and_preserves_all_time_bytes(self):
        cover, annotation = region(), drawing('arrow')
        cover['effect'].update(timeRange=[.08333333333333333, .08333333333333333],
            keyframes=[{'time': .5, 'rect': [[.1, .1], [.7, .7]]}],
            erasures=[{'points': [[.2, .2]], 'width': .1, 'from': .5}])
        annotation['timeRange'] = [.5, 1]
        state = {'regions': [cover], 'drawings': [annotation]}
        before = encoded(state)
        self.assertIsNone(require_legacy_video_timing_compatible(state, Fraction(0)))
        self.assertEqual(encoded(state), before)

    def test_truly_always_on_and_nontemporal_erasures_pass_unknown_origin(self):
        cover, annotation = region('polygon'), drawing('text')
        cover['effect']['erasures'] = [{'points': [[.2, .2]], 'width': .1}]
        annotation.pop('timeRange')  # Legacy drawing omission means always-on.
        state = {'regions': [cover], 'drawings': [annotation]}
        for origin in (None, Fraction(1, 2), Fraction(-1, 2), 0.0):
            before = encoded(state)
            self.assertIsNone(require_legacy_video_timing_compatible(state, origin))
            self.assertEqual(encoded(state), before)
        self.assertIsNone(require_legacy_video_timing_compatible({'regions': [], 'drawings': []}, None))

    def test_explicit_unknown_range_is_not_inferred_as_always_on(self):
        item = drawing()
        item['timeRange'] = None
        self.rejected_without_mutation({'regions': [], 'drawings': [item]}, None)


class VideoTimingWorkspaceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Native Qt is used only for synthetic pixels; no player/codec is used.
        import os
        os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
        from PySide6.QtWidgets import QApplication
        cls.app = QApplication.instance() or QApplication([])

    def setUp(self):
        from PySide6.QtGui import QColor, QImage
        from platforms.windows.bluraction.editor import Workspace
        from platforms.windows.bluraction.media import Page, fingerprint
        self.temp = tempfile.TemporaryDirectory(prefix='bluraction-video-timing-test-')
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.old_source = self.folder / 'old-synthetic.mp4'
        self.new_source = self.folder / 'new-synthetic.mp4'
        for source in (self.old_source, self.new_source):
            source.write_bytes(b'explicit fake video source; no encoded media or codec proof: ' + source.name.encode())
        self.original = {source: source.read_bytes() for source in (self.old_source, self.new_source)}
        self.origins = {self.old_source: Fraction(0), self.new_source: Fraction(1, 2)}
        origins = self.origins

        class FakeVideoSource:
            def __init__(self, path, cancel=None):
                self.source = Path(path).absolute()
                self.origin = origins[self.source]
                self.duration = 1.5
                self.image = QImage(32, 24, QImage.Format.Format_RGBA8888)
                self.image.fill(QColor('white'))
            def page(self):
                return Page(self.source, fingerprint(self.source), self.image)

        self.patch_video = patch('platforms.windows.bluraction.video.VideoSource', FakeVideoSource)
        self.patch_video.start()
        self.addCleanup(self.patch_video.stop)
        self.workspace = Workspace()
        self.workspace.load([self.old_source])
        first = self.workspace.add_cover('rectangle', [[.1, .1], [.4, .4]], style='solid')
        self.baseline = self.folder / 'previous.bluraction'
        self.workspace.save_project(self.baseline)
        self.baseline_bytes = self.baseline.read_bytes()
        second = self.workspace.add_drawing('line', [[.2, .2], [.8, .8]])
        self.workspace.add_cover('ellipse', [[.5, .5], [.8, .8]])
        self.workspace.undo()
        self.workspace.selection_ids = {first, second}
        self.workspace.title = '이전 dirty 영상 편집'
        self.workspace.time = .75
        self.workspace.record_motion = True
        self.assertTrue(self.workspace.dirty)
        self.assertTrue(self.workspace.can_undo)
        self.assertTrue(self.workspace.can_redo)

    def tearDown(self):
        for path, content in self.original.items():
            self.assertEqual(path.read_bytes(), content)
        self.assertEqual(self.baseline.read_bytes(), self.baseline_bytes)

    def snapshot(self):
        value = self.workspace
        metadata = {key: deepcopy(getattr(value, key)) for key in (
            'index', 'title', 'time', 'busy', 'record_motion', 'dirty',
            '_undo', '_redo', '_project_tree', 'review_required')}
        metadata['selection'] = sorted(value.selection_ids)
        metadata['pages'] = [{'source': str(page.source), 'sha256': page.source_sha256,
            'pdfIndex': page.pdf_index, 'pointSize': page.point_size, 'state': page.state}
            for page in value.pages]
        return (value.pages, value.page, value.video, encoded(metadata),
                bytes(value.page.image.constBits()))

    def preserved(self, before):
        after = self.snapshot()
        for old, new in zip(before[:3], after[:3]):
            self.assertIs(old, new)
        self.assertEqual(after[3:], before[3:])
        self.assertTrue(self.workspace.can_undo)
        self.assertTrue(self.workspace.can_redo)

    def project(self, state, name='incoming.bluraction'):
        from shared.portable_project import PortableProject, dump_project
        tree = {'version': 1, 'mediaPath': self.new_source.name,
            'sourceSHA256': hashlib.sha256(self.original[self.new_source]).hexdigest(), **deepcopy(state)}
        path = self.folder / name
        path.write_bytes(dump_project(PortableProject(tree)))
        return path

    def test_real_load_rejects_nonzero_or_unknown_origin_before_commit_and_keeps_dirty_history(self):
        state = {'regions': [region()], 'drawings': [drawing()]}
        state['regions'][0]['effect']['timeRange'] = [.5, 1]
        incoming = self.project(state)
        incoming_bytes = incoming.read_bytes()
        for origin in (Fraction(1, 2), Fraction(-1, 2), None, 0.0):
            self.origins[self.new_source] = origin
            before = self.snapshot()
            with patch.object(self.workspace, '_replace', side_effect=AssertionError('unsafe state commit')) as commit:
                with self.subTest(origin=origin), self.assertRaises(VideoTimelineReview):
                    self.workspace.load_project(incoming)
                commit.assert_not_called()
            self.preserved(before)
            self.assertEqual(incoming.read_bytes(), incoming_bytes)

    def test_real_load_motion_and_temporal_erasure_without_period_are_also_rejected(self):
        for field in ('keyframes', 'erasures'):
            state = {'regions': [], 'drawings': [drawing('arrow')]}
            state['drawings'][0][field] = ([{'time': .5, 'rect': [[.1, .1], [.7, .7]]}]
                if field == 'keyframes' else [{'points': [[.2, .2]], 'width': .1, 'from': .5}])
            incoming = self.project(state, field + '.bluraction')
            before = self.snapshot()
            with self.subTest(field=field), self.assertRaises(VideoTimelineReview):
                self.workspace.load_project(incoming)
            self.preserved(before)

    def test_real_save_rejection_creates_no_output_and_preserves_state_tree_and_history(self):
        from platforms.windows.bluraction import editor
        for origin in (Fraction(1, 2), Fraction(-1, 2), None, 0.0):
            self.workspace.video.origin = origin
            target = self.folder / 'must-not-create.bluraction'
            before = self.snapshot()
            names = {path.name for path in self.folder.iterdir()}
            with patch.object(editor, 'save_bytes_new', side_effect=AssertionError('unsafe output creation')) as write:
                with self.subTest(origin=origin), self.assertRaises(VideoTimelineReview):
                    self.workspace.save_project(target)
                write.assert_not_called()
            self.assertFalse(target.exists())
            self.assertEqual({path.name for path in self.folder.iterdir()}, names)
            self.preserved(before)

    def test_real_zero_origin_load_and_save_preserve_authored_time_values(self):
        self.origins[self.new_source] = Fraction(0)
        state = {'regions': [region()], 'drawings': [drawing('arrow')]}
        state['regions'][0]['effect']['timeRange'] = [.08333333333333333, .08333333333333333]
        state['drawings'][0]['erasures'] = [{'points': [[.2, .2]], 'width': .1, 'from': .5}]
        incoming = self.project(state)
        self.workspace.load_project(incoming)
        self.assertEqual(encoded(self.workspace.page.state), encoded(state))
        target = self.folder / 'zero-narrow-control.bluraction'
        self.workspace.save_project(target)
        tree = json.loads(target.read_bytes())
        self.assertEqual(encoded({key: tree[key] for key in ('regions', 'drawings')}), encoded(state))
        self.assertNotIn('timelinePolicy', tree)
        self.assertFalse(self.workspace.dirty)

    def test_real_always_on_load_and_save_pass_without_fabricating_timeline_metadata(self):
        state = {'regions': [region('polygon')], 'drawings': [drawing('text')]}
        state['drawings'][0].pop('timeRange')
        state['regions'][0]['effect']['erasures'] = [{'points': [[.2, .2]], 'width': .1, 'from': None}]
        incoming = self.project(state)
        self.workspace.load_project(incoming)
        self.assertEqual(encoded(self.workspace.page.state), encoded(state))
        target = self.folder / 'always-on-control.bluraction'
        self.workspace.save_project(target)
        tree = json.loads(target.read_bytes())
        self.assertEqual(encoded({key: tree[key] for key in ('regions', 'drawings')}), encoded(state))
        self.assertNotIn('timelinePolicy', tree)
        self.assertEqual(self.workspace.video.origin, Fraction(1, 2))

    def test_real_item_import_hold_preserves_dirty_history_and_selection_on_nonzero_or_unknown_target(self):
        state = {'regions': [region()], 'drawings': [drawing()]}
        state['drawings'][0]['timeRange'] = [.5, 1]
        incoming = self.project(state, 'import-timed.bluraction')
        incoming_bytes = incoming.read_bytes()
        for origin in (Fraction(1, 2), Fraction(-1, 2), None, 0.0):
            self.workspace.video.origin = origin
            before = self.snapshot()
            with patch.object(self.workspace, '_checkpoint', side_effect=AssertionError('unsafe history commit')) as commit:
                with self.subTest(origin=origin), self.assertRaises(VideoTimelineReview):
                    self.workspace.import_project_items(incoming)
                commit.assert_not_called()
            self.preserved(before)
            self.assertEqual(incoming.read_bytes(), incoming_bytes)

    def test_real_template_hold_uses_candidate_origin_and_keeps_previous_session(self):
        state = {'regions': [region()], 'drawings': [drawing()]}
        state['regions'][0]['effect']['keyframes'] = [{'time': .5, 'rect': [[.1, .1], [.7, .7]]}]
        incoming = self.project(state, 'template-timed.bluraction')
        incoming_bytes = incoming.read_bytes()
        self.assertEqual(self.workspace.video.origin, Fraction(0))
        for origin in (Fraction(1, 2), Fraction(-1, 2), None, 0.0):
            self.origins[self.new_source] = origin
            before = self.snapshot()
            with patch.object(self.workspace, '_replace', side_effect=AssertionError('unsafe template commit')) as commit:
                with self.subTest(origin=origin), self.assertRaises(VideoTimelineReview):
                    self.workspace.apply_project_template(incoming, [self.new_source])
                commit.assert_not_called()
            self.preserved(before)
            self.assertEqual(incoming.read_bytes(), incoming_bytes)

    def test_real_zero_origin_import_and_template_keep_legacy_time_values(self):
        self.origins[self.new_source] = Fraction(0)
        state = {'regions': [region()], 'drawings': [drawing('arrow')]}
        state['regions'][0]['effect']['timeRange'] = [.5, 1]
        state['drawings'][0]['keyframes'] = [{'time': .5, 'rect': [[.1, .1], [.7, .7]]}]
        state['drawings'][0]['erasures'] = [{'points': [[.2, .2]], 'width': .1, 'from': .75}]
        incoming = self.project(state, 'zero-import-template.bluraction')
        original = incoming.read_bytes()
        self.workspace.import_project_items(incoming)
        self.assertEqual(self.workspace.page.state['regions'][-1]['effect'], state['regions'][0]['effect'])
        imported = deepcopy(self.workspace.page.state['drawings'][-1])
        self.assertNotEqual(imported.pop('id'), state['drawings'][0]['id'])
        original_drawing = deepcopy(state['drawings'][0]); original_drawing.pop('id')
        self.assertEqual(encoded(imported), encoded(original_drawing))
        self.workspace.apply_project_template(incoming, [self.new_source])
        self.assertEqual(encoded(self.workspace.page.state), encoded(state))
        self.assertEqual(self.workspace.video.origin, Fraction(0))
        self.assertTrue(self.workspace.dirty)
        self.assertEqual(incoming.read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
