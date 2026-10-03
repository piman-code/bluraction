"""Synthetic PE/archive tests; not actual Windows or license evidence."""
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from shared import windows_bundle_inventory as subject


def sha(data):
    return hashlib.sha256(data).hexdigest()


class BundleInventoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir='/private/tmp' if sys.platform == 'darwin' else None)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bundle = self.root / 'BlurAction'
        self.artifacts = self.root / 'artifacts'
        self.bundle.mkdir()
        self.artifacts.mkdir()
        header = bytearray(100)
        header[:2] = b'MZ'
        struct.pack_into('<I', header, 60, 64)
        header[64:70] = b'PE\0\0\x64\x86'
        self.pe = bytes(header)
        (self.bundle / 'BlurAction.exe').write_bytes(self.pe + b'app')
        (self.bundle / 'Qt6Pdf.dll').write_bytes(self.pe)
        (self.bundle / 'python314.dll').write_bytes(self.pe + b'python')
        self.wheel = self.artifacts / 'fixture.whl'
        with zipfile.ZipFile(self.wheel, 'w') as archive:
            archive.writestr('fixture-1.dist-info/METADATA', 'Name: fixture\nVersion: 1\n')
            archive.writestr('fixture-1.dist-info/WHEEL', 'Wheel-Version: 1.0\nTag: py3-none-any\n')
            archive.writestr('fixture/Qt6Pdf.dll', self.pe)
        runtime = self.artifacts / 'python314.dll'
        runtime.write_bytes(self.pe + b'python')
        def row(path, identity, kind):
            return {'id': identity, 'kind': kind, 'path': path.name,
                    'bytes': path.stat().st_size, 'sha256': sha(path.read_bytes())}
        self.rows = [dict(row(self.wheel, 'fixture', 'wheel'), distribution='fixture', version='1', provider='official-wheel'),
                     row(runtime, 'python-dll', 'runtime')]
        self.receipt = self.root / 'receipt.json'
        self.manifest = self.root / 'manifest.json'
        self.refresh()

    def refresh(self):
        self.receipt.write_text(json.dumps({'artifacts': self.rows}))
        self.manifest.write_text(json.dumps([{'path': 'BlurAction/' + f.name, 'sha256': sha(f.read_bytes())}
                                              for f in self.bundle.iterdir()]))

    def inspect(self):
        return subject.inspect(self.bundle, self.manifest, self.receipt, self.artifacts)

    def test_matches_and_unresolved_product_are_observations(self):
        report = self.inspect()
        entries = {row['path']: row for row in report['native_files']}
        self.assertEqual(entries['Qt6Pdf.dll']['provider_matches'], [{'artifact_id': 'fixture', 'kind': 'wheel', 'member': 'fixture/Qt6Pdf.dll'}])
        self.assertEqual(entries['python314.dll']['provider_status'], 'exact')
        self.assertEqual(entries['BlurAction.exe']['provider_status'], 'unresolved')
        self.assertTrue(entries['BlurAction.exe']['generated_product_executable'])
        self.assertFalse(report['redistribution_approved'])
        self.assertEqual(report['qt_license_review_filename_leads'], ['Qt6Pdf.dll'])
        self.assertNotIn(str(self.root), json.dumps(report))

    def test_ambiguous_hash_not_chosen(self):
        other = self.artifacts / 'same.dll'
        other.write_bytes(self.pe)
        self.rows.append({'id': 'other', 'kind': 'runtime', 'path': other.name, 'bytes': len(self.pe), 'sha256': sha(self.pe)})
        self.refresh()
        item = next(x for x in self.inspect()['native_files'] if x['path'] == 'Qt6Pdf.dll')
        self.assertEqual(item['provider_status'], 'ambiguous')
        self.assertEqual(len(item['provider_matches']), 2)

    def test_arm64_and_extensionless_pe_are_observed(self):
        data = bytearray(self.pe)
        data[68:70] = b'\x64\xaa'
        (self.bundle / 'helper').write_bytes(data)
        self.refresh()
        item = next(x for x in self.inspect()['native_files'] if x['path'] == 'helper')
        self.assertEqual(item['machine'], 'arm64')

    def test_manifest_drift_rejected(self):
        (self.bundle / 'Qt6Pdf.dll').write_bytes(self.pe + b'drift')
        with self.assertRaises(ValueError): self.inspect()

    def test_unlisted_file_rejected(self):
        (self.bundle / 'extra.txt').write_text('extra')
        with self.assertRaises(ValueError): self.inspect()

    def test_acquired_artifact_drift_rejected(self):
        self.wheel.write_bytes(b'changed')
        with self.assertRaises(ValueError): self.inspect()

    def test_duplicate_artifact_rejected(self):
        self.rows.append(self.rows[0])
        self.refresh()
        with self.assertRaises(ValueError): self.inspect()

    def test_symlink_rejected(self):
        try:
            (self.bundle / 'link').symlink_to(self.bundle / 'Qt6Pdf.dll')
        except OSError:
            self.skipTest('symlink creation unavailable')
        with self.assertRaises(ValueError): self.inspect()

    def test_mid_scan_mutation_rejected(self):
        original = subject.receipt_tools.member_sha
        def changing(archive, member):
            result = original(archive, member)
            (self.bundle / 'Qt6Pdf.dll').write_bytes(self.pe + b'mutation')
            return result
        with patch.object(subject.receipt_tools, 'member_sha', changing):
            with self.assertRaises(ValueError): self.inspect()

    def test_cli_refuses_overwrite_and_rejects_without_output(self):
        output = self.root / 'report.json'
        args = [sys.executable, str(Path(subject.__file__)), '--bundle', str(self.bundle), '--bundle-manifest', str(self.manifest),
                '--receipt', str(self.receipt), '--artifacts-root', str(self.artifacts), '--output', str(output)]
        first = subprocess.run(args, capture_output=True, timeout=10)
        self.assertEqual(first.returncode, 0, first.stderr)
        prior = output.read_bytes()
        second = subprocess.run(args, capture_output=True, timeout=10)
        self.assertNotEqual(second.returncode, 0)
        self.assertEqual(output.read_bytes(), prior)
        args[-1] = str(self.root / 'rejected.json')
        self.wheel.write_bytes(b'changed')
        failed = subprocess.run(args, capture_output=True, timeout=10)
        self.assertEqual(failed.returncode, 1)
        self.assertFalse(Path(args[-1]).exists())
        self.assertNotIn(str(self.root).encode(), failed.stderr)


if __name__ == '__main__':
    unittest.main()
