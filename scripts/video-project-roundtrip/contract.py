"""Synthetic-only transport contract. No decoder, network or native imports."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
KINDS = ('nonzero-origin', 'video-negative-twelfth-audio-negative-quarter')
HASHES = (
    '797a1f51c464b0ef5bce39f2a14114c16327100eb3cc8446af5050c130dc8acd',
    '386afa793fc353bba01ded7954490cbc2c08e9582e114f519fd47f361fc2ad79')
MANIFEST_SHA = 'f1779cbc24d9f7a0451b182e028f587db1113f5f605ae80f22b6efa0d5a45f0f'
EDITED_NAME = 'Windows에서 명시 변경'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read(path, maximum=50 * 1024 * 1024):
    path = Path(path)
    require(not path.is_symlink() and path.is_file(), 'Only regular nonsymlink files are permitted')
    with path.open('rb') as stream:
        data = stream.read(maximum + 1)
    require(len(data) <= maximum, 'Transport file exceeds its bounded byte limit')
    return data


def sha(data):
    return hashlib.sha256(data).hexdigest()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'Duplicate transport JSON key')
        result[key] = value
    return result


def tree(data):
    return json.loads(data, object_pairs_hook=unique_object,
                      parse_constant=lambda _: (_ for _ in ()).throw(ValueError('Nonfinite JSON')))


def fixture_bytes():
    folder = ROOT / 'shared/fixtures/video-timelines'
    require(sha(read(folder / 'manifest.json')) == MANIFEST_SHA, 'Fixture manifest SHA mismatch')
    result = {}
    for kind, digest in zip(KINDS, HASHES):
        data = read(folder / (kind + '.mov'))
        require(sha(data) == digest, 'Fixture source SHA mismatch')
        result[kind] = data
    return result


def owned(path, *, empty=False):
    path = Path(path).absolute()
    require(not path.is_symlink() and path.is_dir(), 'Owned directory is missing or a symlink')
    resolved = path.resolve(strict=True)
    require(resolved.is_relative_to((ROOT / '.build').resolve(strict=True)) and
            resolved != (ROOT / '.build').resolve(strict=True), 'Directory must be below repository .build')
    if empty:
        require(not any(resolved.iterdir()), 'Output directory must be empty')
    return resolved


def packet(path, stage):
    value = tree(read(Path(path) / 'packet.json', 64 * 1024))
    require(set(value) == {'schemaVersion', 'stage', 'host', 'status', 'cases'}, 'Unexpected packet keys')
    require(type(value['schemaVersion']) is int and value['schemaVersion'] == 1 and
            value['stage'] == stage and value['status'] == 'completed' and
            value['host'] == ('windows' if stage == 'windows-edit' else 'macos'), 'Incomplete or wrong-host packet')
    require(isinstance(value['cases'], list) and len(value['cases']) == len(KINDS), 'Incomplete case inventory')
    keys = {'kind', 'sourceSHA256', 'macProjectSHA256'}
    if stage != 'mac-emit': keys.add('windowsProjectSHA256')
    if stage == 'mac-verify': keys.add('macReturnProjectSHA256')
    for kind, digest, row in zip(KINDS, HASHES, value['cases']):
        require(set(row) == keys and row['kind'] == kind and row['sourceSHA256'] == digest, 'Unexpected transport row')
        for key in keys - {'kind'}:
            require(isinstance(row[key], str) and len(row[key]) == 64 and
                    all(c in '0123456789abcdef' for c in row[key]), 'Invalid digest')
        filenames = [('macProjectSHA256', '.mac.bluraction')]
        if stage != 'mac-emit': filenames.append(('windowsProjectSHA256', '.windows.bluraction'))
        if stage == 'mac-verify': filenames = [('macReturnProjectSHA256', '.mac-return.bluraction')]
        for key, suffix in filenames:
            require(sha(read(Path(path) / (kind + suffix), 20 * 1024 * 1024)) == row[key], 'Project byte digest mismatch')
        require(sha(read(Path(path) / (kind + '.mov'))) == digest, 'Transport media digest mismatch')
    expected = {'packet.json'}
    for kind in KINDS:
        if stage == 'mac-verify': expected.update((kind + '.mov', kind + '.mac-return.bluraction'))
        else:
            expected.update((kind + '.mov', kind + '.mac.bluraction'))
            if stage == 'windows-edit': expected.add(kind + '.windows.bluraction')
    if stage == 'windows-edit': expected.add('observations.json')
    require({p.name for p in Path(path).iterdir()} == expected, 'Unexpected or missing payload files')
    return value


def write_new(path, data):
    with Path(path).open('xb') as stream:
        stream.write(data)
