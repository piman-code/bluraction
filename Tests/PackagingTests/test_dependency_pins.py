"""Injected metadata only; no installed runtime/native package proof."""
from contextlib import redirect_stdout
import hashlib
from importlib import metadata
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from platforms.windows import verify_dependency_pins as pins


class DependencyPinTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='bluraction-pin-test-')
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)

    def requirements(self, text, name='requirements.txt'):
        path = self.folder / name
        path.write_text(text, encoding='utf-8')
        return path

    def provider(self, versions):
        def lookup(name):
            if name not in versions:
                raise metadata.PackageNotFoundError(name)
            return versions[name]
        return lookup

    def test_exact_runtime_and_packaging_pins_comments_and_blanks_match(self):
        dev = self.requirements('# 개발\n\n PySide6==6.11.1\nPillow == 12.3.0  # source pin\nnumpy==2.3.5\n', 'dev.txt')
        packaging = self.requirements('PyInstaller==6.22.3\n', 'packaging.txt')
        calls = []
        versions = {'pyside6': '6.11.1', 'pillow': '12.3.0', 'numpy': '2.3.5', 'pyinstaller': '6.22.3'}
        def lookup(name):
            calls.append(name)
            return versions[name]
        report = pins.verify_pins([dev, packaging], version_provider=lookup)
        self.assertTrue(report['ok'])
        self.assertEqual(report['exitCode'], 0)
        self.assertEqual(report['errors'], [])
        self.assertEqual(calls, list(versions))
        self.assertTrue(all(row['actual'] == row['expected'] and row['status'] == 'match'
                            for row in report['packages']))
        self.assertFalse(report['runtimeFunctionalityVerified'])
        self.assertFalse(report['nativePackagesImported'])
        self.assertEqual(report['scope'], 'distribution-metadata-only')

    def test_pillow_old_global_version_mismatch_is_not_hidden_by_presence(self):
        path = self.requirements('Pillow==12.3.0\n')
        report = pins.verify_pins([path], version_provider=self.provider({'pillow': '12.2.0'}))
        self.assertFalse(report['ok'])
        self.assertNotEqual(report['exitCode'], 0)
        row = report['packages'][0]
        self.assertEqual((row['expected'], row['actual'], row['status']), ('12.3.0', '12.2.0', 'mismatch'))
        self.assertEqual(report['errors'][0]['type'], 'mismatch')

    def test_all_missing_mismatch_and_provider_failures_are_reported_together(self):
        path = self.requirements('Pillow==12.3.0\nav==19.0.0\nnumpy==2.3.5\npypdf==6.19.0\n')
        def lookup(name):
            if name == 'av':
                raise metadata.PackageNotFoundError(name)
            if name == 'pypdf':
                raise ValueError('invalid distribution metadata')
            return {'pillow': '12.2.0', 'numpy': '2.3.5'}[name]
        report = pins.verify_pins([path], version_provider=lookup)
        self.assertEqual([row['status'] for row in report['packages']], ['mismatch', 'missing', 'match', 'metadata_error'])
        self.assertEqual([error['type'] for error in report['errors']], ['mismatch', 'missing', 'metadata_error'])
        self.assertIsNone(report['packages'][1]['actual'])
        self.assertFalse(report['ok'])

    def test_unsupported_and_malformed_requirement_language_is_explicit_error(self):
        invalid = ['Pillow>=12.3.0', 'Pillow==12.3.*', 'Pillow==12.3.0; python_version>="3.14"',
            'Pillow[extra]==12.3.0', 'Pillow @ https://example.invalid/p.whl', '-r other.txt',
            '--index-url https://example.invalid', 'Pillow===12.3.0', 'Pillow==', '==12.3.0',
            'Pillow==broken', 'Pillow==1..2', 'Pillow==12.3.0#attached', 'Pillow==12.3.0 numpy==2.3.5',
            'Pillow==12.3.0 \\', 'Pillow.==12.3.0']
        path = self.requirements('\n'.join(invalid) + '\n')
        with patch.object(pins.metadata, 'version', side_effect=AssertionError('must not resolve malformed pins')):
            report = pins.verify_pins([path])
        self.assertFalse(report['ok'])
        self.assertEqual(report['packages'], [])
        self.assertEqual(len(report['errors']), len(invalid))
        self.assertTrue(all(error['type'] == 'requirements_syntax' for error in report['errors']))
        self.assertEqual([error['line'] for error in report['errors']], list(range(1, len(invalid) + 1)))

    def test_duplicate_names_are_normalized_across_files_and_never_approved(self):
        dev = self.requirements('Pillow-Heif==1.8.0\n', 'dev.txt')
        other = self.requirements('pillow_heif==1.8.0\npillow.heif==1.9.0\n', 'other.txt')
        report = pins.verify_pins([dev, other], version_provider=self.provider({'pillow-heif': '1.8.0'}))
        self.assertFalse(report['ok'])
        self.assertEqual(len(report['packages']), 1)
        self.assertEqual([error['type'] for error in report['errors']], ['duplicate', 'duplicate'])
        self.assertEqual(report['errors'][1]['previousExpected'], '1.8.0')
        self.assertEqual(report['errors'][1]['expected'], '1.9.0')
        self.assertEqual(report['errors'][0]['previousSource'], str(dev))

    def test_empty_runtime_file_cannot_be_hidden_by_matching_packaging_pins(self):
        packaging = self.requirements('PyInstaller==6.22.3\n', 'packaging.txt')
        for content in ('', ' \n\n # comments alone declare no pins\n'):
            dev = self.requirements(content, 'dev.txt')
            report = pins.verify_pins([dev, packaging],
                version_provider=self.provider({'pyinstaller': '6.22.3'}))
            self.assertFalse(report['ok'])
            self.assertEqual(report['packages'][0]['status'], 'match')
            self.assertEqual(report['errors'][0]['type'], 'requirements_empty')
            self.assertEqual(report['errors'][0]['source'], str(dev))
            self.assertFalse(pins.verify_pins([dev], version_provider=self.provider({}))['ok'])

    def test_exact_versions_are_not_silently_normalized_or_rounded(self):
        path = self.requirements('example==1.0.0\n')
        for actual in ('1.0', '1.0.0+local', ' 1.0.0', '1.0.0 '):
            with self.subTest(actual=actual):
                report = pins.verify_pins([path], version_provider=self.provider({'example': actual}))
                self.assertEqual(report['packages'][0]['status'], 'mismatch')

    def test_missing_unreadable_and_invalid_utf8_files_do_not_hide_other_checks(self):
        valid = self.requirements('numpy==2.3.5\n')
        bad = self.folder / 'invalid.txt'; bad.write_bytes(b'\xff\xfe')
        missing = self.folder / 'absent.txt'
        report = pins.verify_pins([missing, self.folder, bad, valid],
            version_provider=self.provider({'numpy': '2.3.5'}))
        self.assertEqual([error['type'] for error in report['errors']], ['requirements_read'] * 3)
        self.assertEqual(report['packages'][0]['status'], 'match')
        self.assertFalse(report['ok'])
        self.assertFalse(pins.verify_pins([], version_provider=self.provider({}))['ok'])

    def test_invalid_provider_results_fail_metadata_check(self):
        path = self.requirements('numpy==2.3.5\n')
        for actual in (None, 235, ''):
            with self.subTest(actual=actual):
                report = pins.verify_pins([path], version_provider=self.provider({'numpy': actual}))
                self.assertFalse(report['ok'])
                self.assertEqual(report['packages'][0]['status'], 'metadata_error')
                self.assertIsNone(report['packages'][0]['actual'])

    def test_cli_reports_json_nonzero_and_does_not_mutate_global_or_file_state(self):
        dev = self.requirements('Pillow==12.3.0\n', 'dev.txt')
        packaging = self.requirements('PyInstaller==6.22.3\n', 'packaging.txt')
        argv = ['--requirements', str(dev), '--requirements', str(packaging)]
        original_argv = list(argv)
        before = (os.getcwd(), dict(os.environ), list(sys.path),
            {path: (hashlib.sha256(path.read_bytes()).hexdigest(), path.stat().st_mtime_ns)
             for path in (dev, packaging)})
        output = io.StringIO()
        with redirect_stdout(output), patch.object(pins.metadata, 'version',
                side_effect=self.provider({'pillow': '12.2.0', 'pyinstaller': '6.22.3'})):
            exit_code = pins.main(argv)
        report = json.loads(output.getvalue())
        self.assertEqual(exit_code, report['exitCode'])
        self.assertNotEqual(exit_code, 0)
        self.assertEqual([row['status'] for row in report['packages']], ['mismatch', 'match'])
        self.assertEqual(argv, original_argv)
        after = (os.getcwd(), dict(os.environ), list(sys.path),
            {path: (hashlib.sha256(path.read_bytes()).hexdigest(), path.stat().st_mtime_ns)
             for path in (dev, packaging)})
        self.assertEqual(after, before)


if __name__ == '__main__':
    unittest.main()
