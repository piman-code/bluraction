#!/usr/bin/env python3
"""Stage an owned HEIC source build into a candidate app, without installing it.

Only the three recorded shared libraries are copied. The helper is rebuilt from
this checkout and linked to bundle-relative libraries. Reports/notices preserve
the upstream source identity; final license/source distribution is a release gate.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import platform
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
RECIPE = ROOT / 'build-recipes/macos-heic-cpu'
LIBRARIES = ('libheif.1.dylib', 'libde265.0.dylib', 'libkvazaar.7.dylib')


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def command(*arguments):
    return subprocess.check_output(arguments, stderr=subprocess.STDOUT, timeout=120).decode()


def runtime_paths(path):
    lines = command('/usr/bin/otool', '-l', str(path)).splitlines()
    return [lines[index + 2].strip().split(' (')[0].removeprefix('path ')
            for index, line in enumerate(lines) if line.strip() == 'cmd LC_RPATH']


def relative_member(value):
    if not isinstance(value, str) or not value or '\\' in value:
        raise ValueError('Plain relative notice member required')
    path = PurePosixPath(value)
    if path.is_absolute() or '..' in path.parts or '.' in path.parts or str(path) != value:
        raise ValueError('Canonical relative notice member required')
    return path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bundle', required=True, type=Path)
    parser.add_argument('--owned-root', required=True, type=Path)
    args = parser.parse_args()
    if sys.platform != 'darwin' or platform.machine() not in ('arm64', 'x86_64'):
        raise ValueError('Actual supported Mac build host required')
    bundle, owned = args.bundle.absolute(), args.owned_root.absolute()
    if (bundle != ROOT / '.build/BlurAction.app' or
            bundle.resolve() != bundle or owned.resolve() != owned or
            not (bundle / 'Contents/MacOS/BlurAction').is_file()):
        raise ValueError('Only this checkout build candidate may be assembled')
    owned.relative_to(ROOT / '.build')
    pins = json.loads((RECIPE / 'pins.json').read_text())
    acquisition = json.loads((owned / 'reports/acquisition.json').read_text())
    build = json.loads((owned / 'reports/build.json').read_text())
    if sorted(row['name'] for row in acquisition['sources']) != sorted(row['name'] for row in pins['sources']):
        raise ValueError('Only the three pinned acquired sources are permitted')
    if build['status'] != 'source-build-complete-unverified-codec':
        raise ValueError('Completed source-build inventory required')
    for row in pins['sources']:
        recorded = [r for r in acquisition['sources'] if r['name'] == row['name']]
        if (len(recorded) != 1 or recorded[0]['sha256'] != row['sha256'] or
                recorded[0]['actualSHA256'] != row['sha256'] or
                sha(owned / 'archives' / row['filename']) != row['sha256']):
            raise ValueError('Actual upstream source pin mismatch')
    inventory = {row['path']: row for row in build['files']}
    framework = bundle / 'Contents/Frameworks/HEIC'
    helpers = bundle / 'Contents/Helpers'
    resources = bundle / 'Contents/Resources/HEICCPU'
    for path in (framework, helpers, resources):
        if path.exists():
            raise ValueError('New candidate helper destination required; preserve old bundle first')
        path.mkdir(parents=True)
    rows = []
    for name in LIBRARIES:
        original = (owned / 'prefix/lib' / name).resolve(strict=True)
        original.relative_to(owned / 'prefix/lib')
        recorded = inventory[original.relative_to(owned).as_posix()]
        if original.is_symlink() or sha(original) != recorded['sha256']:
            raise ValueError('Recorded library bytes changed')
        target = framework / name
        shutil.copyfile(original, target)
        rows.append(dict(name=name, upstreamBuildSHA256=sha(original)))
        # Kvazaar's upstream shared library has CWD-relative search paths. They
        # are unnecessary for its system-only dependencies; remove them from the
        # copied candidate before recording/signing. Original bytes stay intact.
        removed_rpaths = runtime_paths(target)
        for rpath in removed_rpaths:
            command('/usr/bin/install_name_tool', '-delete_rpath', rpath, str(target))
        if runtime_paths(target):
            raise ValueError('Copied library runtime paths must be empty')
        rows[-1]['removedRuntimePaths'] = removed_rpaths
    helper = helpers / 'HEICCPUEncoder'
    command('/usr/bin/xcrun', 'clang++', '-std=c++20', '-O2',
            '-mmacosx-version-min=14.0', '-I' + str(owned / 'prefix/include'),
            str(RECIPE / 'heic_cpu_candidate.cpp'), '-L' + str(owned / 'prefix/lib'),
            '-lheif', '-Wl,-rpath,@loader_path/../Frameworks/HEIC', '-o', str(helper))
    # Verify the actual link closure before signatures; no external prefix/PATH
    # is a runtime fallback. System dependencies remain under OS ownership.
    dependencies = {}
    for path in [helper] + [framework / name for name in LIBRARIES]:
        output = command('/usr/bin/otool', '-L', str(path))
        links = [line.strip().split(' (')[0] for line in output.splitlines()[1:]]
        if any(not (link in {'@rpath/' + n for n in LIBRARIES} or
                    link.startswith(('/usr/lib/', '/System/Library/'))) for link in links):
            raise ValueError('Unowned runtime library dependency')
        architectures = command('/usr/bin/lipo', '-archs', str(path)).strip().split()
        if architectures != [platform.machine()]:
            raise ValueError('Native architecture mismatch; no universal claim')
        dependencies[path.relative_to(bundle).as_posix()] = links
    actual_rpaths = runtime_paths(helper)
    if actual_rpaths != ['@loader_path/../Frameworks/HEIC']:
        raise ValueError('Only bundle-relative helper runtime path permitted')
    for row in rows:
        path = framework / row['name']
        command('/usr/bin/codesign', '--force', '--sign', '-', str(path))
        command('/usr/bin/codesign', '--verify', '--strict', str(path))
        row['signedSHA256'] = sha(path)
    command('/usr/bin/codesign', '--force', '--sign', '-', str(helper))
    command('/usr/bin/codesign', '--verify', '--strict', str(helper))
    notices = []
    for source in acquisition['sources']:
        for notice in source['notices']:
            member = relative_member(notice['sourceMember'])
            original = owned / 'licenses' / source['name'] / member
            original.relative_to(owned / 'licenses')
            if original.resolve() != original or not original.is_file():
                raise ValueError('Plain contained original notice required')
            if sha(original) != notice['sha256']:
                raise ValueError('Recorded upstream notice changed')
            target = resources / 'licenses' / source['name'] / member
            target.relative_to(resources)
            if target.resolve() != target or target.exists():
                raise ValueError('Fresh contained candidate notice required')
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(original, target)
            notices.append(dict(path=target.relative_to(resources).as_posix(), sha256=sha(target)))
    manifest = dict(schemaVersion=1, architecture=platform.machine(),
                    helperSourceSHA256=sha(RECIPE / 'heic_cpu_candidate.cpp'),
                    helperSignedSHA256=sha(helper), libraries=rows, dependencies=dependencies,
                    sources=pins['sources'], notices=notices,
                    codeSigning='local-ad-hoc', notarized=False,
                    completeCorrespondingSourceDistribution=False,
                    libraryReplacementAndRelinkVerified=False, fullHEICSupportVerified=False)
    (resources / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    info_path = bundle / 'Contents/Info.plist'
    with info_path.open('rb') as stream:
        info = plistlib.load(stream)
    info['BlurActionHEICCPUEncoderSHA256'] = manifest['helperSignedSHA256']
    info['BlurActionHEICCPULibrarySHA256'] = {row['name']: row['signedSHA256'] for row in rows}
    with info_path.open('wb') as stream:
        plistlib.dump(info, stream, sort_keys=False)
    print(json.dumps(dict(helperSHA256=manifest['helperSignedSHA256'], libraries=rows,
                          operatingInstallChanged=False)))


if __name__ == '__main__':
    main()
