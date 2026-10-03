#!/usr/bin/env python3
"""Create a NEW bounded source-material ZIP, never a license-compliance verdict.

Inputs are read-only: three pinned source archives/notices, actual owned-build
settings, a caller-hash-bound curated full application-source archive, GNU texts,
and the candidate app's source/library manifest. No app/native binaries, build
products, raw private logs or absolute tool paths are added to the source ZIP.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
RECIPE = ROOT / 'build-recipes/macos-heic-cpu'
spec = importlib.util.spec_from_file_location('_mac_heic_material_io', ROOT / 'scripts/relink_heic_cpu.py')
io_helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(io_helpers)
plain_path, captured_file = io_helpers.plain_path, io_helpers.captured_file
MAX_ARCHIVE = 512 * 1024**2
MAX_EXPANDED = 2 * 1024**3
MAX_MEMBERS = 50000
RECIPE_FILES = ('pins.json', 'tool-pins.json', 'build_recipe.py', 'verify_candidate.py',
                'owned_process.py', 'heic_cpu_candidate.cpp', 'run_diagnostic.py',
                'NativeReadback.swift', 'RELINKING.ko.md')
APPLICATION_REQUIRED = ('Package.swift', 'LICENSE', 'Resources/Info.plist',
    'Sources/BlurAction/App.swift', 'Sources/BlurAction/HEICCPUEncoder.swift',
    'Sources/BlurAction/BlurredImageExporter.swift', 'scripts/build_app.sh',
    'scripts/bundle_heic_cpu.py')


@contextmanager
def managed(resource, cleanup=None):
    """Attempt owned cleanup without replacing the original failure."""
    try:
        yield resource
    finally:
        io_helpers.cleanup_preserving_primary(cleanup if cleanup is not None else resource.close)


def safe_member(value, *, directory=False):
    if type(value) is not str or not value or len(value) > 4096 or '\\' in value or '\0' in value:
        raise ValueError('plain bounded source archive member required')
    name = value[:-1] if directory and value.endswith('/') else value
    path = PurePosixPath(name)
    if path.is_absolute() or ':' in name or '..' in path.parts or not path.parts or str(path) != name:
        raise ValueError('canonical contained source archive member required')
    if len(path.parts) > 64:
        raise ValueError('bounded source archive depth required')
    return name


def validate_source_archive(value, *, application=False, require_full_application=False):
    """Inspect the full archive without extracting or running its contents.

    Authored fixture/media data in a full source snapshot is retained. Native
    executable/object binaries and generated/private output trees are rejected.
    An archive hash proves supplied bytes, not that they reproduce an app.
    """
    path = plain_path(value)
    if path.stat().st_size > MAX_ARCHIVE:
        raise ValueError('bounded archive bytes required')
    forbidden = {'.git', '.build', '__pycache__', '.venv', 'node_modules', '.DS_Store'}
    suffixes = {'.dylib', '.dll', '.exe', '.so', '.o', '.a', '.obj', '.lib',
                '.pdb', '.class', '.wasm', '.pyc', '.pyo'}
    names = set(); total = 0; files = 0; roots = set()
    def entry(name, size, directory, mode, head):
        nonlocal total, files
        name = safe_member(name, directory=directory)
        if name in names or len(names) >= MAX_MEMBERS:
            raise ValueError('unique bounded source members required')
        names.add(name); parts = PurePosixPath(name).parts; roots.add(parts[0])
        if size < 0 or size > io_helpers.MAX_FILE:
            raise ValueError('bounded source member bytes required')
        total += size
        if total > MAX_EXPANDED:
            raise ValueError('bounded expanded source bytes required')
        if stat.S_ISLNK(mode) or (mode & 0o170000 and not (stat.S_ISREG(mode) or stat.S_ISDIR(mode))):
            raise ValueError('source archive links/devices forbidden')
        if directory:
            return
        files += 1
        if (PurePosixPath(name).suffix.lower() in suffixes
                or head[:4] in (b'\x7fELF', b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
                               b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xce', b'\xca\xfe\xba\xbe')
                or head[:4] in (b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca')
                or head[:2] == b'MZ'):
            raise ValueError('native executable/object in source archive')
        if application:
            if (any(p in forbidden or p.startswith('qa-') or p.endswith('.app') for p in parts)
                    or name.endswith('.log') or parts[-1].startswith('.env')):
                raise ValueError('private/generated/compiled application member forbidden')
    if zipfile.is_zipfile(path):
        with managed(zipfile.ZipFile(path)) as archive:
            members = archive.infolist()
            if len(members) > MAX_MEMBERS:
                raise ValueError('bounded source archive member count required')
            for member in members:
                if member.flag_bits & 1:
                    raise ValueError('encrypted source archive forbidden')
                with managed(archive.open(member)) as stream:
                    head = stream.read(4)
                entry(member.filename, member.file_size, member.is_dir(), member.external_attr >> 16, head)
    else:
        with managed(tarfile.open(path, 'r:*')) as archive:
            for member in archive:
                if not (member.isfile() or member.isdir()):
                    raise ValueError('plain regular source archive required')
                stream = archive.extractfile(member) if member.isfile() else None
                try:
                    head = stream.read(4) if stream else b''
                finally:
                    if stream: io_helpers.cleanup_preserving_primary(stream.close)
                entry(member.name, member.size, member.isdir(),
                      (stat.S_IFDIR if member.isdir() else stat.S_IFREG) | member.mode, head)
    if not files:
        raise ValueError('nonempty actual source archive required')
    full_present = False
    for name in names:
        if name == 'Package.swift' or name.endswith('/Package.swift'):
            prefix = name[:-len('Package.swift')]
            if all(prefix + required in names for required in APPLICATION_REQUIRED):
                full_present = True
                break
    if require_full_application and (not application or not full_present):
        raise ValueError('full application source essential files missing')
    return {'files': files, 'members': len(names), 'expandedBytes': total, 'roots': sorted(roots),
            'essentialApplicationFilesPresent': full_present}


def pinned_digest(value):
    if type(value) is not str or re.fullmatch('[0-9a-f]{64}', value) is None:
        raise ValueError('explicit exact SHA256 required')
    return value


def source_materials(owned_root, source_app, app_archive, app_sha, app_commit,
                     gpl_text, gpl_sha, lgpl_text, lgpl_sha):
    owned = plain_path(owned_root, directory=True)
    app = plain_path(source_app, directory=True)
    if app.suffix != '.app' or re.fullmatch('[0-9a-f]{40}', app_commit) is None:
        raise ValueError('app and exact caller curated source commit required')
    observation_paths = (RECIPE / 'pins.json', owned / 'reports/acquisition.json',
                         owned / 'reports/build.json')
    observation_guards = {path: captured_file(path) for path in observation_paths}
    app_before = io_helpers.tree_inventory(app)
    pins = io_helpers.read_json(observation_paths[0])
    acquisition = io_helpers.read_json(observation_paths[1])
    build = io_helpers.read_json(observation_paths[2])
    bundle = io_helpers.read_json(app / (io_helpers.RESOURCES + '/manifest.json'))
    if (build.get('status') != 'source-build-complete-unverified-codec'
            or bundle.get('replacementLibraries')):
        raise ValueError('unmodified recorded owned source build/app required')
    if bundle.get('sources') != pins['sources']:
        raise ValueError('app upstream source pins differ')
    if bundle.get('helperSourceSHA256') != captured_file(RECIPE / 'heic_cpu_candidate.cpp')['sha256']:
        raise ValueError('candidate helper source differs from supplied recipe')
    flags = build.get('codecFlags')
    if type(flags) is not list or not flags or any(type(f) is not str or not f.startswith('-D') or '\n' in f for f in flags):
        raise ValueError('actual bounded build flags required')
    materials = {}; guards = {}
    def add(name, source, expected=None, limit=io_helpers.MAX_FILE):
        safe_member(name)
        path = plain_path(source)
        row = captured_file(path, limit=limit)
        if expected is not None and row['sha256'] != pinned_digest(expected):
            raise ValueError('actual source material SHA mismatch')
        if name in materials:
            raise ValueError('unique source material path required')
        materials[name] = path; guards[name] = row
        return row
    archives = []
    recorded = acquisition.get('sources')
    if type(recorded) is not list or {r['name'] for r in recorded} != {p['name'] for p in pins['sources']}:
        raise ValueError('actual three-source acquisition required')
    libraries = {row['name']: row for row in bundle['libraries']}
    inventory = {row['path']: row for row in build['files']}
    if set(libraries) != set(io_helpers.LIBRARIES):
        raise ValueError('actual three library source records required')
    for name in io_helpers.LIBRARIES:
        alias = owned / 'prefix/lib' / name
        original = alias.resolve(strict=True)
        original.relative_to(owned / 'prefix/lib')
        plain_path(original)
        expected = libraries[name]['upstreamBuildSHA256']
        row = captured_file(original)
        observation_guards[original] = row
        actual = row['sha256']
        if actual != expected or inventory[original.relative_to(owned).as_posix()]['sha256'] != expected:
            raise ValueError('candidate library is not this recorded source build')
        if app_before[io_helpers.FRAMEWORK + '/' + name]['sha256'] != libraries[name]['signedSHA256']:
            raise ValueError('candidate signed library inventory changed')
    if app_before[io_helpers.HELPER]['sha256'] != bundle['helperSignedSHA256']:
        raise ValueError('candidate signed helper inventory changed')
    for pin in pins['sources']:
        rows = [r for r in recorded if r['name'] == pin['name']]
        if len(rows) != 1 or rows[0].get('actualSHA256') != pin['sha256'] or rows[0].get('sha256') != pin['sha256']:
            raise ValueError('actual upstream acquisition pin differs')
        archive = owned / 'archives' / pin['filename']
        add('upstream/' + pin['filename'], archive, pin['sha256'], 16 * 1024**2)
        inspected = validate_source_archive(archive)
        archives.append(dict(name=pin['name'], version=pin['version'], url=pin['url'],
                             sha256=pin['sha256'], archiveInspection=inspected))
        notices = rows[0].get('notices')
        if not notices:
            raise ValueError('actual upstream full notices required')
        for notice in notices:
            member = safe_member(notice['sourceMember'])
            add('licenses/' + pin['name'] + '/' + member,
                owned / 'licenses' / pin['name'] / member, notice['sha256'], 4 * 1024**2)
    archive = plain_path(app_archive)
    add('application/' + archive.name, archive, app_sha, MAX_ARCHIVE)
    inspected = validate_source_archive(archive, application=True, require_full_application=True)
    for name, path, digest, heading, required_section in (
            ('GNU-GPL-3.0.txt', gpl_text, gpl_sha, 'GNU GENERAL PUBLIC LICENSE', '6. Conveying Non-Source Forms.'),
            ('GNU-LGPL-3.0.txt', lgpl_text, lgpl_sha, 'GNU LESSER GENERAL PUBLIC LICENSE', '4. Combined Works.')):
        add('licenses/' + name, path, digest, 1024**2)
        text = plain_path(path).read_text(encoding='utf-8')
        if (heading not in text or not re.search(r'Version\s+3,\s+29 June 2007', text)
                or required_section not in text or len(text) < 5000):
            raise ValueError('actual full GNU license text required')
    for name in RECIPE_FILES:
        add('build-recipes/macos-heic-cpu/' + name, RECIPE / name, limit=4 * 1024**2)
    for name in ('relink_heic_cpu.py', 'package_mac_heic_sources.py'):
        add('scripts/' + name, ROOT / 'scripts' / name, limit=4 * 1024**2)
    add('shared/source_identity.py', ROOT / 'shared/source_identity.py', limit=4 * 1024**2)
    settings = {'schemaVersion': 1, 'architecture': bundle['architecture'],
        'deploymentTarget': pins['deploymentTarget'], 'codecFlags': flags,
        'helperCompileArguments': ['clang++', '-std=c++20', '-O2', '-mmacosx-version-min=14.0',
            '-I<owned-prefix/include>', 'heic_cpu_candidate.cpp', '-L<owned-prefix/lib>', '-lheif',
            '-Wl,-rpath,@loader_path/../Frameworks/HEIC'],
        'tools': [{k: row[k] for k in ('name', 'sha256')} for row in build['tools']],
        'actualSourceBuildStatus': build['status'], 'libraries': libraries,
        'candidateFiles': io_helpers.public_rows(app_before),
        'applicationSource': {'commit': app_commit, 'sha256': app_sha, 'inspection': inspected},
        'archives': archives,
        'sourceMaterialsHashBound': True,
        'applicationBinaryReproductionVerified': False,
        'modifiedLibraryEncodeVerified': False,
        'completeLegalCorrespondingSourceCertified': False,
        'releaseApproved': False}
    if (io_helpers.tree_inventory(app) != app_before or
            any(captured_file(path) != row for path, row in observation_guards.items())):
        raise ValueError('observed build/app correspondence inputs changed')
    return materials, guards, settings, (app, app_before, observation_guards)


def package(owned_root, source_app, app_archive, app_sha, app_commit,
            gpl_text, gpl_sha, lgpl_text, lgpl_sha, output):
    target = io_helpers.output_path(output, suffix='.zip')
    materials, guards, settings, observations = source_materials(owned_root, source_app, app_archive,
        app_sha, app_commit, gpl_text, gpl_sha, lgpl_text, lgpl_sha)
    if any(target == path or target in path.parents for path in materials.values()):
        raise ValueError('output must be independent of original material inputs')
    report = {'schemaVersion': 1, 'status': 'source-materials-hash-bound-not-legal-certification',
              'originalsPreserved': False, 'releaseApproved': False,
              'files': {name: {k: row[k] for k in ('sha256', 'bytes')} for name, row in guards.items()}}
    # A failed/partial newly created ZIP remains owner-visible. No public-path
    # deletion/replacement is performed after creation, including fallback IO.
    with managed(target.open('xb')) as output_stream:
        with managed(zipfile.ZipFile(output_stream, 'w', compression=zipfile.ZIP_DEFLATED, allowZip64=True)) as archive:
            for name, original in materials.items():
                temporary = tempfile.TemporaryDirectory(prefix='heic-source-read-')
                with managed(temporary, temporary.cleanup):
                    folder = temporary.name
                    private = Path(folder).resolve() / 'material'
                    if captured_file(original, destination=private) != guards[name]:
                        raise ValueError('source material changed during packaging')
                    # The verified private FD snapshot is the only ZIP input;
                    # a retarget of the public source after read cannot slip in.
                    archive.write(private, arcname=name)
            archive.writestr('build-settings.json', json.dumps(settings, indent=2) + '\n')
            app, app_before, observation_guards = observations
            preserved = (all(captured_file(path) == guards[name] for name, path in materials.items())
                         and io_helpers.tree_inventory(app) == app_before
                         and all(captured_file(path) == row for path, row in observation_guards.items()))
            report['originalsPreserved'] = preserved
            if not preserved:
                raise ValueError('source material inputs changed during packaging')
            archive.writestr('manifest.json', json.dumps(report, indent=2) + '\n')
        output_stream.flush(); os.fsync(output_stream.fileno())
    with managed(zipfile.ZipFile(target)) as archive:
        for name, row in guards.items():
            with managed(archive.open(name)) as stream:
                if hashlib.file_digest(stream, 'sha256').hexdigest() != row['sha256']:
                    raise ValueError('packaged source member SHA readback differs')
    return dict(report, zipSHA256=captured_file(target)['sha256'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('owned-root', 'source-app', 'app-source-archive', 'gpl-text', 'lgpl-text', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    for name in ('app-source-sha256', 'app-source-commit', 'gpl-sha256', 'lgpl-sha256'):
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    result = package(args.owned_root, args.source_app, args.app_source_archive,
        args.app_source_sha256, args.app_source_commit, args.gpl_text, args.gpl_sha256,
        args.lgpl_text, args.lgpl_sha256, args.output)
    print(json.dumps({'status': result['status'], 'originalsPreserved': result['originalsPreserved'],
                      'zipSHA256': result['zipSHA256'], 'releaseApproved': False}))


if __name__ == '__main__':
    main()
