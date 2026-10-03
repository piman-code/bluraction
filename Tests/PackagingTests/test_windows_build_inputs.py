"""Authored input-evidence contracts; never native Windows execution evidence."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from scripts.collect_windows_build_inputs import collect, main
from shared.windows_package_receipt import PINS


class WindowsBuildInputsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.wheels = self.root / 'wheels'
        self.wheels.mkdir()
        self.report = self.root / 'report.json'
        self.rows = []
        for name, version in PINS.items():
            filename = name.replace('-', '_') + '-' + version + '-py3-none-any.whl'
            path = self.wheels / filename
            meta = name.replace('-', '_') + '-' + version + '.dist-info/'
            with zipfile.ZipFile(path, 'w') as archive:
                archive.writestr(meta + 'METADATA', f'Name: {name}\nVersion: {version}\n')
                archive.writestr(meta + 'WHEEL', 'Wheel-Version: 1.0\nTag: py3-none-any\n')
            self.rows.append({'metadata': {'name': name, 'version': version}, 'download_info': {
                'url': path.as_uri(), 'archive_info': {'hashes': {'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}}}})
        self.write()
        self.runtime = {'host': 'win32', 'version': '3.14.8', 'implementation': 'cpython',
                        'cache_tag': 'cpython-314', 'architecture': 'amd64', 'gil_disabled': False,
                        'executable_sha256': 'a' * 64, 'distributions': dict(PINS)}

    def write(self):
        self.report.write_text(json.dumps({'version': '1', 'install': self.rows}))

    def observe(self):
        return collect(self.wheels, self.report, self.runtime)

    def test_complete_observation_is_pending_and_contains_no_paths(self):
        result = self.observe()
        self.assertEqual(len(result['wheels']), len(PINS))
        self.assertEqual(result['release_review'], 'pending')
        self.assertNotIn(str(self.root), json.dumps(result))
        self.assertNotIn('file:', json.dumps(result))

    def test_nonwindows_is_rejected(self):
        self.runtime['host'] = 'darwin'
        with self.assertRaises(ValueError): self.observe()

    def test_modified_wheel_rejected(self):
        next(self.wheels.iterdir()).write_bytes(b'changed')
        with self.assertRaises(ValueError): self.observe()

    def test_missing_required_and_duplicate_selection_rejected(self):
        for change in ('missing', 'duplicate'):
            with self.subTest(change=change):
                original = list(self.rows)
                self.rows = original[:-1] if change == 'missing' else original + [original[0]]
                self.write()
                with self.assertRaises(ValueError): self.observe()
                self.rows = original

    def test_installed_metadata_drift_rejected(self):
        self.runtime['distributions']['pillow'] = '0.0'
        with self.assertRaises(ValueError): self.observe()

    def test_credential_url_and_encoded_traversal_rejected(self):
        for url in ('https://user:password@example.org/test.whl',
                    'https://example.org/test.whl?secret=value',
                    'https://example.org/%2e%2e%2ftest.whl'):
            with self.subTest(url=url):
                self.rows[0]['download_info']['url'] = url
                self.write()
                with self.assertRaises(ValueError): self.observe()

    def test_unreported_input_rejected(self):
        extra = self.wheels / 'extra.whl'
        extra.write_bytes(b'not reported')
        with self.assertRaises(ValueError): self.observe()

    def test_symlink_input_rejected(self):
        selected = next(self.wheels.iterdir())
        saved = self.root / 'saved.whl'
        selected.rename(saved)
        try:
            selected.symlink_to(saved)
        except OSError as error:
            self.skipTest(f'Host does not permit creating symlinks: {type(error).__name__}')
        with self.assertRaises(ValueError): self.observe()

    def test_cli_exclusive_output_and_runtime_observation(self):
        output = self.root / 'evidence.json'
        args = ['--wheelhouse', str(self.wheels), '--pip-report', str(self.report), '--output', str(output)]
        with patch('scripts.collect_windows_build_inputs.runtime_observation', return_value=self.runtime):
            self.assertEqual(main(args), 0)
            original = output.read_bytes()
            with self.assertRaises(ValueError): main(args)
            self.assertEqual(output.read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
