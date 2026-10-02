"""QA draft. Execute only on an approved disposable Windows worker, not this authoring host."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.parse
import urllib.request

HERE = Path(__file__).resolve().parent
PINS = json.loads((HERE / 'pins.json').read_text(encoding='utf-8'))
HOSTS = {'github.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com',
         'files.pythonhosted.org', 'ffmpeg.org', 'repo.msys2.org'}


def sha(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def write_json(path, data):
    with path.open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(data, stream, ensure_ascii=False, sort_keys=True, indent=2)
        stream.write('\n')


def owned(root):
    root = Path(root).absolute()
    if root.is_symlink() or root.resolve() != root or not (root / 'owned.json').is_file():
        raise ValueError('this attempt-owned root required')
    return root


def below(root, path):
    path = Path(path).absolute()
    path.relative_to(root)
    if path.is_symlink() or path.resolve() != path:
        raise ValueError('no reparse/symlink candidate path')
    return path


class HTTPSRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        url = urllib.parse.urlsplit(newurl)
        if url.scheme != 'https' or url.hostname not in HOSTS or url.username or url.password:
            raise ValueError('unapproved acquisition redirect')
        return super().redirect_request(request, fp, code, message, headers, newurl)


def download(root, row, maximum=768 * 1024 * 1024):
    name = row['filename']
    if Path(name).name != name or not re.fullmatch(r'[A-Za-z0-9_.+~:-]+', name):
        raise ValueError('plain acquired filename required')
    if not re.fullmatch('[0-9a-f]{64}', row['sha256']):
        raise ValueError('real expected SHA256 required')
    url = urllib.parse.urlsplit(row['url'])
    if url.scheme != 'https' or url.hostname not in HOSTS or url.username or url.password:
        raise ValueError('official pinned HTTPS source only')
    path = root / 'downloads' / name
    opener = urllib.request.build_opener(HTTPSRedirects())
    request = urllib.request.Request(row['url'], headers={'User-Agent': 'BlurAction-owned-source-recipe'})
    with opener.open(request, timeout=90) as response, path.open('xb') as target:
        size = 0
        while block := response.read(1024 * 1024):
            size += len(block)
            if size > maximum:
                raise ValueError('acquisition size limit')
            target.write(block)
    if not size or sha(path) != row['sha256']:
        raise ValueError('acquired SHA mismatch; candidate preserved, not executed')
    return path


def unpack(root, archive, destination):
    destination = below(root, destination)
    destination.mkdir()
    with tarfile.open(archive, 'r:*') as source:
        members = source.getmembers()
        if len(members) > 150000 or sum(max(0, item.size) for item in members) > 3 * 1024**3:
            raise ValueError('archive resource limit')
        for item in members:
            # Validate all metadata before extraction. Python 3.14 data filter
            # additionally rejects outside links/devices; no permission bypass.
            tarfile.data_filter(item, str(destination))
        source.extractall(destination, members=members, filter='data')


def acquire(root):
    if sys.platform != 'win32' or tuple(sys.version_info[:3]) != (3, 14, 7):
        raise ValueError('actual Windows CPython 3.14.7 required')
    root = Path(root).absolute()
    root.mkdir(parents=False, exist_ok=False)
    if root.resolve() != root:
        raise ValueError('new plain owned root required')
    write_json(root / 'owned.json', {'schemaVersion': 1, 'python': sys.version,
                                  'supportComplete': False, 'releaseApproved': False})
    for name in ('downloads', 'logs', 'reports', 'raw-wheel', 'repaired-wheel', 'prefix'):
        (root / name).mkdir()
    acquired = []
    for row in PINS['archives'] + PINS['wheels']:
        path = download(root, row)
        acquired.append(dict(row, bytes=path.stat().st_size, actualSHA256=sha(path)))
    unpack(root, root / 'downloads' / PINS['archives'][0]['filename'], root / 'msys')
    unpack(root, root / 'downloads' / PINS['archives'][1]['filename'], root / 'ffmpeg-source')
    unpack(root, root / 'downloads' / PINS['archives'][2]['filename'], root / 'pyav-source')
    write_json(root / 'reports' / 'source-acquisition.json', {
        'files': acquired, 'pinsSHA256': sha(HERE / 'pins.json'),
        'wholeGoalComplete': False, 'correspondingSourceComplete': False})


def package_lock(root):
    """Consume official pacman --print-format rows; freeze before package execution."""
    root = owned(root)
    rows = []
    for line in (root / 'pacman-plan.txt').read_text(encoding='utf-8-sig').splitlines():
        if not line.strip():
            continue
        parts = line.split('|')
        if len(parts) != 6:
            raise ValueError('unstructured pacman acquisition row')
        name, version, filename, expected, url, signature = parts
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != 'https' or parsed.hostname != 'repo.msys2.org':
            raise ValueError('official fixed pacman server required')
        if parsed.path.rsplit('/', 1)[-1] != filename:
            raise ValueError('package filename URL mismatch')
        rows.append({'name': name, 'version': version, 'filename': filename,
                     'sha256': expected, 'url': url, 'PGPSignatureBase64': signature})
    if not rows or len(rows) > 160 or len({x['name'] for x in rows}) != len(rows):
        raise ValueError('finite unique full package closure required')
    for target in PINS['compilerTargets']:
        matches = [x for x in rows if x['name'] == target['name']]
        if len(matches) != 1 or any(matches[0][k] != target[k] for k in ('version', 'filename', 'sha256')):
            raise ValueError('known compiler target drifted; do not select a new version silently')
    for row in rows:
        download(root, row)
        signature = base64.b64decode(row['PGPSignatureBase64'], validate=True)
        if not 128 <= len(signature) <= 65536:
            raise ValueError('mandatory package signature unavailable')
        with (root / 'downloads' / (row['filename'] + '.sig')).open('xb') as stream:
            stream.write(signature)
    write_json(root / 'reports' / 'compiler-packages-lock.json', {
        'source': 'official pacman repository database', 'packages': rows,
        'PGPVerification': 'mandatory pacman -U before execution; success not yet asserted',
        'sourceArchivesForAllRuntimePackagesComplete': False})


def import_libraries(root, library_tool):
    import pefile
    root = owned(root)
    bindir, libdir = root / 'prefix' / 'bin', root / 'prefix' / 'lib'
    expected = ('avcodec', 'avdevice', 'avfilter', 'avformat', 'avutil', 'swresample', 'swscale')
    rows = []
    for name in expected:
        matches = list(bindir.glob(name + '-*.dll'))
        if len(matches) != 1:
            raise ValueError('one owned FFmpeg DLL per link library required')
        dll = matches[0]
        with pefile.PE(str(dll)) as pe:
            if pe.FILE_HEADER.Machine != 0x8664:
                raise ValueError('x64 PE required')
            exports = pe.DIRECTORY_ENTRY_EXPORT.symbols
            if len(exports) > 20000 or any(x.name is None for x in exports):
                raise ValueError('finite named FFmpeg exports required')
            names = sorted(x.name.decode('ascii') for x in exports)
            if any(not re.fullmatch(r'[A-Za-z0-9_@?$]+', x) for x in names):
                raise ValueError('unexpected export token')
        definition = libdir / (name + '.def')
        definition.write_text('LIBRARY ' + dll.name + '\nEXPORTS\n' + '\n'.join(names) + '\n',
                              encoding='ascii')
        subprocess.run([library_tool, '/NOLOGO', '/MACHINE:X64', '/DEF:' + str(definition),
                        '/OUT:' + str(libdir / (name + '.lib'))], check=True, timeout=60)
        rows.append({'library': name, 'dllSHA256': sha(dll), 'definitionSHA256': sha(definition),
                     'importLibrarySHA256': sha(libdir / (name + '.lib'))})
    write_json(root / 'reports' / 'generated-import-libraries.json', {'rows': rows})


def dll_closure(root):
    """Copy only imported compiler runtimes, recording package ownership for source follow-up."""
    import pefile
    root = owned(root)
    bins = root / 'prefix' / 'bin'
    compiler = root / 'msys' / 'msys64' / 'mingw64' / 'bin'
    system = Path(os.environ['SystemRoot']) / 'System32'
    pending = list(bins.glob('*.dll'))
    seen, rows = set(), []
    while pending:
        path = pending.pop()
        if path.name.lower() in seen:
            continue
        seen.add(path.name.lower())
        with pefile.PE(str(path)) as pe:
            imports = [x.dll.decode('ascii') for section in ('DIRECTORY_ENTRY_IMPORT', 'DIRECTORY_ENTRY_DELAY_IMPORT')
                       for x in getattr(pe, section, ())]
        rows.append({'name': path.name, 'sha256': sha(path), 'imports': sorted(imports)})
        for name in imports:
            if Path(name).name != name:
                raise ValueError('invalid PE import path')
            existing = next((p for p in bins.glob('*.dll') if p.name.lower() == name.lower()), None)
            if existing is not None:
                pending.append(existing)
                continue
            origin = next((p for p in compiler.glob('*.dll') if p.name.lower() == name.lower()), None)
            if origin is not None:
                target = bins / origin.name
                with origin.open('rb') as src, target.open('xb') as dst:
                    shutil.copyfileobj(src, dst)
                pending.append(target)
                continue
            if name.lower().startswith(('api-ms-win-', 'ext-ms-win-')) or (system / name).is_file():
                continue
            raise ValueError('unresolved imported DLL; no arbitrary search/PATH fallback: ' + name)
    write_json(root / 'reports' / 'owned-ffmpeg-dll-closure.json', {
        'dlls': rows, 'runtimeSourceCompleteness': False, 'finalBundleReviewed': False})


def final_manifest(root):
    root = owned(root)
    rows = []
    for folder in ('downloads', 'logs', 'reports', 'raw-wheel', 'repaired-wheel', 'prefix'):
        for path in sorted((root / folder).rglob('*')):
            if path.is_file():
                below(root, path)
                rows.append({'path': path.relative_to(root).as_posix(), 'bytes': path.stat().st_size,
                             'sha256': sha(path)})
    write_json(root / 'candidate-material-manifest.json', {
        'files': rows, 'newOwnedBuild': True, 'historicalWheelReproduced': False,
        'correspondingSourceComplete': False, 'fullFormatSupportVerified': False,
        'QtIMEAndAppVerified': False, 'timelineP1Closed': False, 'releaseApproved': False})


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=('acquire', 'package-lock', 'import-libs', 'dll-closure', 'manifest'))
    parser.add_argument('--root', required=True)
    parser.add_argument('--lib-tool')
    args = parser.parse_args()
    if args.mode == 'acquire': acquire(args.root)
    elif args.mode == 'package-lock': package_lock(args.root)
    elif args.mode == 'import-libs': import_libraries(args.root, args.lib_tool)
    elif args.mode == 'dll-closure': dll_closure(args.root)
    else: final_manifest(args.root)
