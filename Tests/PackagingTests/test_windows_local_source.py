"""Authored local snapshot checks; no Git or native Windows execution."""
import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from scripts import package_windows_local_source as subject
from shared import windows_package_receipt as gate


class LocalSourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.root = self.base / 'source'
        self.root.mkdir()
        for name in gate.SOURCE_REQUIRED:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('# authored source\n')
        pins = {k: v for k, v in gate.PINS.items()
                if k not in {'pyside6-addons', 'pyside6-essentials', 'shiboken6'}}
        (self.root / 'platforms/windows/requirements-dev.txt').write_text(
            '\n'.join(f'{k}=={v}' for k, v in pins.items() if k != 'pyinstaller') + '\n')
        (self.root / 'platforms/windows/installer/requirements-packaging.txt').write_text(
            'pyinstaller==' + pins['pyinstaller'] + '\n')
        self.rows = [self.row(name) for name in sorted(gate.SOURCE_REQUIRED)]
        self.file_list = self.base / 'reviewed.json'
        self.output = self.base / 'output'

    def row(self, name):
        data = (self.root / name).read_bytes()
        return dict(path=name, bytes=len(data), sha256=hashlib.sha256(data).hexdigest())

    def run_package(self, output=None):
        self.file_list.write_text(json.dumps(dict(schema_version=1, files=self.rows)))
        return subject.package(source_root=self.root, file_list=self.file_list,
                               output=output or self.output)

    def test_deterministic_exact_census_without_private_files(self):
        (self.root / 'private-user.txt').write_text('never selected')
        result = self.run_package()
        other = self.base / 'other'
        self.run_package(other)
        self.assertEqual((self.output / 'source.zip').read_bytes(), (other / 'source.zip').read_bytes())
        self.assertEqual(result['release_review'], 'pending')
        self.assertNotIn('commit', result['app_source'])
        with zipfile.ZipFile(self.output / 'source.zip') as archive:
            self.assertEqual(set(archive.namelist()), gate.SOURCE_REQUIRED)
            self.assertEqual(archive.comment, subject.COMMENT_PREFIX + result['source_manifest']['sha256'].encode())
        self.assertNotIn(str(self.root), (self.output / 'source-evidence.json').read_text())

    def test_reviewed_bytes_tamper_rejected_before_output(self):
        (self.root / 'LICENSE').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'changed'):
            self.run_package()
        self.assertFalse(self.output.exists())

    def test_existing_output_preserved(self):
        self.output.mkdir()
        sentinel = self.output / 'saved.txt'
        sentinel.write_text('keep')
        with self.assertRaisesRegex(ValueError, 'fresh'):
            self.run_package()
        self.assertEqual(sentinel.read_text(), 'keep')

    def test_private_traversal_binary_and_platform_paths_rejected(self):
        for name in ('.git/config', '.build/file.py', 'shared/qa-one/test.py',
                     'shared/Backups/test.py', 'shared/원본/test.json',
                     '../LICENSE', '/tmp/LICENSE', 'shared/../LICENSE',
                     'platforms/windows/test.exe', 'Sources/main.swift',
                     'shared/file.png', 'shared/CON.txt'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                subject.allowed_path(name)

    def test_preflight_dependency_text_paths_are_explicitly_eligible(self):
        for name in ('.gitattributes', 'scripts/verify_mac.py',
                     'scripts/diagnose_image_io.py', 'scripts/diagnose_image_io.swift',
                     'scripts/video-project-roundtrip/run_stage.py', 'scripts/test.sh',
                     'build-recipes/macos-heic-cpu/build_recipe.py',
                     'build-recipes/macos-heic-cpu/heic_cpu_candidate.cpp',
                     'build-recipes/macos-heic-cpu/NativeReadback.swift',
                     'build-recipes/macos-heic-cpu/README.md',
                     'Tests/VerificationRunnerTests/test_roundtrip_stage_contract.py'):
            with self.subTest(name=name):
                self.assertEqual(subject.allowed_path(name), name)
        for name in ('.git/config', '.github/workflows/verify.yml',
                     'build-recipes/unreviewed/code.py',
                     'build-recipes/macos-heic-cpu/unreviewed.cpp',
                     'build-recipes/macos-heic-cpu/library.dylib',
                     'build-recipes/macos-heic-cpu/source.tar.gz'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                subject.allowed_path(name)

    def test_case_collision_rejected(self):
        name = 'shared/sample.py'
        (self.root / name).write_text('# authored\n')
        row = self.row(name)
        self.rows.extend((row, dict(row, path='shared/SAMPLE.py')))
        with self.assertRaisesRegex(ValueError, 'case-colliding'):
            self.run_package()

    def test_duplicate_rejected(self):
        self.rows.append(dict(self.rows[0]))
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            self.run_package()

    def test_symlink_selected_file_rejected(self):
        path = self.root / 'LICENSE'
        original = Path.lstat
        def controlled_link(candidate, *args, **kwargs):
            value = original(candidate, *args, **kwargs)
            if candidate == path:
                fields = list(value)
                fields[0] = stat.S_IFLNK | 0o777
                return os.stat_result(fields)
            return value
        # Exercise the path guard without requiring Windows symlink privileges.
        with patch.object(Path, 'lstat', controlled_link):
            with self.assertRaisesRegex(ValueError, 'symlink'):
                self.run_package()

    def test_disguised_native_rejected(self):
        (self.root / 'LICENSE').write_bytes(b'MZ executable disguised as license')
        self.rows = [self.row(row['path']) for row in self.rows]
        with self.assertRaisesRegex(ValueError, 'compiled'):
            self.run_package()

    def test_missing_required_input_has_no_success_evidence(self):
        self.rows = [row for row in self.rows if row['path'] != 'LICENSE']
        with self.assertRaises(ValueError):
            self.run_package()
        self.assertFalse((self.output / 'source-evidence.json').exists())

    def test_source_changes_after_archive_are_rejected(self):
        real = gate.source_identity
        def mutate(*args, **kwargs):
            real(*args, **kwargs)
            (self.root / 'LICENSE').write_text('changed after archive')
        with patch.object(gate, 'source_identity', side_effect=mutate):
            with self.assertRaisesRegex(ValueError, 'changed'):
                self.run_package()
        self.assertFalse((self.output / 'source-evidence.json').exists())

    def test_binary_fixture_only_when_explicitly_selected(self):
        name = 'shared/fixtures/authored-test.png'
        path = self.root / name
        path.parent.mkdir(parents=True)
        path.write_bytes(b'\x89PNG\r\n\x1a\n\x00authored fixture')
        self.rows.append(self.row(name))
        self.run_package()
        with zipfile.ZipFile(self.output / 'source.zip') as archive:
            self.assertEqual(archive.read(name), path.read_bytes())

    def test_empty_source_module_supported(self):
        name = 'shared/__init__.py'
        (self.root / name).write_bytes(b'')
        self.rows.append(self.row(name))
        self.run_package()


if __name__ == '__main__':
    unittest.main()
