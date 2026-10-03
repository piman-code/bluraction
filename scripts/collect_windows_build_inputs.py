"""Observe installed Windows build inputs; no acquisition or release approval.

Use after pip download and an offline pip install --report. Only the compact
result is suitable for CI upload: raw report URLs and local paths are omitted.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from urllib.parse import unquote, urlsplit

if __package__ in (None, ''):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from shared.windows_package_receipt import (
    PINS, canonical, hash_value, normalize, plain, read_json,
    runtime_observation, sha, wheel_identity,
)


def collect(wheelhouse, pip_report, runtime):
    """Pure observation seam for synthetic tests; CLI always observes its host."""
    wheelhouse = plain(wheelhouse, directory=True)
    pip_report = plain(pip_report)
    before_report = sha(pip_report)
    report = read_json(pip_report)
    if (runtime.get('host') != 'win32' or runtime.get('architecture') not in ('amd64', 'x86_64')
            or runtime.get('implementation') != 'cpython'
            or runtime.get('cache_tag') != 'cpython-314'
            or runtime.get('gil_disabled') is not False
            or not str(runtime.get('version', '')).startswith('3.14.')):
        raise ValueError('Actual standard Windows x64 CPython 3.14 required')
    hash_value(runtime.get('executable_sha256'))
    if report.get('version') != '1' or not isinstance(report.get('install'), list) or not report['install']:
        raise ValueError('Nonempty pip report version 1 required')
    if len(report['install']) > 1000:
        raise ValueError('Too many report entries')
    observed, files, distributions = [], set(), {}
    for entry in report['install']:
        info = entry['metadata']
        name, version = normalize(info['name']), info['version']
        if name in distributions or not isinstance(version, str) or not version or len(version) > 128:
            raise ValueError('Unique bounded distribution identity required')
        download = entry['download_info']
        url = urlsplit(download['url'])
        if url.scheme not in ('https', 'file') or url.username or url.password or url.query or url.fragment:
            raise ValueError('Uncredentialed artifact URL without query required')
        filename = unquote(url.path.rsplit('/', 1)[-1])
        canonical(filename)
        if '/' in filename or not filename.endswith('.whl') or filename.lower() in files:
            raise ValueError('Unique plain wheel filename required')
        path = plain(wheelhouse / filename)
        digest = hash_value(download['archive_info']['hashes']['sha256'])
        if sha(path) != digest:
            raise ValueError('Downloaded wheel differs from install report')
        row = {'distribution': name, 'version': version, 'filename': filename,
               'bytes': path.stat().st_size, 'sha256': digest}
        try:
            wheel_identity(path, row)
        except ValueError as error:
            raise ValueError(f'Wheel metadata rejected for {filename}: {error}') from error
        if runtime.get('distributions', {}).get(name) != version:
            raise ValueError('Installed metadata differs from selected wheel')
        observed.append(row)
        distributions[name] = version
        files.add(filename.lower())
    if not PINS.keys() <= distributions.keys():
        raise ValueError('Complete runtime and packaging pin set required in report')
    # No unreported wheel may silently become a later build input.
    actual = {p.name.lower() for p in wheelhouse.iterdir()}
    if actual != files:
        raise ValueError('Wheelhouse differs from exact reported wheel set')
    for row in observed:
        if sha(wheelhouse / row['filename']) != row['sha256']:
            raise ValueError('Wheel changed while collecting evidence')
    if sha(pip_report) != before_report:
        raise ValueError('Install report changed while collecting evidence')
    safe_runtime = {key: runtime[key] for key in (
        'host', 'version', 'implementation', 'cache_tag', 'architecture',
        'gil_disabled', 'executable_sha256')}
    return {'schema_version': 1, 'status': 'observed-inputs-only',
            'release_review': 'pending', 'runtime': safe_runtime,
            'pip_report_sha256': before_report,
            'wheels': sorted(observed, key=lambda row: row['distribution']),
            'limitations': ['Metadata and selected archive hashes only; no installed-file equivalence proof.',
                            'No native codec, frozen application, installer, license or user acceptance proof.',
                            'Not a bundle-input receipt or a reviewed release record.']}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--wheelhouse', required=True, type=Path)
    parser.add_argument('--pip-report', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args(argv)
    # Parent must exist and be a real directory, including every ancestor.
    parent = plain(args.output.absolute().parent, directory=True)
    canonical(args.output.name)
    target = parent / args.output.name
    if target.exists() or target.is_symlink():
        raise ValueError('Output already exists')
    observed = runtime_observation()
    result = collect(args.wheelhouse, args.pip_report, observed)
    if runtime_observation() != observed:
        raise ValueError('Runtime metadata changed during observation')
    with target.open('x', encoding='utf-8') as stream:
        json.dump(result, stream, indent=2, ensure_ascii=True)
        stream.write('\n')
    print(json.dumps({'status': result['status'], 'wheel_count': len(result['wheels']),
                      'output_sha256': sha(target)}))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
