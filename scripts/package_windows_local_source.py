"""Create a reviewed local source snapshot without invoking or reading Git.

This is source identity evidence, not a release or license approval. An explicit
file list binds every selected path to reviewed bytes; unlisted files are never
copied. Existing output directories are never reused.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import stat
import sys
import zipfile

if __package__ in (None, ''):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from shared import windows_package_receipt as gate

COMMENT_PREFIX = b'bluraction-local-snapshot-v1:'
TEXT_SUFFIXES = {'.py', '.ps1', '.md', '.txt', '.json', '.jsonl', '.yaml',
                 '.yml', '.toml', '.ini', '.cfg', '.iss', '.sh', '.swift',
                 '.bluraction', '.csv', '.xml', '.html', '.css', '.js', '.bat'}
MEDIA_SUFFIXES = {'.png', '.jpg', '.jpeg', '.pdf', '.heic', '.heif', '.webp',
                  '.bmp', '.tif', '.tiff', '.gif', '.mp4', '.mov', '.mkv',
                  '.avi', '.wav', '.m4a', '.mp3'}
NATIVE_MAGIC = {b'\x7fELF', b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe',
                b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe'}


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode('utf-8')


def allowed_path(name):
    name = gate.canonical(name)
    # Verification inventories hash this ordinary source policy file. This is
    # not permission to read repository metadata or any other hidden path.
    if name == '.gitattributes':
        return name
    parts = PurePosixPath(name).parts
    for part in parts:
        folded = part.casefold()
        if (folded.startswith(('.', 'qa-', 'backup')) or
                folded in {'__pycache__', 'node_modules', 'useroriginals', 'originals',
                           '원본', '백업', '사용자원본'} or folded.endswith('.app')):
            raise ValueError('private/generated source path forbidden: ' + name)
    if name in {'LICENSE', 'NOTICE', 'README.md'}:
        return name
    if not name.startswith(('platforms/windows/', 'scripts/', 'shared/', 'Tests/',
                            'docs/', 'build-recipes/windows-owned-ffmpeg/',
                            'build-recipes/macos-heic-cpu/')):
        raise ValueError('path outside curated Windows source roots: ' + name)
    suffix = PurePosixPath(name).suffix.lower()
    fixture = name.startswith('shared/fixtures/') and suffix in MEDIA_SUFFIXES
    license_name = parts[-1].upper().startswith(('LICENSE', 'COPYING', 'NOTICE'))
    authored_cpp = name == 'build-recipes/macos-heic-cpu/heic_cpu_candidate.cpp'
    if suffix not in TEXT_SUFFIXES and not fixture and not license_name and not authored_cpp:
        raise ValueError('unsupported source file type: ' + name)
    return name


def checked_bytes(root, row):
    path = gate.contained(root, row['path'])
    with gate.stable_read(path) as stream:
        data = stream.read(gate.MAX_FILE + 1)
    if len(data) != row['bytes'] or hashlib.sha256(data).hexdigest() != row['sha256']:
        raise ValueError('reviewed source bytes changed: ' + row['path'])
    if data[:2] == b'MZ' or data[:4] in NATIVE_MAGIC or data.startswith(b'!<arch>\n'):
        raise ValueError('compiled object disguised as source: ' + row['path'])
    if not (row['path'].startswith('shared/fixtures/') and
            PurePosixPath(row['path']).suffix.lower() in MEDIA_SUFFIXES):
        data.decode('utf-8-sig')
        if b'\0' in data:
            raise ValueError('binary content in text source: ' + row['path'])
    return data


def selection(root, file_list):
    value = gate.read_json(file_list)
    if (type(value) is not dict or set(value) != {'schema_version', 'files'} or
            type(value['schema_version']) is not int or value['schema_version'] != 1 or
            type(value['files']) is not list or not 0 < len(value['files']) <= gate.MAX_ROWS):
        raise ValueError('explicit reviewed schema_version 1 file list required')
    rows, names, total = [], set(), 0
    for row in value['files']:
        if type(row) is not dict or set(row) != {'path', 'bytes', 'sha256'}:
            raise ValueError('exact reviewed path/bytes/sha256 row required')
        name = allowed_path(row['path'])
        if name.casefold() in names:
            raise ValueError('duplicate/case-colliding source path')
        names.add(name.casefold())
        if type(row['bytes']) is not int or not 0 <= row['bytes'] <= gate.MAX_FILE:
            raise ValueError('bounded source byte count required')
        gate.hash_value(row['sha256'])
        total += row['bytes']
        if total > gate.MAX_EXPANDED:
            raise ValueError('bounded source snapshot required')
        checked_bytes(root, row)
        rows.append(dict(row))
    # A file cannot also be an ancestor directory on case-insensitive Windows.
    for row in rows:
        for parent in PurePosixPath(row['path']).parents:
            if parent.as_posix().casefold() in names:
                raise ValueError('source file/directory path collision')
    return sorted(rows, key=lambda row: row['path'])


def package(*, source_root, file_list, output):
    root = gate.plain(source_root, directory=True)
    rows = selection(root, file_list)
    output = Path(output).absolute()
    gate.plain(output.parent, directory=True)
    if output.exists() or output.is_symlink():
        raise ValueError('fresh output directory required')
    manifest = {'schema_version': 1, 'source_kind': 'local-snapshot', 'files': rows}
    encoded = json_bytes(manifest)
    manifest_sha = hashlib.sha256(encoded).hexdigest()
    output.mkdir()
    archive_path = output / 'source.zip'
    with zipfile.ZipFile(archive_path, 'x', compression=zipfile.ZIP_STORED) as archive:
        archive.comment = COMMENT_PREFIX + manifest_sha.encode('ascii')
        for row in rows:
            entry = zipfile.ZipInfo(row['path'], date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = (stat.S_IFREG | 0o644) << 16
            archive.writestr(entry, checked_bytes(root, row))
    gate.source_identity(archive_path, source_root=root)
    with gate.stable_read(archive_path) as stream, zipfile.ZipFile(stream) as archive:
        members = gate.zip_members(archive)
        if len(members) != len(rows):
            raise ValueError('source archive census mismatch')
        for row in rows:
            member = members[row['path'].lower()]
            if member.file_size != row['bytes'] or gate.member_sha(archive, member) != row['sha256']:
                raise ValueError('source archive content mismatch')
    for row in rows:
        checked_bytes(root, row)
    # Publish success evidence only after all source and archive checks pass.
    (output / 'source-manifest.json').write_bytes(encoded)
    evidence = {'schema_version': 1, 'source_kind': 'local-snapshot',
                'status': 'local-source-identity-verified',
                'app_source': {'path': 'source.zip', 'bytes': archive_path.stat().st_size,
                               'sha256': gate.sha(archive_path)},
                'source_manifest': {'path': 'source-manifest.json', 'bytes': len(encoded),
                                    'sha256': manifest_sha},
                'file_count': len(rows), 'release_review': 'pending'}
    (output / 'source-evidence.json').write_bytes(json_bytes(evidence))
    return evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', required=True, type=Path)
    parser.add_argument('--file-list', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    try:
        evidence = package(source_root=args.source_root, file_list=args.file_list, output=args.output)
    except (ValueError, OSError, UnicodeError, zipfile.BadZipFile) as error:
        parser.exit(1, 'Local source snapshot failed: ' + str(error) + '\n')
    print(json.dumps(evidence, ensure_ascii=False, sort_keys=True))


if __name__ == '__main__':
    main()
