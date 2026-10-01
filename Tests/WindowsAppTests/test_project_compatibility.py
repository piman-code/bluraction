"""Actual Qt grapheme segmentation on synthetic Swift contract copies.

No personal media, media decoder, app window, install or OS control is used.
These tests are authored for serial execution by the parent, not yet executed.
"""
from copy import deepcopy
from pathlib import Path
import json
import re
import unittest

from PySide6.QtCore import QTextBoundaryFinder

from shared.portable_project import PortableProject, ProjectError, dump_project
from platforms.windows.bluraction.project_compatibility import (
    bounded_name_with_suffix, grapheme_count, validate_host_reviews)

ROOT = Path(__file__).resolve().parents[2]
HANGUL = '\u1100\u1161\u11a8'  # Decomposed 각, three scalars / one cluster.
ACCENT = 'e\u0301'
FAMILY = '\U0001f468\u200d\U0001f469\u200d\U0001f467\u200d\U0001f466'


class ProjectCompatibilityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.v1 = json.loads((ROOT / 'shared/fixtures/swift-v1-rich.bluraction').read_text(encoding='utf-8'))
        cls.v2 = json.loads((ROOT / 'shared/fixtures/swift-v2-rich.bluraction').read_text(encoding='utf-8'))

    def test_real_qt_cluster_count_covers_hangul_combining_emoji_flags_and_crlf(self):
        for cluster in (HANGUL, ACCENT, FAMILY, '\U0001f1f0\U0001f1f7', '\U0001f44d\U0001f3fd', '\r\n'):
            with self.subTest(cluster=repr(cluster)):
                self.assertEqual(grapheme_count(cluster * 200), 200)
        self.assertEqual(grapheme_count(''), 0)
        self.assertEqual(grapheme_count('abc'), 3)
        self.assertEqual(grapheme_count(FAMILY * 1000, stop_after=200), 201)

    def test_two_hundred_hangul_and_emoji_names_clear_native_reviews_losslessly(self):
        tree = deepcopy(self.v1)
        tree['regions'][0]['effect']['name'] = HANGUL * 200
        tree['drawings'][0]['name'] = FAMILY * 200
        tree['drawings'][0]['fontName'] = ACCENT * 200
        tree['drawings'][0]['text'] = HANGUL * 1000
        tree['mediaPath'] = HANGUL * 4092 + '.png'
        project = PortableProject(tree)
        before, reviews = dump_project(project), project.required_reviews
        self.assertTrue(reviews)
        self.assertTrue(all('native grapheme-count' in reason for reason in reviews))
        self.assertEqual(validate_host_reviews(project), ())
        self.assertEqual(project.to_dict(), tree)
        self.assertEqual(project.required_reviews, reviews)
        self.assertEqual(dump_project(project), before)

    def test_v2_title_and_nested_page_text_limits_are_checked_by_actual_path(self):
        tree = deepcopy(self.v2)
        tree['title'] = HANGUL * 255
        tree['pages'][1]['drawings'][0]['name'] = FAMILY * 200
        tree['pages'][1]['drawings'][0]['text'] = FAMILY * 1000
        project = PortableProject(tree)
        self.assertIn('$.title: native grapheme-count limit 255 requires validation', project.required_reviews)
        self.assertTrue(any('$.pages[1].drawings[0].name' in reason for reason in project.required_reviews))
        self.assertEqual(validate_host_reviews(project), ())
        self.assertEqual(project.to_dict(), tree)

    def test_swift_crlf_cluster_limits_resolve_without_changing_line_endings(self):
        tree = deepcopy(self.v1)
        tree['drawings'][0]['text'] = '\r\n' * 1000
        project = PortableProject(tree)
        before = dump_project(project)
        self.assertIn('$.drawings[0].text: native grapheme-count limit 1000 requires validation',
                      project.required_reviews)
        self.assertEqual(grapheme_count(tree['drawings'][0]['text']), 1000)
        self.assertEqual(validate_host_reviews(project), ())
        self.assertEqual(dump_project(project), before)
        self.assertEqual(project.to_dict()['drawings'][0]['text'], '\r\n' * 1000)
        tree['drawings'][0]['text'] = '\r\n' * 1001
        with self.assertRaisesRegex(ProjectError, r'\$\.drawings\[0\]\.text.*limit 1000'):
            validate_host_reviews(PortableProject(tree))

    def test_over_limit_text_raises_with_the_corresponding_field_path(self):
        for version in (1, 2):
            for kind, limit in (('mediaPath', 4096), ('region-name', 200), ('drawing-name', 200),
                                ('fontName', 200), ('text', 1000)):
                with self.subTest(version=version, kind=kind):
                    tree = deepcopy(self.v1 if version == 1 else self.v2)
                    page, path = (tree, '$') if version == 1 else (tree['pages'][1], '$.pages[1]')
                    value = FAMILY * (limit + 1)
                    if kind == 'mediaPath':
                        page['mediaPath'] = value; expected_path = path + '.mediaPath'
                    elif kind == 'region-name':
                        page['regions'][0]['effect']['name'] = value; expected_path = path + '.regions[0].effect.name'
                    else:
                        field = 'name' if kind == 'drawing-name' else kind
                        page['drawings'][0][field] = value; expected_path = path + '.drawings[0].' + field
                    project = PortableProject(tree)
                    before = dump_project(project)
                    with self.assertRaisesRegex(ProjectError, re.escape(expected_path) + '.*limit ' + str(limit)):
                        validate_host_reviews(project)
                    self.assertEqual(dump_project(project), before)
        tree = deepcopy(self.v2); tree['title'] = HANGUL * 256
        with self.assertRaisesRegex(ProjectError, r'\$\.title.*limit 255'):
            validate_host_reviews(PortableProject(tree))

    def test_unknown_and_legacy_reviews_remain_after_valid_text_review_is_resolved(self):
        tree = deepcopy(self.v2)
        tree['title'] = HANGUL * 255
        tree['futureRendering'] = {'keep': 'opaque future contract'}
        tree['pages'][0]['regions'][0]['effect']['futureOpacityMeaning'] = {'value': .5}
        tree['pages'][1].pop('pdfGeometryVersion')
        project = PortableProject(tree)
        before = dump_project(project)
        expected = tuple(reason for reason in project.required_reviews if 'native grapheme-count' not in reason)
        self.assertTrue(any('unknown fields' in reason for reason in expected))
        self.assertTrue(any('legacy edited PDF' in reason for reason in expected))
        self.assertEqual(validate_host_reviews(project), expected)
        self.assertEqual(dump_project(project), before)
        self.assertEqual(project.to_dict()['futureRendering'], tree['futureRendering'])

    def test_unrecognized_grapheme_path_or_limit_is_not_blanket_cleared(self):
        tree = deepcopy(self.v1); tree['drawings'][0]['name'] = HANGUL * 200
        project = PortableProject(tree)
        extra = ('$.futureName: native grapheme-count limit 200 requires validation',
                 '$.drawings[0].name: native grapheme-count limit 999 requires validation',
                 '$: future host approval is required')
        project.required_reviews += extra
        self.assertEqual(validate_host_reviews(project), extra)

    def test_canonical_reviews_cannot_be_bypassed_by_replacing_the_public_tuple(self):
        tree = deepcopy(self.v2); tree['futureRenderer'] = {'mustRemainBlocked': True}
        project = PortableProject(tree)
        canonical = project.required_reviews
        project.required_reviews = ()
        self.assertEqual(validate_host_reviews(project), canonical)
        tree = deepcopy(self.v1); tree['drawings'][0]['name'] = HANGUL * 201
        project = PortableProject(tree); project.required_reviews = ()
        with self.assertRaisesRegex(ProjectError, r'\$\.drawings\[0\]\.name.*limit 200'):
            validate_host_reviews(project)

    def test_qstring_utf16_boundary_is_not_a_python_slice_index(self):
        finder = QTextBoundaryFinder(QTextBoundaryFinder.BoundaryType.Grapheme, FAMILY + 'Z')
        finder.toStart()
        first = finder.toNextBoundary()
        self.assertEqual(first, len(FAMILY.encode('utf-16-le')) // 2)
        self.assertGreater(first, len(FAMILY))
        self.assertEqual(bounded_name_with_suffix(FAMILY * 20, '.pdf', maxclusters=6), FAMILY * 2 + '.pdf')
        self.assertEqual(bounded_name_with_suffix('A' + FAMILY + ACCENT + HANGUL, '.pdf', maxclusters=6),
                         'A' + FAMILY + '.pdf')

    def test_suffix_and_unicode_spelling_survive_truncation_and_short_names_are_unchanged(self):
        suffix = '_copy'
        for cluster in (HANGUL, ACCENT, FAMILY):
            with self.subTest(cluster=repr(cluster)):
                result = bounded_name_with_suffix(cluster * 210, suffix)
                self.assertEqual(result, cluster * 195 + suffix)
                self.assertEqual(grapheme_count(result), 200)
                self.assertTrue(result.endswith(suffix))
        self.assertEqual(bounded_name_with_suffix('짧은 이름', '.bluraction'), '짧은 이름.bluraction')
        # A combining suffix joins the preceding cluster. Keep the full name
        # when the combined value is already within the real Qt limit.
        self.assertEqual(bounded_name_with_suffix('a' * 200, '\u0301'), 'a' * 200 + '\u0301')
        self.assertEqual(bounded_name_with_suffix('abc', '', maxclusters=0), '')

    def test_invalid_limits_suffix_budget_and_surrogates_are_rejected(self):
        for maximum in (True, -1, 2.5):
            with self.subTest(maximum=maximum):
                with self.assertRaises(ValueError):
                    bounded_name_with_suffix('name', '.pdf', maximum)
        with self.assertRaisesRegex(ValueError, '접미사'):
            bounded_name_with_suffix('name', '.bluraction', maxclusters=5)
        with self.assertRaises(TypeError):
            validate_host_reviews(self.v1)
        with self.assertRaises(ValueError):
            grapheme_count('\ud800')
        with self.assertRaises(ValueError):
            bounded_name_with_suffix('name', '\udfff')


if __name__ == '__main__':
    unittest.main()
