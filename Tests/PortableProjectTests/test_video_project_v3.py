"""Video v3 JSON boundary only: no host loading, media reads or decoder proof.

The authored v3 envelope uses the shared exact timeline DTO and unchanged rich
v1/v2 editing representations. Native clocks/playback/export require separate QA.
"""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import uuid

from shared.portable_project import (MAX_V1_BYTES, MAX_V2_BYTES, MAX_V3_BYTES,
                                     PortableProject, ProjectError, dump_project,
                                     load_project, save_project_new)
from Tests.PortableProjectTests.test_portable_project import fixture as legacy_fixture
from Tests.PortableProjectTests.test_video_timeline import fixture as timeline_fixture


def fixture():
    project = timeline_fixture()
    edits = legacy_fixture(1)
    project.update(mediaPath='synthetic-video.mov', regions=edits['regions'], drawings=edits['drawings'])
    return project


class VideoProjectV3Tests(unittest.TestCase):
    def test_rich_roundtrip_keeps_edit_times_fields_ids_and_asset_metadata_exactly(self):
        data = fixture()
        data['regions'][0]['effect']['keyframes'] = [
            {'time': 2, 'rect': [[.1, .2], [.3, .4]]},
            {'time': .5000162760416667, 'rect': [[.6, .1], [.2, .2]]},
            {'time': 2, 'rect': [[.4, .3], [.5, .2]]}]
        data['drawings'][0]['erasures'][0]['from'] = .5000162760416667
        expected = copy.deepcopy(data)
        project = load_project(json.dumps(data).encode())
        self.assertEqual(project.version, 3)
        self.assertEqual(project.required_reviews, ())
        self.assertEqual(load_project(dump_project(project)).to_dict(), expected)
        self.assertEqual(project.to_dict(), expected)
        # The data boundary neither clips a template nor shifts saved timestamps
        # merely because edits extend beyond the descriptor's asset duration.
        self.assertEqual(project.to_dict()['regions'][0]['effect']['timeRange'], [2, 5])
        data.clear()
        exposed = project.to_dict(); exposed['regions'].clear(); exposed['timeline'].clear()
        self.assertEqual(project.to_dict(), expected, 'Both construction and access are copies')

    def test_every_existing_shape_and_drawing_enum_remains_lossless_in_v3(self):
        data = fixture(); region, drawing = data['regions'][0], data['drawings'][0]
        data['regions'], data['drawings'] = [], []
        for index, kind in enumerate(('rectangle', 'ellipse', 'polygon')):
            body = {'id': str(uuid.UUID(int=index + 1)).upper()}
            if kind == 'polygon':
                body['points'] = [[.1, .2], [.5, .7], [.8, .3]]
            else:
                body.update(origin=[.1, .2], size=[.3, .4])
            item = copy.deepcopy(region); item['shape'] = {kind: body}
            data['regions'].append(item)
        for index, kind in enumerate(('rectangle', 'ellipse', 'line', 'freehand', 'arrow', 'text')):
            item = copy.deepcopy(drawing); item.update(id=str(uuid.UUID(int=index + 100)).upper(), kind=kind)
            data['drawings'].append(item)
        self.assertEqual(load_project(dump_project(PortableProject(data))).to_dict(), data)

    def test_unknown_root_and_edit_fields_survive_and_require_review_without_interpretation(self):
        data = fixture()
        data['futureExtension'] = {'instructions': 'never execute this string', 'order': [3, 2, 1]}
        data['pdfPageIndex'] = 'uninterpreted future root field'
        data['pdfGeometryVersion'] = {'future': None}
        data['regions'][0]['effect']['futureEffect'] = {'enabled': False}
        data['drawings'][0]['futureDrawing'] = [None, True, 'verbatim']
        project = PortableProject(data)
        self.assertTrue(any('unknown fields retained' in reason for reason in project.required_reviews))
        self.assertEqual(load_project(dump_project(project)).to_dict(), data)
        source, = project.sources
        self.assertEqual(source.media_path, data['mediaPath'])
        self.assertEqual(source.expected_sha256, data['sourceSHA256'])
        self.assertIsNone(source.page_index)
        self.assertIsNone(source.pdf_geometry_version)

    def test_optional_absent_and_explicit_null_edit_values_are_not_filled_or_removed(self):
        data = fixture(); effect, drawing = data['regions'][0]['effect'], data['drawings'][0]
        for field in ('style', 'color', 'groupID', 'erasures', 'name', 'locked'):
            effect.pop(field)
        for field in ('fillOpacity', 'timeRange', 'keyframes', 'text', 'groupID', 'erasures',
                      'name', 'hidden', 'locked', 'fontName', 'bold', 'textBackground'):
            drawing.pop(field)
        drawing['fontName'] = None
        effect['name'] = None
        self.assertEqual(load_project(dump_project(PortableProject(data))).to_dict(), data)

    def test_all_mandatory_video_envelope_fields_are_required_and_never_defaulted(self):
        for field in ('version', 'mediaKind', 'mediaPath', 'sourceSHA256', 'producer', 'timeline', 'regions', 'drawings'):
            for operation in ('remove', 'null'):
                data = fixture()
                if operation == 'remove': del data[field]
                else: data[field] = None
                with self.subTest(field=field, operation=operation), self.assertRaises(ProjectError):
                    PortableProject(data)
        old = legacy_fixture(); old['version'] = 3
        with self.assertRaises(ProjectError):
            PortableProject(old)

    def test_v3_versions_kinds_paths_and_hashes_are_strict(self):
        for field, value in (('version', True), ('version', 3.0), ('version', '3'),
                             ('version', 4), ('mediaKind', 'image'), ('mediaKind', True),
                             ('mediaPath', ''), ('mediaPath', 'bad\0.mov'),
                             ('sourceSHA256', 'A' * 64), ('sourceSHA256', 'a' * 63),
                             ('sourceSHA256', 1), ('sourceSHA256', 'a' * 64 + '\n')):
            data = fixture(); data[field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ProjectError):
                load_project(json.dumps(data))

    def test_unknown_or_malformed_producer_and_clock_metadata_fail_closed(self):
        mutations = [lambda d: d['producer'].update(platform='unknown'),
                     lambda d: d['producer'].update(name='OtherApp'),
                     lambda d: d['producer'].update(version=''),
                     lambda d: d['producer'].update(version='0.8\n'),
                     lambda d: d['producer'].update(origin='inferred'),
                     lambda d: d['timeline'].update(version=1.0),
                     lambda d: d['timeline'].update(version=True),
                     lambda d: d['timeline'].update(basis='qt-origin'),
                     lambda d: d['timeline'].update(rawOrigin={'numerator': '0', 'denominator': '1'}),
                     lambda d: d['timeline']['tracks'][0].update(id=True),
                     lambda d: d['timeline']['tracks'][0].update(id=1.0),
                     lambda d: d['timeline']['tracks'][0].update(mediaTimescale=0),
                     lambda d: d['timeline']['tracks'][0]['segments'][0].update(assetStart=0.0),
                     lambda d: d['timeline']['assetDuration'].update(numerator='039'),
                     lambda d: d['timeline']['assetDuration'].update(numerator='9223372036854775808'),
                     lambda d: d['timeline']['assetDuration'].update(denominator='0')]
        for mutate in mutations:
            data = fixture(); mutate(data)
            with self.subTest(data=data), self.assertRaises(ProjectError):
                PortableProject(data)

    def test_segment_bounds_order_duplicate_ids_and_track_counts_are_checked(self):
        mutations = [lambda d: d['timeline']['tracks'][1].update(id=1),
                     lambda d: d['timeline']['tracks'].reverse(),
                     lambda d: d['timeline']['tracks'][1].update(kind='video'),
                     lambda d: d['timeline']['tracks'][0]['segments'][1]['assetStart'].update(numerator='1', denominator='1'),
                     lambda d: d['timeline']['tracks'][0]['segments'][1]['assetDuration'].update(numerator='3', denominator='1'),
                     lambda d: d['timeline']['tracks'][0]['segments'][0]['rate'].update(numerator='2'),
                     lambda d: d['timeline']['tracks'].clear(),
                     lambda d: d['timeline']['tracks'].__imul__(9),
                     lambda d: d['timeline']['tracks'][0]['segments'].__imul__(2049)]
        for mutate in mutations:
            data = fixture(); mutate(data)
            with self.subTest(data=data), self.assertRaises(ProjectError):
                PortableProject(data)

    def test_existing_edits_still_reject_duplicate_items_nonfinite_values_and_unknown_enums(self):
        mutations = [lambda d: d['drawings'][0].update(id=d['regions'][0]['shape']['rectangle']['id']),
                     lambda d: d['regions'][0]['effect'].update(enabled=1),
                     lambda d: d['regions'][0]['effect'].update(timeRange=[5, 2]),
                     lambda d: d['regions'][0]['effect'].update(style='futureCover'),
                     lambda d: d['drawings'][0].update(kind='futureDrawing'),
                     lambda d: d['drawings'][0].update(alpha=float('nan')),
                     lambda d: d['drawings'][0].update(lineWidth=float('inf')),
                     lambda d: d['regions'][0]['effect']['erasures'][0].update(**{'from': -.1}),
                     lambda d: d.update(futureExtension={'unknown': float('inf')})]
        for mutate in mutations:
            data = fixture(); mutate(data)
            with self.subTest(data=data), self.assertRaises(ProjectError):
                PortableProject(data)

    def test_duplicate_json_keys_at_root_and_inside_timeline_are_never_last_key_wins(self):
        raw = json.dumps(fixture())
        for payload in (raw.replace('"version": 3', '"version": 3, "version": 3', 1),
                        raw.replace('"basis": "asset-presentation"', '"basis": "asset-presentation", "basis": "asset-presentation"', 1),
                        raw.replace('"numerator": "39"', '"numerator": "39", "numerator": "39"', 1)):
            with self.assertRaisesRegex(ProjectError, 'duplicate JSON key'):
                load_project(payload)

    def test_v3_known_edit_counts_and_unknown_nesting_limits_cannot_be_bypassed(self):
        for field, count in (('regions', 1001), ('drawings', 5001)):
            data = fixture(); data[field] *= count
            with self.subTest(field=field), self.assertRaisesRegex(ProjectError, 'invalid array size/type'):
                PortableProject(data)
        nested = None
        for _ in range(66):
            nested = {'future': nested}
        data = fixture(); data['futureExtension'] = nested
        with self.assertRaisesRegex(ProjectError, 'nesting limit'):
            PortableProject(data)

    def test_v3_byte_limit_unknown_payload_and_native_grapheme_review_still_apply(self):
        self.assertEqual((MAX_V1_BYTES, MAX_V2_BYTES, MAX_V3_BYTES), (20 * 1024 ** 2, 50 * 1024 ** 2, 20 * 1024 ** 2))
        data = fixture(); data['futureExtension'] = 'x' * 4096
        project = PortableProject(data)
        with patch('shared.portable_project.MAX_V3_BYTES', 1024):
            with self.assertRaisesRegex(ProjectError, 'version byte limit'):
                load_project(json.dumps(data))
            with self.assertRaisesRegex(ProjectError, 'encoded project exceeds'):
                dump_project(project)
        data = fixture(); data['drawings'][0]['text'] = 'x' * 1001
        with self.assertRaises(ProjectError):
            PortableProject(data)
        data['drawings'][0]['text'] = 'e\u0301' * 700
        project = PortableProject(data)
        self.assertTrue(any('native grapheme-count' in reason for reason in project.required_reviews))
        self.assertEqual(load_project(dump_project(project)).to_dict(), data)

    def test_v1_v2_remain_original_versions_with_optional_hashes_and_page_sources(self):
        for version in (1, 2):
            data = legacy_fixture(version)
            project = load_project(dump_project(PortableProject(data)))
            self.assertEqual(project.to_dict(), data)
            self.assertEqual(project.version, version)
            self.assertEqual(len(project.sources), 1 if version == 1 else 2)
            if version == 1:
                self.assertIsNone(project.sources[0].expected_sha256)
            else:
                self.assertEqual(project.sources[1].expected_sha256, 'a' * 64)
                self.assertEqual(project.sources[1].pdf_geometry_version, 1)
        for version, limit in ((1, 'MAX_V1_BYTES'), (2, 'MAX_V2_BYTES')):
            with patch('shared.portable_project.' + limit, 64), self.assertRaises(ProjectError):
                dump_project(PortableProject(legacy_fixture(version)))

    def test_exclusive_writer_roundtrip_preserves_existing_project_and_never_reads_media(self):
        project = PortableProject(fixture())
        with patch('shared.portable_project.os.open', side_effect=AssertionError('JSON boundary opened media')):
            self.assertEqual(load_project(dump_project(project)).to_dict(), fixture())
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'new-video-v3.bluraction'
            save_project_new(project, path)
            before = path.read_bytes(); digest = hashlib.sha256(before).hexdigest()
            self.assertEqual(load_project(before).to_dict(), fixture())
            with self.assertRaises(FileExistsError):
                save_project_new(project, path)
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), digest)
            self.assertEqual(list(Path(temporary).iterdir()), [path])

    def test_schema_documents_separate_v3_exact_clock_without_replacing_legacy_definitions(self):
        schema = json.loads((Path(__file__).resolve().parents[2] / 'shared/bluraction-project.schema.json').read_text())
        self.assertEqual(schema['oneOf'], [{'$ref': '#/$defs/v1'}, {'$ref': '#/$defs/v2'}, {'$ref': '#/$defs/v3'}])
        definitions = schema['$defs']; v3 = definitions['v3']
        self.assertEqual(set(v3['required']), {'version', 'mediaKind', 'mediaPath', 'sourceSHA256', 'producer', 'timeline', 'regions', 'drawings'})
        self.assertEqual(v3['x-maxUTF8Bytes'], MAX_V3_BYTES)
        self.assertTrue(v3['additionalProperties'])
        self.assertEqual(v3['properties']['regions'], definitions['v1']['properties']['regions'])
        self.assertEqual(v3['properties']['drawings'], definitions['v1']['properties']['drawings'])
        self.assertEqual(definitions['v1']['x-maxUTF8Bytes'], MAX_V1_BYTES)
        self.assertEqual(definitions['v2']['x-maxUTF8Bytes'], MAX_V2_BYTES)
        self.assertFalse(definitions['videoTimeline']['additionalProperties'])
        self.assertFalse(definitions['rational']['additionalProperties'])
        self.assertEqual(definitions['videoTimeline']['properties']['tracks']['maxItems'], 17)
        # This is a schema readback, not execution of a third-party validator.


if __name__ == '__main__':
    unittest.main()
