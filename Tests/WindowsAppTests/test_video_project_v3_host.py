"""Shared v3 handoff safety only; actual host video clock integration is pending."""
from copy import deepcopy
import hashlib
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from shared.portable_project import PortableProject, ProjectError, dump_project
from shared.source_relink import check_source, resolve_reference, relink_media
from Tests.PortableProjectTests.test_video_project_v3 import fixture
from platforms.windows.bluraction.project_compatibility import validate_host_reviews
from platforms.windows.bluraction.editor import Workspace


class VideoProjectV3HostTests(unittest.TestCase):
    def test_v3_grapheme_review_uses_top_level_video_without_mutation(self):
        tree = fixture()
        tree['drawings'][0]['text'] = '\u1100\u1161\u11a8' * 1000
        project = PortableProject(tree)
        self.assertTrue(project.required_reviews)
        self.assertEqual(validate_host_reviews(project), ())
        self.assertEqual(project.to_dict(), tree)
        tree['drawings'][0]['text'] += 'x'
        with self.assertRaises(ProjectError): validate_host_reviews(PortableProject(tree))

    def test_v3_relink_verifies_selected_bytes_and_changes_only_media_path(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); source = root / 'replacement.mov'
            source.write_bytes(b'authored byte identity only; never decoded as media')
            tree = fixture(); tree['sourceSHA256'] = hashlib.sha256(source.read_bytes()).hexdigest()
            project = PortableProject(tree)
            platform = 'windows' if os.name == 'nt' else 'macos'
            location = str(root/'project.bluraction')
            resolution = resolve_reference(source.name, location, platform)
            checked = check_source(resolution, tree['sourceSHA256'], approved_roots=[root])
            self.assertEqual(checked.state, 'verified')
            relinked = relink_media(project, tree['mediaPath'], source.name,
                project_location=location, platform=platform, checked=checked)
            expected = deepcopy(tree); expected['mediaPath'] = source.name
            self.assertEqual(relinked.to_dict(), expected)
            self.assertEqual(project.to_dict(), tree)
            self.assertEqual(relinked.sources[0].expected_sha256, tree['sourceSHA256'])

    def test_current_origin_relative_host_holds_v3_before_source_reads_or_session_change(self):
        workspace = Workspace()
        workspace.title = 'keep dirty session'; workspace.dirty = True
        workspace.selection_ids = {'preserved-selection'}
        workspace._undo = {'preserved': [1, 2]}
        before = deepcopy(workspace.__dict__)
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'video-v3.bluraction'; path.write_bytes(dump_project(PortableProject(fixture())))
            with patch('platforms.windows.bluraction.editor.fingerprint', side_effect=AssertionError('v3 must be held before source access')):
                with self.assertRaisesRegex(ValueError, '시간축 연결 검수'):
                    workspace.load_project(path)
        self.assertEqual(workspace.__dict__, before)
