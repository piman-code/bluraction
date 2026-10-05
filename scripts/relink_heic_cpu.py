#!/usr/bin/env python3
"""Replace interface-compatible HEIC libraries in a NEW, locally signed copy.

No original, installation, system setting or product integrity policy is changed.
This tool does not execute the app/helper and does not certify codec equivalence,
source correspondence, notarization or redistribution compliance.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import selectors
import signal
import stat
import subprocess
import sys
import time

LIBRARIES = ('libheif.1.dylib', 'libde265.0.dylib', 'libkvazaar.7.dylib')
HELPER = 'Contents/Helpers/HEICCPUEncoder'
FRAMEWORK = 'Contents/Frameworks/HEIC'
RESOURCES = 'Contents/Resources/HEICCPU'
MAX_FILE = 512 * 1024**2
MAX_TOTAL = 1024**3
MAX_FILES = 20000
_identity_spec = importlib.util.spec_from_file_location('_mac_heic_source_identity',
    Path(__file__).resolve().parents[1] / 'shared/source_identity.py')
_source_identity = importlib.util.module_from_spec(_identity_spec)
sys.modules[_identity_spec.name] = _source_identity
_identity_spec.loader.exec_module(_source_identity)


def cleanup_preserving_primary(action):
    primary = sys.exception()
    try:
        action()
    except BaseException as cleanup:
        if primary is None:
            raise
        if cleanup is not primary:
            primary.add_note('owned cleanup also failed: ' + type(cleanup).__name__)


def plain_path(value, *, directory=False):
    path = Path(value).absolute()
    # Fail closed on aliases/links rather than following a retargetable input.
    if path.resolve(strict=True) != path:
        raise ValueError('plain canonical path required')
    info = path.lstat()
    if not (stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)):
        raise ValueError('plain directory/file required')
    return path


def identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_nlink,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def captured_file(value, *, destination=None, limit=MAX_FILE):
    """Hash/copy one no-follow FD and guard pathname+FD before/after streaming."""
    path = plain_path(value)
    before = path.lstat()
    path_snapshot = _source_identity.stat_snapshot(before, domain='path')
    if not 0 <= before.st_size <= limit:
        raise ValueError('bounded input file required')
    descriptor = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
    digest = hashlib.sha256(); size = 0; out = None
    try:
        fd_before = os.fstat(descriptor)
        fd_snapshot = _source_identity.stat_snapshot(fd_before, domain='descriptor')
        if (not _source_identity.path_matches_descriptor(path_snapshot, fd_snapshot)
                or fd_before.st_nlink != before.st_nlink):
            raise ValueError('input identity changed before read')
        if destination is not None:
            target = Path(destination)
            plain_path(target.parent, directory=True)
            out = target.open('xb')
        while True:
            block = os.read(descriptor, 1024**2)
            if not block:
                break
            size += len(block)
            if size > limit or size > before.st_size:
                raise ValueError('input grew during read')
            digest.update(block)
            if out is not None:
                out.write(block)
        fd_after = os.fstat(descriptor)
        if (size != before.st_size or fd_after.st_nlink != fd_before.st_nlink
                or not _source_identity.same_domain(fd_snapshot,
                    _source_identity.stat_snapshot(fd_after, domain='descriptor'))):
            raise ValueError('input changed during read')
        if plain_path(path) != path or identity(path.lstat()) != identity(before):
            raise ValueError('input pathname changed during read')
        if out is not None:
            os.fchmod(out.fileno(), stat.S_IMODE(before.st_mode))
            out.flush(); os.fsync(out.fileno())
    finally:
        try:
            if out is not None:
                cleanup_preserving_primary(out.close)
        finally:
            cleanup_preserving_primary(lambda: os.close(descriptor))
    return {'sha256': digest.hexdigest(), 'bytes': size,
            'mode': stat.S_IMODE(before.st_mode), 'identity': identity(before)}


def tree_inventory(value, *, destination=None):
    root = plain_path(value, directory=True)
    rows = {}; total = 0
    for parent, directories, files in os.walk(root, followlinks=False):
        folder = plain_path(parent, directory=True)
        relative = folder.relative_to(root)
        if len(relative.parts) > 64:
            raise ValueError('bounded tree depth required')
        for name in sorted(directories):
            plain_path(folder / name, directory=True)
        if destination is not None:
            target_folder = Path(destination) / relative
            if relative.parts:
                target_folder.mkdir()
        for name in sorted(files):
            member = (relative / name).as_posix()
            if len(rows) >= MAX_FILES:
                raise ValueError('bounded tree file count required')
            row = captured_file(folder / name,
                destination=Path(destination) / member if destination is not None else None)
            total += row['bytes']
            if total > MAX_TOTAL:
                raise ValueError('bounded tree bytes required')
            rows[member] = row
    return rows


def output_path(value, *, suffix):
    path = Path(value).absolute()
    if path.suffix != suffix or path.exists() or path.is_symlink():
        raise ValueError('new exclusive output with expected suffix required')
    forbidden = ('/Applications', '/System', '/Library', '/usr', '/bin', '/sbin')
    if any(path == Path(p) or Path(p) in path.parents for p in forbidden):
        raise ValueError('system/installation output forbidden')
    if Path.home() / 'Applications' in path.parents:
        raise ValueError('user installation output forbidden')
    parent = plain_path(path.parent, directory=True)
    return parent / path.name


def run_tool(*arguments):
    # Only fixed Apple tools; no shell/PATH lookup or app/helper execution.
    if arguments[0] not in ('/usr/bin/otool', '/usr/bin/lipo',
                            '/usr/bin/install_name_tool', '/usr/bin/codesign'):
        raise ValueError('fixed Apple inspection/signing tool required')
    child = subprocess.Popen(arguments, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             start_new_session=True)
    selector = selectors.DefaultSelector(); output = bytearray()
    deadline = time.monotonic() + 120
    try:
        selector.register(child.stdout, selectors.EVENT_READ)
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ValueError('native inspection/signing deadline exceeded')
            if not selector.select(min(.2, remaining)):
                continue
            block = os.read(child.stdout.fileno(), 65536)
            if not block:
                break
            output.extend(block)
            if len(output) > 4 * 1024**2:
                raise ValueError('native inspection/signing output limit exceeded')
        if child.wait(timeout=max(.001, deadline-time.monotonic())):
            raise ValueError('native inspection/signing failed')
        return output.decode('utf-8', errors='strict')
    finally:
        # Terminate only this newly owned group and reap its direct child.
        # The caller's outer watchdog remains necessary for native failures.
        def stop_group():
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        try:
            cleanup_preserving_primary(stop_group)
        finally:
            try:
                cleanup_preserving_primary(lambda: child.wait(timeout=10))
            finally:
                try:
                    cleanup_preserving_primary(selector.close)
                finally:
                    cleanup_preserving_primary(child.stdout.close)


def runtime_paths(path, command=run_tool):
    lines = command('/usr/bin/otool', '-l', str(path)).splitlines()
    paths = []
    for index, line in enumerate(lines):
        if line.strip() == 'cmd LC_RPATH':
            if index + 2 >= len(lines) or not lines[index + 2].strip().startswith('path '):
                raise ValueError('invalid Mach-O runtime path command')
            paths.append(lines[index + 2].strip()[5:].split(' (')[0])
    return paths


def inspect_macho(path, architecture, *, helper=False, command=run_tool):
    if architecture not in ('arm64', 'x86_64'):
        raise ValueError('supported explicit architecture required')
    arches = command('/usr/bin/lipo', '-archs', str(path)).strip().split()
    if arches != [architecture]:
        raise ValueError('exact single source architecture required')
    lines = command('/usr/bin/otool', '-L', str(path)).splitlines()
    if len(lines) < 2:
        raise ValueError('Mach-O dependencies missing')
    links = [line.strip().split(' (')[0] for line in lines[1:]]
    allowed = {'@rpath/' + name for name in LIBRARIES}
    def system_link(link):
        parts = PurePosixPath(link)
        return (link.startswith(('/usr/lib/', '/System/Library/'))
                and str(parts) == link and '..' not in parts.parts)
    if any(not (link in allowed or system_link(link))
           for link in links):
        raise ValueError('library outside known HEIC/system link closure')
    paths = runtime_paths(path, command)
    expected = ['@loader_path/../Frameworks/HEIC'] if helper else []
    if paths != expected:
        raise ValueError('noncanonical bundle runtime path')
    if helper and '@rpath/libheif.1.dylib' not in links:
        raise ValueError('helper must link the replaced libheif')
    return links


def public_rows(rows):
    return {name: {key: row[key] for key in ('sha256', 'bytes', 'mode')}
            for name, row in rows.items()}


def read_json(value, limit=20 * 1024**2):
    path = plain_path(value)
    before = captured_file(path, limit=limit)
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != before['sha256'] or captured_file(path, limit=limit) != before:
        raise ValueError('JSON input changed during read')
    def pairs(items):
        result = {}
        for key, item in items:
            if key in result:
                raise ValueError('duplicate metadata JSON key')
            result[key] = item
        return result
    def constant(_value):
        raise ValueError('nonfinite JSON metadata')
    return json.loads(data, object_pairs_hook=pairs,
                      parse_constant=constant)


def relink(source_app, replacements, destination, command=run_tool):
    """All mutations belong to a new owner copy. Failed copies stay explicit."""
    source = plain_path(source_app, directory=True)
    if source.suffix != '.app' or set(replacements) != set(LIBRARIES):
        raise ValueError('one app and exactly three explicit library inputs required')
    target = output_path(destination, suffix='.app')
    if source == target or source in target.parents or target in source.parents:
        raise ValueError('independent output outside source app required')
    inputs = {name: plain_path(path) for name, path in replacements.items()}
    if any(target in path.parents for path in inputs.values()):
        raise ValueError('replacement input must be outside output')
    baseline = tree_inventory(source)
    manifest_name = RESOURCES + '/manifest.json'
    for required in ('Contents/Info.plist', 'Contents/MacOS/BlurAction', HELPER, manifest_name):
        if required not in baseline:
            raise ValueError('complete known source app required')
    manifest = read_json(source / manifest_name)
    architecture = manifest['architecture']
    info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
    if info.get('BlurActionHEICCPUEncoderSHA256') != baseline[HELPER]['sha256']:
        raise ValueError('original helper integrity mismatch')
    expected_libs = info.get('BlurActionHEICCPULibrarySHA256')
    if type(expected_libs) is not dict or set(expected_libs) != set(LIBRARIES):
        raise ValueError('original exact library integrity map required')
    for name in LIBRARIES:
        if baseline.get(FRAMEWORK + '/' + name, {}).get('sha256') != expected_libs[name]:
            raise ValueError('original library integrity mismatch')
    command('/usr/bin/codesign', '--verify', '--strict', '--deep', str(source))
    original_inputs = {name: captured_file(path) for name, path in inputs.items()}
    # File creation is exclusive, including the journal; retain failures for
    # owner review instead of deleting a public path which could be replaced.
    journal = target.with_name(target.name + '.relink.json')
    descriptor = os.open(journal, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    journal_stream = os.fdopen(descriptor, 'w', encoding='utf-8')
    report = {'schemaVersion': 1, 'status': 'failed-or-incomplete',
              'originalApp': source.name, 'modifiedApp': target.name,
              'inputFiles': public_rows(original_inputs), 'architecture': architecture,
              'codeSigning': 'local-ad-hoc', 'notarized': False,
              'sourceCorrespondenceVerified': False, 'encodeVerified': False,
              'releaseApproved': False, 'originalsPreserved': False}
    try:
        target.mkdir(mode=0o700)
        copied = tree_inventory(source, destination=target)
        if copied != baseline:
            raise ValueError('original app changed while copied')
        dependencies = {}
        for name, original in inputs.items():
            path = target / FRAMEWORK / name
            # Delete only the just-copied, manifest-recorded owner file. Never
            # unlink an input or an unknown public destination.
            if captured_file(path)['sha256'] != expected_libs[name]:
                raise ValueError('owner-copy library changed before replacement')
            path.unlink()
            if captured_file(original, destination=path) != original_inputs[name]:
                raise ValueError('replacement source changed during copy')
            # Kvazaar's plain CWD rpaths from its source build are unnecessary;
            # canonicalize only this owned copy before inspection/signing.
            for rpath in runtime_paths(path, command):
                command('/usr/bin/install_name_tool', '-delete_rpath', rpath, str(path))
            dependencies[FRAMEWORK + '/' + name] = inspect_macho(path, architecture, command=command)
        helper = target / HELPER
        dependencies[HELPER] = inspect_macho(helper, architecture, helper=True, command=command)
        hashes = {}
        for name in LIBRARIES:
            path = target / FRAMEWORK / name
            command('/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', str(path))
            command('/usr/bin/codesign', '--verify', '--strict', str(path))
            hashes[name] = captured_file(path)['sha256']
        command('/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', str(helper))
        command('/usr/bin/codesign', '--verify', '--strict', str(helper))
        helper_sha = captured_file(helper)['sha256']
        info['BlurActionHEICCPUEncoderSHA256'] = helper_sha
        info['BlurActionHEICCPULibrarySHA256'] = hashes
        with (target / 'Contents/Info.plist').open('wb') as stream:
            plistlib.dump(info, stream, sort_keys=False)
        # Preserve historical upstream records but distinguish replacement
        # bytes; do not imply they came from the unchanged upstream source.
        manifest['originalLibraries'] = manifest['libraries']
        manifest['replacementLibraries'] = [dict(name=name, inputSHA256=original_inputs[name]['sha256'],
                                                    signedSHA256=hashes[name]) for name in LIBRARIES]
        manifest['libraries'] = manifest['replacementLibraries']
        manifest['sourcesDescribeOriginalBuild'] = True
        manifest['sourceCorrespondenceVerified'] = False
        manifest['helperSignedSHA256'] = helper_sha
        manifest['dependencies'] = dependencies
        manifest['libraryReplacementAndRelinkVerified'] = False
        manifest['notarized'] = False
        (target / manifest_name).write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
        command('/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', str(target))
        command('/usr/bin/codesign', '--verify', '--strict', '--deep', str(target))
        report.update(status='new-owner-copy-relinked-and-signature-verified',
                      libraries=hashes, helperSHA256=helper_sha, dependencies=dependencies,
                      modifiedFiles=public_rows(tree_inventory(target)))
        return report
    finally:
        primary = sys.exception()
        verification_error = None
        try:
            preserved = (tree_inventory(source) == baseline and
                         all(captured_file(path) == original_inputs[name] for name, path in inputs.items()))
        except BaseException as error:
            preserved = False; verification_error = error
        report['originalsPreserved'] = preserved
        if not preserved:
            report['status'] = 'failed-input-changed'
        try:
            json.dump(report, journal_stream, indent=2); journal_stream.write('\n')
            journal_stream.flush(); os.fsync(journal_stream.fileno())
        except BaseException as error:
            if primary is None:
                raise
            primary.add_note('owned relink journal also failed: ' + type(error).__name__)
        finally:
            cleanup_preserving_primary(journal_stream.close)
        if not preserved and primary is None:
            raise ValueError('read-only original inputs changed during operation') from verification_error
        if not preserved and primary is not None:
            primary.add_note('original input preservation could not be confirmed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-app', type=Path, required=True)
    parser.add_argument('--libheif', type=Path, required=True)
    parser.add_argument('--libde265', type=Path, required=True)
    parser.add_argument('--libkvazaar', type=Path, required=True)
    parser.add_argument('--output-app', type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != 'darwin':
        raise ValueError('actual macOS native inspection/signing required')
    report = relink(args.source_app, dict(zip(LIBRARIES,
        (args.libheif, args.libde265, args.libkvazaar))), args.output_app)
    print(json.dumps({'status': report['status'], 'originalsPreserved': report['originalsPreserved'],
                      'notarized': False, 'encodeVerified': False}))


if __name__ == '__main__':
    main()
