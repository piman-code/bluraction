"""Authored archive/PE-header fixtures; no Windows/codec/package execution proof."""
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))
from shared import windows_package_receipt as subject


def digest(data):
    return hashlib.sha256(data).hexdigest()


def row(path, root):
    data = path.read_bytes()
    return {'path': path.relative_to(root).as_posix(), 'bytes': len(data), 'sha256': digest(data)}


class WindowsReceiptTests(unittest.TestCase):
    def setUp(self):
        # /tmp is a symlink on macOS; actual no-follow checks remain enabled.
        self.temp = tempfile.TemporaryDirectory(dir='/private/tmp' if sys.platform == 'darwin' else None)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.artifacts = self.root / 'acquired'
        self.materials = self.root / 'materials'
        self.source = self.root / 'source'
        self.bundle = self.root / 'BlurAction'
        for directory in (self.artifacts, self.materials, self.source, self.bundle):
            directory.mkdir()
        header = bytearray(96)
        header[:2] = b'MZ'
        struct.pack_into('<I', header, 60, 64)
        header[64:70] = b'PE\0\0\x64\x86'
        self.native = bytes(header)
        # Literal independent pins: this fixture cannot auto-pass a changed pin.
        self.pins = {'pyside6': '6.11.1', 'pyside6-addons': '6.11.1',
            'pyside6-essentials': '6.11.1', 'shiboken6': '6.11.1', 'pillow': '12.3.0',
            'numpy': '2.3.5', 'av': '19.0.0', 'opencv-contrib-python-headless': '4.14.0.94',
            'pypdf': '6.19.0', 'pillow-heif': '1.8.0', 'pyinstaller': '6.22.3'}
        artifacts = []
        for name, version in self.pins.items():
            file = self.artifacts / (name + '.whl')
            self.write_wheel(file, name, version)
            artifacts.append(dict(row(file, self.artifacts), id=name, kind='wheel',
                distribution=name, version=version, provider='official-wheel'))
        python = self.artifacts / 'python.exe'
        python.write_bytes(self.native + b'authored interpreter artifact')
        artifacts.append(dict(row(python, self.artifacts), id='python', kind='runtime'))
        runtime = {'host': 'win32', 'version': '3.14.7', 'implementation': 'cpython',
            'cache_tag': 'cpython-314', 'architecture': 'amd64', 'gil_disabled': False,
            'executable_sha256': digest(python.read_bytes())}
        self.runtime = dict(runtime, distributions=self.pins.copy())
        required = ('LICENSE', 'platforms/windows/launcher.py',
            'platforms/windows/bluraction/ui.py', 'platforms/windows/bluraction/editor.py',
            'platforms/windows/bluraction/renderer.py', 'platforms/windows/requirements-dev.txt',
            'platforms/windows/installer/requirements-packaging.txt',
            'platforms/windows/build_package.ps1', 'platforms/windows/installer/build_installer.ps1',
            'platforms/windows/verify_dependency_pins.py', 'scripts/verify_windows.py',
            'shared/portable_project.py')
        for name in required:
            file = self.source / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text('# authored source fixture\n', encoding='utf-8')
        (self.source / 'shared').mkdir(exist_ok=True)
        (self.source / 'shared/fixture.py').write_text('# shared authored source\n')
        declared = {k: v for k, v in self.pins.items() if k not in
            ('pyside6-addons', 'pyside6-essentials', 'shiboken6', 'pyinstaller')}
        (self.source / 'platforms/windows/requirements-dev.txt').write_text(
            '\n'.join(k + '==' + v for k, v in declared.items()) + '\n')
        (self.source / 'platforms/windows/installer/requirements-packaging.txt').write_text('pyinstaller==6.22.3\n')
        self.source_zip = self.artifacts / 'source.zip'
        self.write_source()
        self.materials.joinpath('NOTICE.txt').write_text('Authored notice; no legal verdict.\n')
        self.materials.joinpath('license.txt').write_text('Authored license fixture.\n')
        self.materials.joinpath('evidence.txt').write_text('Authored evidence fixture.\n')
        ids = ('python', 'pyside6', 'qt', 'pdfium', 'pyav', 'ffmpeg', 'opencv',
            'pillow', 'numpy', 'pyinstaller', 'pypdf', 'pillow-heif', 'libheif', 'heif-codecs')
        aliases = {'pyav': 'av', 'opencv': 'opencv-contrib-python-headless'}
        dependencies = [dict(id=name, version=('3.14.7' if name == 'python' else
            self.pins.get(aliases.get(name, name), 'authored-only')), license='fixture',
            redistribution_review='pending-unpublished-candidate',
            license_files=['license.txt'], evidence_files=['evidence.txt']) for name in ids]
        self.inventory = {'dependencies': dependencies, 'final_bundle_bound': False}
        (self.materials / 'dependencies.json').write_text(json.dumps(self.inventory))
        self.receipt = dict(schema_version=1, phase='candidate-inputs', runtime=runtime,
            artifacts=artifacts, app_source=dict(row(self.source_zip, self.artifacts), commit='c'*40, dirty=False),
            materials={})
        self.refresh_materials()
        (self.bundle / 'BlurAction.exe').write_bytes(self.native + b'authored generated app')
        (self.bundle / '_internal').mkdir()
        (self.bundle / '_internal/native.dll').write_bytes(self.native)
        self.manifest = self.root / 'bundle-manifest.json'
        self.receipt['native_bindings'] = [dict(path='_internal/native.dll', artifact_id='pyside6-essentials', member='native/native.dll')]
        build = self.artifacts / 'build.json'
        tool = self.find('pyinstaller')
        self.build_record = dict(status='pyinstaller-build-completed', exit=0, timed_out=False,
            source_archive_sha256=self.receipt['app_source']['sha256'],
            python_executable_sha256=runtime['executable_sha256'],
            pyinstaller_wheel_sha256=tool['sha256'], executable_sha256=digest((self.bundle / 'BlurAction.exe').read_bytes()))
        build.write_text(json.dumps(self.build_record))
        self.receipt['build_evidence'] = row(build, self.artifacts)
        for name in self.pins:
            if name in ('pypdf', 'pyinstaller', 'pyside6', 'pyside6-essentials'):
                continue
            file = self.bundle / ('_internal/' + name + '.dll')
            file.write_bytes(self.native)
            self.receipt['native_bindings'].append(dict(path=file.relative_to(self.bundle).as_posix(),
                artifact_id=name, member='native/native.dll'))
        runtime_dll = self.bundle / '_internal/python.dll'
        runtime_dll.write_bytes(python.read_bytes())
        self.receipt['native_bindings'].append(dict(path='_internal/python.dll', artifact_id='python'))
        component_ids = {'python': ['python'], 'pyside6': ['pyside6', 'shiboken6'],
            'qt': ['pyside6-essentials', 'pyside6-addons'], 'pdfium': ['pyside6-addons'],
            'pyav': ['av'], 'ffmpeg': ['av', 'pyside6-addons', 'opencv-contrib-python-headless'],
            'opencv': ['opencv-contrib-python-headless'], 'pillow': ['pillow'], 'numpy': ['numpy'],
            'pyinstaller': ['pyinstaller'], 'pypdf': ['pypdf'], 'pillow-heif': ['pillow-heif'],
            'libheif': ['pillow-heif'], 'heif-codecs': ['pillow-heif']}
        self.component_bindings = [dict(id=d['id'], version=d['version'],
            artifact_ids=component_ids[d['id']], provider={name: ('runtime' if name == 'python' else
                'official-wheel') for name in component_ids[d['id']]}, evidence_paths=['evidence.txt'],
            native_paths=[b['path'] for b in self.receipt['native_bindings'] if b['artifact_id'] in component_ids[d['id']]])
            for d in dependencies]
        self.receipt['materials']['dependency_bindings'] = self.component_bindings
        self.review_file = self.root / 'review.json'
        self.update_review()
        self.refresh_bundle()
        self.update_review()

    def find(self, identity):
        return next(r for r in self.receipt['artifacts'] if r['id'] == identity)

    def write_wheel(self, file, name, version, tag='cp314-cp314-win_amd64', extra=None):
        directory = name.replace('-', '_') + '-' + version + '.dist-info/'
        with zipfile.ZipFile(file, 'w') as archive:
            archive.writestr(directory + 'METADATA', 'Metadata-Version: 2.1\nName: ' + name + '\nVersion: ' + version + '\n')
            archive.writestr(directory + 'WHEEL', 'Wheel-Version: 1.0\nTag: ' + tag + '\n')
            if name not in ('pyside6', 'pypdf', 'pyinstaller'):
                archive.writestr('native/native.dll', self.native)
            for path, data in (extra or {}).items():
                archive.writestr(path, data)

    def refresh_wheel(self, identity, **changes):
        item = self.find(identity)
        self.write_wheel(self.artifacts / item['path'], changes.pop('name', item['distribution']),
            changes.pop('version', item['version']), **changes)
        item.update(row(self.artifacts / item['path'], self.artifacts))

    def write_source(self, extra=None):
        with zipfile.ZipFile(self.source_zip, 'w') as archive:
            for file in self.source.rglob('*'):
                if file.is_file():
                    archive.write(file, file.relative_to(self.source).as_posix())
            for path, data in (extra or {}).items():
                archive.writestr(path, data)
        if hasattr(self, 'receipt'):
            self.receipt['app_source'].update(row(self.source_zip, self.artifacts))

    def refresh_materials(self):
        self.receipt['materials'] = dict(inventory_sha256=digest((self.materials / 'dependencies.json').read_bytes()),
            files=[row(f, self.materials) for f in sorted(self.materials.iterdir())])
        if hasattr(self, 'component_bindings'):
            self.receipt['materials']['dependency_bindings'] = self.component_bindings

    def refresh_bundle(self):
        licenses = self.bundle / 'licenses'
        if licenses.exists():
            shutil.rmtree(licenses)
        shutil.copytree(self.materials, licenses)
        manifest = [dict(path='BlurAction/' + file.relative_to(self.bundle).as_posix(), sha256=digest(file.read_bytes()))
            for file in sorted(self.bundle.rglob('*')) if file.is_file()]
        self.manifest.write_text(json.dumps(manifest))
        self.receipt['bundle_manifest_sha256'] = digest(self.manifest.read_bytes())

    def check(self, mode='prepare', receipt=None):
        candidate = deepcopy(self.receipt if receipt is None else receipt)
        if mode == 'finalize':
            candidate['phase'] = 'bundle-inputs-bound'
        candidate_hash = digest(json.dumps(candidate, sort_keys=True).encode())
        if mode == 'finalize':
            self.update_review(candidate, candidate_hash)
        return subject.validate_receipt(candidate, artifacts_root=self.artifacts, materials_root=self.materials,
            bundle_root=self.bundle, bundle_manifest=self.manifest, runtime_observation=self.runtime,
            source_root=self.source, mode=mode, license_review=self.review_file,
            version='authored-fixture', receipt_sha256=candidate_hash)

    def update_review(self, candidate=None, candidate_hash=None):
        candidate = deepcopy(self.receipt) if candidate is None else candidate
        candidate['phase'] = 'bundle-inputs-bound'
        review = dict(status='reviewed', version='authored-fixture', reviewed_by='authored-fixture',
            reviewed_at='authored-fixture', dependencies=[dict(id=d['id'], version=d['version'],
                status='reviewed', findings='Synthetic findings, no actual license approval.',
                evidence_files=d['evidence_files']) for d in self.inventory['dependencies']],
            bundle_manifest_sha256=candidate.get('bundle_manifest_sha256'),
            input_receipt_sha256=candidate_hash or digest(json.dumps(candidate, sort_keys=True).encode()))
        data = json.dumps(review)
        if not self.review_file.exists() or self.review_file.read_text() != data:
            self.review_file.write_text(data)

    def reject(self, mode='prepare', receipt=None, contains=None):
        result = self.check(mode, receipt)
        self.assertFalse(result['ok'], result)
        self.assertTrue(result['errors'])
        if contains:
            self.assertIn(contains, result['errors'][0])

    def test_authored_prepare_and_final_are_read_only_without_runtime_or_legal_claim(self):
        before = {p: (digest(p.read_bytes()), p.stat().st_mtime_ns) for p in self.root.rglob('*') if p.is_file()}
        for mode in ('prepare', 'finalize'):
            result = self.check(mode)
            self.assertTrue(result['ok'], result)
            self.assertFalse(result['native_codec_execution'])
            self.assertFalse(result['redistribution_approved'])
        after = {p: (digest(p.read_bytes()), p.stat().st_mtime_ns) for p in self.root.rglob('*') if p.is_file()}
        self.assertEqual(before, after)

    def test_exact_runtime_patch_architecture_gil_and_executable(self):
        for key, value in [('version', '3.14.8'), ('host', 'darwin'), ('architecture', 'arm64'),
                ('gil_disabled', True), ('cache_tag', 'cpython-314t'), ('executable_sha256', '0'*64)]:
            with self.subTest(key=key):
                candidate = deepcopy(self.receipt)
                candidate['runtime'][key] = value
                self.reject(receipt=candidate)
        self.runtime['distributions']['numpy'] = '2.0.0'
        self.reject(contains='installed metadata')

    def test_missing_transitive_and_runtime_artifacts_fail(self):
        for identity in ('pyside6-addons', 'python'):
            with self.subTest(identity=identity):
                candidate = deepcopy(self.receipt)
                candidate['artifacts'] = [r for r in candidate['artifacts'] if r['id'] != identity]
                self.reject(receipt=candidate)

    def test_archive_name_version_and_compatible_abi_are_actual_not_labels(self):
        identity = 'pypdf'
        for changes in ({'name': 'imposter'}, {'version': '6.18.0'},
                {'tag': 'cp314-cp314-win_arm64'}, {'tag': 'cp314t-cp314t-win_amd64'},
                {'tag': 'cp313-cp313-win_amd64'}, {'tag': 'cp315-abi3-win_amd64'},
                {'tag': 'cp314-cp314-macosx_14_0_arm64'}):
            with self.subTest(changes=changes):
                self.refresh_wheel(identity, **changes)
                self.reject()
        self.refresh_wheel(identity, tag='py3-none-any')
        self.assertTrue(self.check()['ok'])
        self.refresh_wheel(identity, tag='cp39-abi3-win_amd64')
        self.assertTrue(self.check()['ok'])

    def test_pyinstaller_platform_wheel_none_abi_is_supported_only_for_windows_x64(self):
        # Actual acquired PyInstaller 6.22.3 metadata names py3-none-win_amd64.
        self.refresh_wheel('pyinstaller', tag='py3-none-win_amd64')
        self.assertTrue(self.check()['ok'])
        for tag in ('py3-none-win_arm64', 'py3-none-win32', 'py3-none-manylinux_2_17_x86_64'):
            with self.subTest(tag=tag):
                self.refresh_wheel('pyinstaller', tag=tag)
                self.reject(contains='compatible')

    def test_unknown_fields_duplicate_ids_paths_and_changed_bytes(self):
        candidate = deepcopy(self.receipt)
        candidate['skip_native_verification'] = True
        self.reject(receipt=candidate, contains='unknown')
        for field in ('id', 'path'):
            candidate = deepcopy(self.receipt)
            candidate['artifacts'][1][field] = candidate['artifacts'][0][field]
            self.reject(receipt=candidate)
        (self.artifacts / self.find('pypdf')['path']).write_bytes(b'altered archive')
        self.reject(contains='SHA drift')

    def test_owned_wheel_requires_actual_nonempty_evidence_artifact(self):
        owned = self.find('av')
        owned['provider'] = 'owned-build'
        self.reject(contains='evidence')
        owned['evidence_ids'] = ['pypdf']
        self.reject(contains='evidence')
        evidence = self.artifacts / 'source-acquisition.json'
        evidence.write_text('{"fixture":"authored build lock, not an execution"}')
        self.receipt['artifacts'].append(dict(row(evidence, self.artifacts), id='owned-lock', kind='evidence'))
        owned['evidence_ids'] = ['owned-lock']
        self.assertTrue(self.check()['ok'])
        evidence.write_bytes(b'')
        self.reject()

    def test_source_archive_spine_checkout_and_declared_requirements_are_bound(self):
        (self.source / 'platforms/windows/bluraction/ui.py').write_text('# changed checkout\n')
        self.reject(contains='checkout')
        self.write_source()
        self.assertTrue(self.check()['ok'])
        (self.source / 'platforms/windows/requirements-dev.txt').write_text('pypdf==6.18.0\n')
        self.write_source()
        self.reject(contains='requirements')

    def test_new_shared_code_must_be_in_source_archive(self):
        (self.source / 'shared/new_module.py').write_text('# new input\n')
        self.reject(contains='absent from source')

    def test_actual_repo_spine_exists_and_actual_requirements_match_independent_pins(self):
        # Separate from authored source fixtures: a nonexistent required path
        # cannot pass merely because the fixture factory created the same typo.
        for name in subject.SOURCE_REQUIRED:
            with self.subTest(actual_repository_input=name):
                self.assertTrue((REPO / name).is_file(), name)
        declared = {}
        for name in ('platforms/windows/requirements-dev.txt',
                     'platforms/windows/installer/requirements-packaging.txt'):
            for line in (REPO / name).read_text(encoding='utf-8-sig').splitlines():
                line = line.partition('#')[0].strip()
                if not line:
                    continue
                package, version = line.split('==')
                package = package.lower().replace('_', '-')
                self.assertNotIn(package, declared)
                declared[package] = version
        self.assertEqual(declared, {k: v for k, v in self.pins.items()
            if k not in ('pyside6-addons', 'pyside6-essentials', 'shiboken6')})

    def test_source_private_and_disguised_native_inputs_rejected(self):
        for extra in ({'.git/config': b'private'}, {'qa-20261001/user.png': b'private'},
                {'extra.dll': self.native}, {'image.bin': self.native}):
            with self.subTest(extra=list(extra)):
                self.write_source(extra)
                self.reject()

    def test_all_materials_versions_and_nonempty_references_are_bound(self):
        (self.materials / 'unlisted.txt').write_text('extra actual file')
        self.reject(contains='every actual file')
        self.refresh_materials()
        self.assertTrue(self.check()['ok'])
        self.inventory['dependencies'][0]['version'] = '3.14.8'
        (self.materials / 'dependencies.json').write_text(json.dumps(self.inventory))
        self.refresh_materials()
        self.reject(contains='Python identity')

    def test_material_references_and_bundle_copy_cannot_be_missing_or_changed(self):
        self.inventory['dependencies'][0]['evidence_files'] = ['absent.txt']
        (self.materials / 'dependencies.json').write_text(json.dumps(self.inventory))
        self.refresh_materials()
        self.reject()
        self.inventory['dependencies'][0]['evidence_files'] = ['evidence.txt']
        (self.materials / 'dependencies.json').write_text(json.dumps(self.inventory))
        self.refresh_materials()
        self.refresh_bundle()
        (self.bundle / 'licenses/license.txt').write_text('changed bundled license')
        manifest = json.loads(self.manifest.read_text())
        for entry in manifest:
            if entry['path'] == 'BlurAction/licenses/license.txt':
                entry['sha256'] = digest((self.bundle / 'licenses/license.txt').read_bytes())
        self.manifest.write_text(json.dumps(manifest))
        self.receipt['bundle_manifest_sha256'] = digest(self.manifest.read_bytes())
        self.reject('finalize', contains='bundled materials differ')

    def test_hidden_bundle_files_manifest_duplicates_and_root_are_exact(self):
        (self.bundle / '.hidden').write_text('hidden addition')
        self.reject('finalize', contains='unlisted')
        self.refresh_bundle()
        self.assertTrue(self.check('finalize')['ok'])
        entries = json.loads(self.manifest.read_text())
        entries.append(entries[0])
        self.manifest.write_text(json.dumps(entries))
        self.receipt['bundle_manifest_sha256'] = digest(self.manifest.read_bytes())
        self.reject('finalize', contains='duplicate')

    def test_missing_mismatched_native_member_and_duplicate_mapping_fail(self):
        for bindings in ([], [dict(path='_internal/native.dll', artifact_id='pyside6-essentials', member='missing.dll')],
                self.receipt['native_bindings'] * 2):
            with self.subTest(bindings=bindings):
                candidate = deepcopy(self.receipt)
                candidate['native_bindings'] = bindings
                self.reject('finalize', candidate)
        (self.bundle / '_internal/native.dll').write_bytes(self.native + b'altered DLL')
        self.refresh_bundle()
        self.reject('finalize', contains='differs from selected')

    def test_helper_exe_and_disguised_pe_need_providers_and_actual_amd64(self):
        for name in ('_internal/helper.exe', '_internal/disguised.dat'):
            file = self.bundle / name
            file.write_bytes(self.native)
            self.refresh_bundle()
            self.reject('finalize', contains='every native')
            file.unlink()
        arm = bytearray(self.native)
        arm[68:70] = b'\x64\xaa'
        self.native = bytes(arm)
        self.refresh_wheel('pyside6-essentials')
        (self.bundle / '_internal/native.dll').write_bytes(self.native)
        self.refresh_bundle()
        self.reject('finalize', contains='AMD64')

    def test_build_record_binds_source_interpreter_tool_output_and_positive_exit(self):
        file = self.artifacts / 'build.json'
        for field, value in [('status', 'pending'), ('exit', 1), ('exit', False), ('timed_out', True),
                ('source_archive_sha256', '0'*64), ('python_executable_sha256', '0'*64),
                ('pyinstaller_wheel_sha256', '0'*64), ('executable_sha256', '0'*64)]:
            with self.subTest(field=field, value=value):
                bad = dict(self.build_record, **{field: value})
                file.write_text(json.dumps(bad))
                self.receipt['build_evidence'] = row(file, self.artifacts)
                self.reject('finalize', contains='build evidence')

    def test_generated_main_executable_architecture_is_not_only_a_hash_label(self):
        arm = bytearray(self.native)
        arm[68:70] = b'\x64\xaa'
        file = self.bundle / 'BlurAction.exe'
        file.write_bytes(arm)
        self.build_record['executable_sha256'] = digest(file.read_bytes())
        build = self.artifacts / 'build.json'
        build.write_text(json.dumps(self.build_record))
        self.receipt['build_evidence'] = row(build, self.artifacts)
        self.refresh_bundle()
        self.reject('finalize', contains='AMD64')

    def test_windows_alias_paths_and_symlink_inputs_are_rejected(self):
        for path in ('../escape', '.', 'a//b', 'a\\b', 'C:stream', 'CON', 'nul.txt',
                'folder/name.', 'folder/name ', 'COM¹.txt', 'a?b', 'LPT9'):
            with self.subTest(path=path):
                candidate = deepcopy(self.receipt)
                candidate['artifacts'][0]['path'] = path
                self.reject(receipt=candidate)
        if sys.platform == 'win32':
            return  # Creating Windows symlinks requires a separate OS privilege.
        real = self.artifacts / self.find('pypdf')['path']
        target = self.artifacts / 'target.whl'
        real.rename(target)
        real.symlink_to(target)
        self.reject(contains='symlink')

    def test_json_duplicate_nonfinite_and_depth_fail_structurally(self):
        file = self.root / 'invalid.json'
        for data in ('{"x":1,"x":2}', '{"x":NaN}'):
            file.write_text(data)
            with self.assertRaises(ValueError):
                subject.read_json(file)
        file.write_text('['*1500 + '0' + ']'*1500)
        # The public validator converts malformed build JSON depth to an error.
        (self.artifacts / 'build.json').write_bytes(file.read_bytes())
        self.receipt['build_evidence'] = row(self.artifacts / 'build.json', self.artifacts)
        self.reject('finalize')

    def test_zip_case_alias_nul_and_local_central_filename_mismatch(self):
        file = self.artifacts / 'case.zip'
        with zipfile.ZipFile(file, 'w') as archive:
            archive.writestr('A.txt', b'a')
            archive.writestr('a.txt', b'b')
        with zipfile.ZipFile(file) as archive:
            with self.assertRaises(ValueError):
                subject.zip_members(archive)
        for replacement in (b'a\x00txt', b'b.txt'):
            with zipfile.ZipFile(file, 'w') as archive:
                archive.writestr('a.txt', b'a')
            raw = file.read_bytes()
            # NUL modifies both names; mismatch modifies the local name only.
            raw = raw.replace(b'a.txt', replacement, 2 if b'\x00' in replacement else 1)
            file.write_bytes(raw)
            with zipfile.ZipFile(file) as archive:
                with self.assertRaises((ValueError, zipfile.BadZipFile)):
                    subject.zip_members(archive)

    def test_bounds_and_live_mutation_during_read_fail_closed(self):
        with patch.object(subject, 'MAX_MEMBERS', 2):
            self.reject()
        with patch.object(subject, 'MAX_JSON', 16):
            self.reject()
        file = self.artifacts / 'mutate.txt'
        file.write_bytes(b'old')
        with self.assertRaises(ValueError):
            with subject.stable_read(file) as stream:
                self.assertEqual(stream.read(), b'old')
                file.write_bytes(b'new bytes')

    def test_component_binding_different_same_version_wheel_stock_owned_and_native_mismatch(self):
        for change in ('missing', 'different-wheel', 'wrong-provider', 'wrong-version', 'missing-native', 'wrong-native', 'missing-evidence'):
            with self.subTest(change=change):
                candidate = deepcopy(self.receipt)
                bindings = candidate['materials']['dependency_bindings']
                target = next(b for b in bindings if b['id'] == 'qt')
                if change == 'missing':
                    bindings.remove(target)
                elif change == 'different-wheel':
                    target['artifact_ids'] = ['shiboken6']  # Same 6.11.1, different distribution.
                    target['provider'] = {'shiboken6': 'official-wheel'}
                    target['native_paths'] = ['_internal/shiboken6.dll']
                elif change == 'wrong-provider':
                    target['provider']['pyside6-essentials'] = 'owned-build'
                elif change == 'wrong-version':
                    target['version'] = '6.11.0'
                elif change == 'missing-native':
                    target['native_paths'] = []
                elif change == 'wrong-native':
                    target['native_paths'] = ['_internal/av.dll']
                else:
                    target['evidence_paths'] = ['license.txt']
                self.reject('finalize', candidate)

    def test_nested_component_version_is_explicit_pending_not_certified(self):
        result = self.check('finalize')
        self.assertTrue(result['ok'], result)
        self.assertFalse(result['component_versions_certified'])
        self.assertFalse(result['redistribution_approved'])

    def test_license_review_duplicate_keys_bad_binding_nonfinite_and_size(self):
        candidate = deepcopy(self.receipt)
        candidate['phase'] = 'bundle-inputs-bound'
        receipt_hash = digest(json.dumps(candidate, sort_keys=True).encode())
        self.update_review(candidate, receipt_hash)
        good = self.review_file.read_text()
        def validate():
            return subject.validate_receipt(candidate, artifacts_root=self.artifacts, materials_root=self.materials,
                bundle_root=self.bundle, bundle_manifest=self.manifest, runtime_observation=self.runtime,
                source_root=self.source, mode='finalize', license_review=self.review_file,
                version='authored-fixture', receipt_sha256=receipt_hash)
        for bad in (good[:-1] + ',"status":"reviewed"}', good.replace(receipt_hash, '0'*64),
                good.replace('"reviewed_at": "authored-fixture"', '"reviewed_at": NaN')):
            with self.subTest(bad=bad[:45]):
                self.review_file.write_text(bad)
                self.assertFalse(validate()['ok'])
        self.review_file.write_text(' ' * (4*1024**2 + 1))
        self.assertFalse(validate()['ok'])

    def test_review_requires_complete_unique_inventory_findings_and_actual_evidence(self):
        candidate = deepcopy(self.receipt)
        candidate['phase'] = 'bundle-inputs-bound'
        receipt_hash = digest(json.dumps(candidate, sort_keys=True).encode())
        self.update_review(candidate, receipt_hash)
        good = json.loads(self.review_file.read_text())
        def validate():
            return subject.validate_receipt(candidate, artifacts_root=self.artifacts, materials_root=self.materials,
                bundle_root=self.bundle, bundle_manifest=self.manifest, runtime_observation=self.runtime,
                source_root=self.source, mode='finalize', license_review=self.review_file,
                version='authored-fixture', receipt_sha256=receipt_hash)
        self.assertTrue(validate()['ok'])
        rows = good['dependencies']
        invalid = [[], [None], ['findings'], rows[:-1], rows + [rows[0]]]
        for field, value in [('id', 'unknown-dependency'), ('id', None), ('version', 'different'),
                ('version', 314), ('status', 'pending'), ('status', True), ('findings', ''),
                ('findings', ' \n\t'), ('findings', {'notes': 'not text'}), ('findings', 'x' * 8193),
                ('evidence_files', []), ('evidence_files', ['missing.txt']),
                ('evidence_files', ['license.txt']), ('evidence_files', ['../evidence.txt']),
                ('evidence_files', ['evidence.txt', 'EVIDENCE.txt']), ('evidence_files', [None])]:
            altered = deepcopy(rows)
            altered[0][field] = value
            invalid.append(altered)
        for field in ('id', 'version', 'status', 'findings', 'evidence_files'):
            altered = deepcopy(rows)
            del altered[0][field]
            invalid.append(altered)
        for index, findings in enumerate(invalid):
            with self.subTest(case=index):
                altered = deepcopy(good)
                altered['dependencies'] = findings
                self.review_file.write_text(json.dumps(altered))
                self.assertFalse(validate()['ok'])
        self.review_file.write_text(json.dumps(good))
        result = validate()
        self.assertTrue(result['ok'], result)
        self.assertFalse(result['redistribution_approved'])
        self.assertFalse(result['component_versions_certified'])

    def test_exponent_overflow_is_nonfinite_at_every_json_depth(self):
        file = self.root / 'overflow.json'
        for data in ('1e400', '-1e400', '{"rows":[{"version":1e400}]}',
                     '{"rows":[[-1e400]]}'):
            with self.subTest(raw=data):
                file.write_text(data)
                with self.assertRaisesRegex(ValueError, 'nonfinite'):
                    subject.read_json(file)
        file.write_text('{"value":1.25,"nested":[-2.5,1e300]}')
        self.assertEqual(subject.read_json(file), {'value': 1.25, 'nested': [-2.5, 1e300]})

    def test_review_identity_types_blank_bounds_and_nested_overflow_are_rejected(self):
        candidate = deepcopy(self.receipt)
        candidate['phase'] = 'bundle-inputs-bound'
        receipt_hash = digest(json.dumps(candidate, sort_keys=True).encode())
        self.update_review(candidate, receipt_hash)
        good = self.review_file.read_text()
        def validate():
            return subject.validate_receipt(candidate, artifacts_root=self.artifacts, materials_root=self.materials,
                bundle_root=self.bundle, bundle_manifest=self.manifest, runtime_observation=self.runtime,
                source_root=self.source, mode='finalize', license_review=self.review_file,
                version='authored-fixture', receipt_sha256=receipt_hash)
        for field in ('reviewed_by', 'reviewed_at'):
            for value in (True, 42, 1.5, {'name': 'fixture'}, ['fixture'], None, '', ' \n\t', 'x' * 513):
                with self.subTest(field=field, value_type=type(value).__name__):
                    altered = json.loads(good)
                    altered[field] = value
                    self.review_file.write_text(json.dumps(altered))
                    self.assertFalse(validate()['ok'])
            for raw in ('1e400', '-1e400'):
                self.review_file.write_text(good.replace('"' + field + '": "authored-fixture"',
                    '"' + field + '": ' + raw))
                self.assertFalse(validate()['ok'])
        self.review_file.write_text(good[:-1] + ',"nested":{"evidence":[1e400]}}')
        self.assertFalse(validate()['ok'])

    def test_relative_input_context_changes_but_caller_bound_paths_remain_same(self):
        # Actual pure-helper path behavior; this does not execute PowerShell or
        # certify its Resolve-Path implementation on Windows.
        before = Path.cwd()
        try:
            os.chdir(self.root)
            artifact_path = Path('acquired').absolute()
            material_path = Path('materials').absolute()
            arguments = dict(source_root=self.source, runtime_observation=self.runtime, mode='prepare')
            self.assertTrue(subject.validate_receipt(self.receipt, artifacts_root='acquired',
                materials_root='materials', **arguments)['ok'])
            os.chdir(self.source)
            self.assertFalse(subject.validate_receipt(self.receipt, artifacts_root='acquired',
                materials_root='materials', **arguments)['ok'])
            self.assertTrue(subject.validate_receipt(self.receipt, artifacts_root=artifact_path,
                materials_root=material_path, **arguments)['ok'])
        finally:
            os.chdir(before)
        self.assertEqual(Path.cwd(), before)

    @unittest.skipIf(sys.platform == 'win32', 'Non-Windows CLI boundary only')
    def test_cli_rejects_macos_before_acquisition_or_native_reads(self):
        result = subprocess.run([sys.executable, str(REPO / 'shared/windows_package_receipt.py'),
            '--mode', 'finalize', '--receipt', str(self.root / 'does-not-exist'),
            '--artifacts-root', str(self.artifacts), '--materials-root', str(self.materials),
            '--source-root', str(self.source)], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 1, result)
        output = json.loads(result.stdout)
        self.assertFalse(output['ok'])
        self.assertIn('actual Windows interpreter', output['errors'][0])
        self.assertFalse(output['native_codec_execution'])


if __name__ == '__main__':
    unittest.main()
