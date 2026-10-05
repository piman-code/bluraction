"""Authored literal TOC/PE tests; no actual PyInstaller/Windows execution."""
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('bundle_origins', Path(__file__).resolve().parents[2] / 'scripts/collect_windows_bundle_origins.py')
subject = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(subject)


class BundleOriginsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir='/private/tmp' if sys.platform == 'darwin' else None)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bundle = self.root / 'BlurAction'
        (self.bundle / '_internal').mkdir(parents=True)
        self.base = self.root / 'python-base'
        self.base.mkdir()
        pe = bytearray(96)
        pe[:2] = b'MZ'
        struct.pack_into('<I', pe, 60, 64)
        pe[64:70] = b'PE\0\0\x64\x86'
        self.pe = bytes(pe)
        self.native = self.base / 'libssl-3.dll'
        self.native.write_bytes(self.pe)
        (self.bundle / '_internal/libssl-3.dll').write_bytes(self.pe)
        self.exe = self.root / 'BlurAction.exe'
        self.exe.write_bytes(self.pe + b'app')
        (self.bundle / 'BlurAction.exe').write_bytes(self.exe.read_bytes())
        self.rows = [('libssl-3.dll', str(self.native), 'BINARY')]
        self.analysis = self.root / 'Analysis-00.toc'
        self.collect = self.root / 'COLLECT-00.toc'
        self.save()

    def save(self):
        fields = [None] * 20
        fields[15] = self.rows
        self.analysis.write_text(repr(tuple(fields)))
        self.collect.write_text(repr((self.rows + [('BlurAction.exe', str(self.exe), 'EXECUTABLE')],)))

    def observe(self):
        return subject.observe(self.analysis, self.bundle, roots={'python-base': self.base})

    def test_collect_native_and_generated_executable_exact(self):
        report = self.observe()
        self.assertEqual(report['native_file_count'], 2)
        self.assertEqual({x['source_status'] for x in report['native_files']}, {'exact-bytes'})
        ssl = next(x for x in report['native_files'] if x['path'].endswith('.dll'))
        self.assertTrue(ssl['analysis_source_agrees'])
        self.assertEqual(ssl['source'], {'classification': 'python-base', 'relative_path': 'libssl-3.dll'})
        self.assertEqual(ssl['machine'], 'amd64')
        self.assertNotIn(str(self.root), json.dumps(report))

    def test_modified_copy_not_exact(self):
        (self.bundle / '_internal/libssl-3.dll').write_bytes(self.pe + b'processed')
        ssl = next(x for x in self.observe()['native_files'] if x['path'].endswith('.dll'))
        self.assertEqual(ssl['source_status'], 'different-bytes')

    def test_literal_call_not_executed(self):
        marker = self.root / 'pwned'
        self.analysis.write_text(f"__import__('pathlib').Path({str(marker)!r}).touch()")
        with self.assertRaises(ValueError): self.observe()
        self.assertFalse(marker.exists())

    def test_wrong_schema_refused(self):
        self.analysis.write_text(repr(tuple([None] * 19)))
        with self.assertRaises(ValueError): self.observe()

    def test_traversal_and_duplicate_destinations_refused(self):
        self.rows.append(('../bad.dll', str(self.native), 'BINARY'))
        self.save()
        with self.assertRaises(ValueError): self.observe()
        self.rows[-1] = ('LIBSSL-3.DLL', str(self.native), 'BINARY')
        self.save()
        with self.assertRaises(ValueError): self.observe()

    def test_missing_source_reports_unavailable(self):
        self.rows[0] = ('libssl-3.dll', str(self.root / 'missing.dll'), 'BINARY')
        self.save()
        row = next(x for x in self.observe()['native_files'] if x['path'].endswith('.dll'))
        self.assertEqual(row['source_status'], 'source-unavailable-or-rejected')
        self.assertEqual(row['source'], {'classification': 'other', 'basename': 'missing.dll'})

    def test_analysis_only_preserves_unmapped_product(self):
        self.collect.unlink()
        report = self.observe()
        self.assertEqual(report['authority'], 'Analysis-00.toc')
        exe = next(x for x in report['native_files'] if x['path'] == 'BlurAction.exe')
        self.assertEqual(exe['source_status'], 'no-toc-entry')

    def test_known_root_classification_prefers_specific(self):
        roots = {'python-base': self.root, 'venv': self.base}
        self.assertEqual(subject.source_label(self.native, roots)['classification'], 'venv')
        self.assertEqual(subject.source_label(self.native, {'SystemRoot': self.base})['classification'], 'SystemRoot')

    def test_source_drift_refused(self):
        original = subject.machine
        calls = 0
        def change(path):
            nonlocal calls
            result = original(path)
            if Path(path) == self.native:
                self.native.write_bytes(self.pe + b'changed')
            return result
        with patch.object(subject, 'machine', change):
            with self.assertRaises(ValueError): self.observe()

    def test_cli_fresh_output_no_absolute_paths(self):
        output = self.root / 'report.json'
        args = [sys.executable, str(subject.__file__), '--analysis', str(self.analysis), '--bundle', str(self.bundle), '--output', str(output)]
        result = subprocess.run(args, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(str(self.root), output.read_text())
        prior = output.read_bytes()
        result = subprocess.run(args, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(output.read_bytes(), prior)


if __name__ == '__main__':
    unittest.main()
