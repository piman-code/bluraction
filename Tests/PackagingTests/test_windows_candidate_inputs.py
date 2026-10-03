"""Authored PE/archive tests only; not actual Windows execution evidence."""
import json
from pathlib import Path
import shutil
import unittest
from unittest.mock import patch
import zipfile

from Tests.PackagingTests import test_windows_package_receipt as fixtures
from scripts import create_windows_candidate_inputs as subject
from shared import windows_package_receipt as gate


class CandidateInputsTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.WindowsReceiptTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        f = self.fixture
        self.root = f.root
        self.wheelhouse = self.root / 'wheels'
        self.wheelhouse.mkdir()
        self.runtime = dict(f.runtime, distributions=dict(f.runtime['distributions']))
        self.runtime_root = self.root / 'runtime-home'
        (self.runtime_root / 'DLLs').mkdir(parents=True)
        (self.runtime_root / 'python314.dll').write_bytes(f.native + b'authored runtime')
        (self.runtime_root / 'DLLs/_ssl.pyd').write_bytes(f.native + b'authored extension')
        (self.runtime_root / 'Lib/site-packages').mkdir(parents=True)
        (self.runtime_root / 'Lib/site-packages/private.dll').write_bytes(b'not a selected runtime file')
        for path in f.artifacts.glob('*.whl'):
            shutil.copyfile(path, self.wheelhouse / path.name)
        # Six additional transitive packages: the generator must preserve every
        # reported wheel, not just the eleven direct/core pins.
        for name in ('altgraph', 'packaging', 'pefile', 'pyinstaller-hooks-contrib', 'pywin32-ctypes', 'setuptools'):
            f.write_wheel(self.wheelhouse / (name + '.whl'), name, '1.0', tag='py3-none-any')
            self.runtime['distributions'][name] = '1.0'
        self.report = self.root / 'pip-report.json'
        rows = []
        for path in sorted(self.wheelhouse.iterdir()):
            name = path.stem
            rows.append(dict(metadata=dict(name=name, version=self.runtime['distributions'][name]),
                download_info=dict(url=path.as_uri(), archive_info=dict(hashes=dict(sha256=gate.sha(path))))))
        self.report.write_text(json.dumps(dict(version='1', install=rows)))
        with zipfile.ZipFile(f.source_zip, 'a') as archive:
            archive.comment = b'c' * 40
        self.output = self.root / 'candidate'
        self.args = dict(wheelhouse=self.wheelhouse, pip_report=self.report,
                         materials_root=f.materials, source_archive=f.source_zip,
                         commit='c' * 40, source_root=f.source, output=self.output,
                         runtime=self.runtime, executable=f.artifacts / 'python.exe',
                         runtime_root=self.runtime_root)

    def create(self):
        return subject.create(**self.args)

    def test_all_seventeen_wheels_runtime_materials_and_prepare_gate(self):
        result = self.create()
        self.assertEqual(result['wheel_count'], 17)
        receipt = gate.read_json(self.output / 'candidate-inputs.json')
        self.assertEqual(receipt['phase'], 'candidate-inputs')
        checked = gate.validate_receipt(receipt, artifacts_root=self.output / 'artifacts',
            materials_root=self.output / 'materials', source_root=self.fixture.source,
            runtime_observation=self.runtime)
        self.assertTrue(checked['ok'], checked)
        self.assertFalse(result['redistribution_approved'])
        self.assertFalse(result['frozen_execution_verified'])
        self.assertEqual(len([r for r in receipt['artifacts'] if r['kind'] == 'runtime']), 3)
        self.assertFalse((self.output / 'artifacts/runtime/Lib').exists())
        self.assertEqual(gate.tree_files(self.fixture.materials).keys(), gate.tree_files(self.output / 'materials').keys())
        text = (self.output / 'artifacts/acquisition-observation.json').read_text()
        self.assertNotIn(str(self.root), text)
        self.assertNotIn('file:', text)
        self.assertFalse((self.output / 'artifacts/pip-report.json').exists())

    def test_wrong_commit_and_missing_reported_wheel_do_not_emit_receipt(self):
        self.args['commit'] = 'd' * 40
        with self.assertRaisesRegex(ValueError, 'commit comment'):
            self.create()
        self.assertFalse(self.output.exists())
        self.args['commit'] = 'c' * 40
        next(self.wheelhouse.iterdir()).unlink()
        with self.assertRaises(OSError):
            self.create()
        self.assertFalse(self.output.exists())

    def test_copy_drift_rejected_without_success_receipt(self):
        original = subject.copy_exact
        def corrupt(source, destination, expected=None):
            if destination.name == 'source.zip':
                source.write_bytes(b'changed source')
            return original(source, destination, expected)
        with patch.object(subject, 'copy_exact', side_effect=corrupt):
            with self.assertRaisesRegex(ValueError, 'differs'):
                self.create()
        self.assertFalse((self.output / 'candidate-inputs.json').exists())

    def test_missing_material_reference_rejected_without_receipt(self):
        self.fixture.materials.joinpath('license.txt').unlink()
        with self.assertRaisesRegex(ValueError, 'Prepare gate rejected'):
            self.create()
        self.assertFalse((self.output / 'candidate-inputs.json').exists())

    def test_output_existing_is_preserved(self):
        self.output.mkdir()
        marker = self.output / 'existing.txt'
        marker.write_text('preserve')
        with self.assertRaisesRegex(ValueError, 'already exists'):
            self.create()
        self.assertEqual(marker.read_text(), 'preserve')

    def test_non_windows_and_non_amd64_runtime_rejected(self):
        self.runtime['host'] = 'darwin'
        with self.assertRaisesRegex(ValueError, 'Windows'):
            self.create()
        self.runtime['host'] = 'win32'
        (self.runtime_root / 'python314.dll').write_bytes(b'not PE')
        with self.assertRaisesRegex(ValueError, 'Windows PE'):
            self.create()
        self.assertFalse(self.output.exists())

    def test_checkout_source_drift_is_rejected(self):
        (self.fixture.source / 'platforms/windows/launcher.py').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'differs from packaging checkout'):
            self.create()
        self.assertFalse(self.output.exists())

    def test_cli_has_no_runtime_override_and_calls_actual_observer(self):
        args = []
        for key in ('wheelhouse', 'pip_report', 'materials_root', 'source_archive', 'source_root', 'output', 'commit'):
            args += ['--' + key.replace('_', '-'), str(self.args[key])]
        with patch.object(gate, 'runtime_observation', return_value=self.runtime) as observer, \
             patch.object(subject.sys, 'executable', str(self.args['executable'])), \
             patch.object(subject.sys, 'base_prefix', str(self.runtime_root)):
            self.assertEqual(subject.main(args), 0)
            self.assertEqual(observer.call_count, 2)
        with self.assertRaises(SystemExit):
            subject.main(args + ['--runtime', 'win32'])


if __name__ == '__main__':
    unittest.main()
