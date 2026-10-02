"""QA draft. Execute only on an approved disposable Windows worker, not this authoring host."""
from __future__ import annotations

import argparse
import base64
import hashlib
import gzip
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import time
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


MAX_DB_BYTES = 64 * 1024 * 1024
MAX_DB_MEMBERS = 100000
MAX_DB_EXPANDED_BYTES = 512 * 1024 * 1024
MAX_DESC_BYTES = 65536
MAX_SIGNATURE_BYTES = 65536


def _package_url(url, filename):
    parsed = urllib.parse.urlsplit(url)
    if (parsed.scheme != 'https' or parsed.hostname != 'repo.msys2.org'
            or parsed.username or parsed.password or parsed.port not in (None, 443)
            or parsed.query or parsed.fragment
            or not re.fullmatch(r'[A-Za-z0-9_.+~\-]+', filename)):
        raise ValueError('official fixed package HTTPS URL required')
    if parsed.path not in ('/mingw/mingw64/' + filename, '/msys/x86_64/' + filename):
        raise ValueError('exact package repository/filename URL required')
    return 'mingw64.db' if parsed.path.startswith('/mingw/') else 'msys.db'


def _signature_bytes(data):
    """Bounded binary signature packet, NOT cryptographic PGP verification.

    The unchanged Required pacman installer verifies signer/trust/content before
    any compiler executes. Reject HTML, empty/truncated/partial OpenPGP packets.
    """
    if type(data) is not bytes or not 128 <= len(data) <= MAX_SIGNATURE_BYTES:
        raise ValueError('mandatory bounded binary package signature unavailable')
    first = data[0]
    if not first & 0x80:
        raise ValueError('binary OpenPGP signature packet required')
    if first & 0x40:
        if first & 0x3f != 2:
            raise ValueError('detached signature packet tag required')
        size = data[1]; offset = 2
        if size < 192: pass
        elif size < 224:
            size = ((size - 192) << 8) + data[2] + 192; offset = 3
        elif size == 255:
            size = int.from_bytes(data[2:6], 'big'); offset = 6
        else: raise ValueError('partial signature packet length rejected')
    else:
        if (first >> 2) & 15 != 2:
            raise ValueError('detached signature packet tag required')
        form = first & 3
        if form == 3: raise ValueError('indeterminate signature packet length rejected')
        length = (1, 2, 4)[form]; offset = 1 + length
        size = int.from_bytes(data[1:offset], 'big')
    body = data[offset:]
    if size != len(body) or len(body) < 8 or body[0] not in (4, 5, 6) or body[1] != 0:
        raise ValueError('incomplete binary-document signature packet')
    return data


class PackageSignatureRedirects(urllib.request.HTTPRedirectHandler):
    def __init__(self, expected_url):
        super().__init__(); self.expected_url = expected_url

    def redirect_request(self, request, fp, code, message, headers, newurl):
        # No cross-host/path redirect, including other generally allowed recipe
        # hosts. The signature is bound to this exact official package URL.
        if newurl != self.expected_url:
            raise ValueError('signature redirect changed fixed official URL')
        return super().redirect_request(request, fp, code, message, headers, newurl)


def fetch_package_signature(url):
    filename = urllib.parse.urlsplit(url).path.rsplit('/', 1)[-1]
    if not filename.endswith('.sig'):
        raise ValueError('detached signature suffix required')
    _package_url(url[:-4], filename[:-4])
    opener = urllib.request.build_opener(PackageSignatureRedirects(url))
    request = urllib.request.Request(url, headers={'User-Agent': 'BlurAction-owned-source-recipe'})
    deadline = time.monotonic() + 45
    with opener.open(request, timeout=15) as response:
        if response.geturl() != url:
            raise ValueError('signature response changed fixed official URL')
        declared = response.headers.get('Content-Length')
        if declared is not None and (not re.fullmatch(r'[0-9]+', declared)
                or not 128 <= int(declared) <= MAX_SIGNATURE_BYTES):
            raise ValueError('bounded signature Content-Length required')
        result = bytearray()
        while True:
            if time.monotonic() >= deadline:
                raise ValueError('signature acquisition deadline exceeded')
            # read1 returns one underlying buffered/network read; each native
            # read retains the 15s socket timeout, rather than filling a huge
            # buffer under an unbounded trickle. Outer owned build still bounded.
            block = response.read1(min(4096, MAX_SIGNATURE_BYTES + 1 - len(result)))
            if not block: break
            result.extend(block)
            if len(result) > MAX_SIGNATURE_BYTES:
                raise ValueError('signature acquisition size limit')
        if declared is not None and len(result) != int(declared):
            raise ValueError('signature response length mismatch')
    return _signature_bytes(bytes(result))


def _database_records(path, requested):
    """Read a bounded immutable tar image without extracting archive paths."""
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_DB_BYTES:
        raise ValueError('bounded plain copied repository database required')
    before = path.stat()
    with path.open('rb') as stream: raw = stream.read(MAX_DB_BYTES + 1)
    after = path.stat()
    fields = lambda st: (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns)
    if not raw or len(raw) > MAX_DB_BYTES or fields(before) != fields(after):
        raise ValueError('repository database changed or exceeded budget')
    # Bound decompression BEFORE tarfile handles extended/PAX headers: those
    # headers can otherwise request their declared size before yielding a member.
    if raw.startswith(b'\x1f\x8b'):
        with gzip.GzipFile(fileobj=io.BytesIO(raw)) as compressed:
            tar_image = compressed.read(MAX_DB_EXPANDED_BYTES + 1)
    else:
        tar_image = raw  # Current copied DB contract is gzip or plain tar.
    if len(tar_image) > MAX_DB_EXPANDED_BYTES:
        raise ValueError('repository database decompression budget')
    records = {}; members = expanded = 0
    with tarfile.open(fileobj=io.BytesIO(tar_image), mode='r:') as archive:
        for item in archive:
            members += 1; expanded += max(0, item.size)
            if members > MAX_DB_MEMBERS or expanded > MAX_DB_EXPANDED_BYTES:
                raise ValueError('repository database resource limit')
            if item.isdir(): continue
            if (not item.isfile() or item.name.startswith('/') or '\\' in item.name
                    or '..' in item.name.split('/')):
                raise ValueError('unsafe repository database member')
            if not item.name.endswith('/desc'): continue
            if item.size > MAX_DESC_BYTES:
                raise ValueError('repository description exceeds budget')
            with archive.extractfile(item) as leaf: data = leaf.read(MAX_DESC_BYTES + 1)
            if len(data) != item.size: raise ValueError('repository description truncated')
            values = {}
            for section in data.decode('utf-8').split('\n\n'):
                lines = section.splitlines()
                if not lines: continue
                key = lines[0]
                if not re.fullmatch(r'%[A-Z0-9_]+%', key) or key in values:
                    raise ValueError('malformed or duplicate repository field')
                values[key] = lines[1:]
            names = values.get('%NAME%', [])
            if len(names) != 1: raise ValueError('one repository package name required')
            name = names[0]
            if name not in requested: continue
            if name in records: raise ValueError('duplicate selected repository package')
            records[name] = values
    return records, hashlib.sha256(raw).hexdigest()


def resolve_package_plan(root):
    """Validate the entire five-field closure/DB/pins before any acquisition."""
    rows = []; plan = below(root, root / 'pacman-plan.txt')
    if not plan.is_file() or plan.stat().st_size > 1024 * 1024:
        raise ValueError('bounded package plan required')
    with plan.open('rb') as stream: plan_bytes = stream.read(1024 * 1024 + 1)
    if len(plan_bytes) > 1024 * 1024: raise ValueError('package plan exceeds budget')
    plan_sha = hashlib.sha256(plan_bytes).hexdigest()
    for line in plan_bytes.decode('utf-8-sig').splitlines():
        if not line.strip(): continue
        parts = line.split('|')
        if len(parts) != 5: raise ValueError('five-field package acquisition row required')
        name, version, filename, expected, url = parts
        if (not re.fullmatch(r'[A-Za-z0-9_.+\-]+', name) or not version
                or not re.fullmatch(r'[A-Za-z0-9_.+~:\-]+', version)
                or not re.fullmatch(r'[0-9a-f]{64}', expected)):
            raise ValueError('strict package name/version/SHA required')
        database = _package_url(url, filename)
        rows.append(dict(name=name, version=version, filename=filename, sha256=expected,
                         url=url, database=database, packagePlanSHA256=plan_sha))
    if (not rows or len(rows) > 160 or len({x['name'] for x in rows}) != len(rows)
            or len({x['filename'].lower() for x in rows}) != len(rows)):
        raise ValueError('finite unique full package closure required')
    for target in PINS['compilerTargets']:
        matches = [r for r in rows if r['name'] == target['name']]
        if len(matches) != 1 or any(matches[0][k] != target[k] for k in ('version', 'filename', 'sha256')):
            raise ValueError('known compiler target drifted; no version substitution')
    databases = {}; db_shas = {}
    for database in ('msys.db', 'mingw64.db'):
        path = below(root, root / 'reports' / database)
        records, digest = _database_records(path, {r['name'] for r in rows if r['database'] == database})
        databases[database] = records; db_shas[database] = digest
    for row in rows:
        values = databases[row['database']].get(row['name'])
        if values is None: raise ValueError('selected package absent from exact repository DB')
        for key, field in (('name','%NAME%'), ('version','%VERSION%'),
                           ('filename','%FILENAME%'), ('sha256','%SHA256SUM%')):
            if values.get(field) != [row[key]]:
                raise ValueError('package plan differs from copied repository database')
        row['databaseSHA256'] = db_shas[row['database']]
        if '%PGPSIG%' in values:
            entries = values['%PGPSIG%']
            if len(entries) != 1: raise ValueError('embedded signature missing/ambiguous')
            row['_embedded_signature'] = _signature_bytes(base64.b64decode(entries[0], validate=True))
    return rows, db_shas


def package_lock(root):
    """Freeze exact package and signature bytes; PGP trust is NOT verified here."""
    root = owned(root)
    rows, database_shas = resolve_package_plan(root)
    acquired = []
    for row in rows:
        embedded = row.pop('_embedded_signature', None)
        if embedded is not None:
            signature = embedded; source = 'repository-embedded-PGPSIG'; signature_url = None
        else:
            signature_url = row['url'] + '.sig'
            signature = fetch_package_signature(signature_url)
            source = 'same-official-package-detached-signature'
        signature = _signature_bytes(signature)
        # Package expected SHA is always enforced by the unchanged downloader.
        download(root, row)
        signature_path = below(root, root / 'downloads' / (row['filename'] + '.sig'))
        with signature_path.open('xb') as stream: stream.write(signature)
        acquired.append(dict(row, signature={'filename':signature_path.name,
            'bytes':len(signature), 'sha256':hashlib.sha256(signature).hexdigest(),
            'sourceType':source, 'url':signature_url, 'PGPVerified':False}))
    # Repository snapshots may not change while signatures/packages are acquired.
    for database, digest in database_shas.items():
        if sha(below(root, root / 'reports' / database)) != digest:
            raise ValueError('repository DB changed during acquisition; no install lock')
    if sha(below(root, root / 'pacman-plan.txt')) != rows[0]['packagePlanSHA256']:
        raise ValueError('package plan changed during acquisition; no install lock')
    write_json(root / 'reports' / 'compiler-packages-lock.json', {
        'source': 'five-field pacman closure plus exact copied repository database',
        'packagePlanSHA256':rows[0]['packagePlanSHA256'],
        'repositoryDatabaseSHA256':database_shas, 'packages': acquired,
        'signaturePolicy':'embedded PGPSIG else exact official package HTTPS URL + .sig',
        'PGPVerification':'UNVERIFIED until mandatory offline pacman -U Required succeeds; no compiler execution before success',
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
