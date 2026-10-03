"""Copy acquired candidate inputs and validate a prepare-only receipt.

No acquisition, installation, package build, license verdict or release approval.
The CLI observes its own Windows interpreter. Partial outputs after an error are
retained for diagnosis and never contain a successful candidate receipt.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
import zipfile

if __package__ in (None, ''):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts.collect_windows_build_inputs import collect
from shared import windows_package_receipt as gate


def copy_exact(source, destination, expected=None):
    """Exclusive bounded copy with no-follow source identity and digest checks."""
    source = gate.plain(source)
    expected = gate.sha(source) if expected is None else gate.hash_value(expected)
    gate.plain(destination.parent, directory=True)
    digest, size = hashlib.sha256(), 0
    with gate.stable_read(source) as incoming, destination.open('xb') as outgoing:
        for block in iter(lambda: incoming.read(1024 * 1024), b''):
            size += len(block)
            if size > gate.MAX_FILE:
                raise ValueError('bounded input copy required')
            outgoing.write(block)
            digest.update(block)
    if size == 0 or digest.hexdigest() != expected or gate.sha(destination) != expected:
        raise ValueError('copied input differs from selected bytes')
    return {'bytes': size, 'sha256': expected}


def write_new(path, value):
    with path.open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(value, stream, indent=2, ensure_ascii=True)
        stream.write('\n')


def create(*, wheelhouse, pip_report, materials_root, source_archive, commit=None,
           source_root, output, source_manifest=None, runtime=None, executable=None, runtime_root=None):
    """Runtime/executable injection is only an authored-test seam, never CLI input."""
    observed = gate.runtime_observation() if runtime is None else runtime
    executable = Path(sys.executable) if executable is None else Path(executable)
    wheelhouse = gate.plain(wheelhouse, directory=True)
    materials_root = gate.plain(materials_root, directory=True)
    source_root = gate.plain(source_root, directory=True)
    source_archive = gate.plain(source_archive)
    output = Path(output).absolute()
    gate.plain(output.parent, directory=True)
    gate.canonical(output.name)
    if output.exists() or output.is_symlink():
        raise ValueError('Output already exists')
    if (commit is None) == (source_manifest is None):
        raise ValueError('Select exactly one commit or local source manifest')
    if commit is not None and not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('Exact lowercase 40-character Git commit required')
    for input_path in (wheelhouse, materials_root, source_root):
        if output == input_path or input_path.is_relative_to(output):
            raise ValueError('Output must not contain an input directory')
    runtime_root = gate.plain(sys.base_prefix if runtime_root is None else runtime_root, directory=True)
    native_files = {}
    for path in runtime_root.iterdir():
        if path.suffix.lower() == '.dll':
            native_files[path.name] = gate.plain(path)
    dlls = runtime_root / 'DLLs'
    if dlls.exists() or dlls.is_symlink():
        for name, path in gate.tree_files(dlls).values():
            if path.suffix.lower() in ('.dll', '.pyd'):
                native_files['DLLs/' + name] = path
    if len(native_files) > 1000:
        raise ValueError('Bounded Python native runtime set required')
    native_rows = []
    for name, path in sorted(native_files.items()):
        gate.canonical(name)
        gate.require_amd64(path)
        native_rows.append((name, path, gate.sha(path)))
    observation = collect(wheelhouse, pip_report, observed)
    if gate.sha(executable) != observed['executable_sha256']:
        raise ValueError('Actual interpreter executable differs from observation')
    gate.require_amd64(executable)
    archive_hash = gate.sha(source_archive)
    manifest_hash = None
    if source_manifest is not None:
        source_manifest = gate.plain(source_manifest)
        manifest_hash = gate.sha(source_manifest)
        gate.local_source_identity(source_archive, source_manifest, source_root)
    else:
        # Existing acquired commit archives are read, never generated here.
        with gate.stable_read(source_archive) as stream, zipfile.ZipFile(stream) as archive:
            if archive.comment != commit.encode('ascii'):
                raise ValueError('Source archive Git commit comment differs')
        gate.source_identity(source_archive, source_root)
    material_files = gate.tree_files(materials_root)
    material_rows = [{'path': name, 'bytes': path.stat().st_size, 'sha256': gate.sha(path)}
                     for name, path in sorted(material_files.values())]
    output.mkdir()
    artifacts = output / 'artifacts'
    materials = output / 'materials'
    artifacts.mkdir()
    materials.mkdir()
    (artifacts / 'wheels').mkdir()
    rows = []
    for wheel in observation['wheels']:
        relative = 'wheels/' + wheel['filename']
        copied = copy_exact(wheelhouse / wheel['filename'], artifacts / relative, wheel['sha256'])
        rows.append(dict(copied, path=relative, id=wheel['distribution'], kind='wheel',
                         distribution=wheel['distribution'], version=wheel['version'],
                         provider='official-wheel'))
    copied = copy_exact(executable, artifacts / 'python.exe', observed['executable_sha256'])
    rows.append(dict(copied, path='python.exe', id='python', kind='runtime'))
    for name, path, digest in native_rows:
        relative = 'runtime/' + name
        target = artifacts / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        copied = copy_exact(path, target, digest)
        identity = 'runtime-' + hashlib.sha256(name.encode('utf-8')).hexdigest()[:32]
        rows.append(dict(copied, path=relative, id=identity, kind='runtime'))
    copied = copy_exact(source_archive, artifacts / 'source.zip', archive_hash)
    if source_manifest is not None:
        manifest_copy = copy_exact(source_manifest, artifacts / 'source-manifest.json', manifest_hash)
        source = dict(copied, path='source.zip', source_kind='local-snapshot',
                      source_manifest=dict(manifest_copy, path='source-manifest.json'))
    else:
        source = dict(copied, path='source.zip', commit=commit, dirty=False)
    # Raw pip report contains machine paths. Only its hash and sanitized wheel
    # observation are copied; acquisition locations are never written here.
    evidence = artifacts / 'acquisition-observation.json'
    write_new(evidence, observation)
    rows.append(dict(path=evidence.name, bytes=evidence.stat().st_size,
                     sha256=gate.sha(evidence), id='acquisition-observation', kind='evidence'))
    for row in material_rows:
        target = materials / row['path']
        target.parent.mkdir(parents=True, exist_ok=True)
        copy_exact(materials_root / row['path'], target, row['sha256'])
    receipt = dict(schema_version=1, phase='candidate-inputs', runtime=observation['runtime'],
                   artifacts=rows, app_source=source,
                   materials=dict(inventory_sha256=gate.sha(materials / 'dependencies.json'), files=material_rows))
    result = gate.validate_receipt(receipt, artifacts_root=artifacts, materials_root=materials,
                                   source_root=source_root, runtime_observation=observed, mode='prepare')
    if not result['ok']:
        raise ValueError('Prepare gate rejected candidate: ' + '; '.join(result['errors']))
    if collect(wheelhouse, pip_report, observed) != observation:
        raise ValueError('Acquired inputs changed during preparation')
    if material_files.keys() != gate.tree_files(materials_root).keys():
        raise ValueError('Materials membership changed during preparation')
    for row in material_rows:
        gate.file_row(materials_root, row)
    if gate.sha(source_archive) != archive_hash or gate.sha(executable) != observed['executable_sha256']:
        raise ValueError('Source/runtime changed during preparation')
    if source_manifest is not None:
        if gate.sha(source_manifest) != manifest_hash:
            raise ValueError('Local source manifest changed during preparation')
        gate.local_source_identity(source_archive, source_manifest, source_root)
    for _, path, digest in native_rows:
        if gate.sha(path) != digest:
            raise ValueError('Python native runtime changed during preparation')
    if runtime is None and gate.runtime_observation() != observed:
        raise ValueError('Runtime metadata changed during preparation')
    write_new(output / 'prepare-validation.json', result)
    # Published last: a failed operation never creates the candidate receipt.
    write_new(output / 'candidate-inputs.json', receipt)
    return {'status': 'candidate-inputs-prepared', 'wheel_count': len(observation['wheels']),
            'material_count': len(material_rows), 'receipt_sha256': gate.sha(output / 'candidate-inputs.json'),
            'redistribution_approved': False, 'frozen_execution_verified': False}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for field in ('wheelhouse', 'pip-report', 'materials-root', 'source-archive', 'source-root', 'output'):
        parser.add_argument('--' + field, required=True, type=Path)
    provenance = parser.add_mutually_exclusive_group(required=True)
    provenance.add_argument('--commit')
    provenance.add_argument('--source-manifest', type=Path)
    args = parser.parse_args(argv)
    result = create(**vars(args))
    print(json.dumps(result))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
