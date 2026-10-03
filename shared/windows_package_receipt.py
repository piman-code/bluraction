"""Bounded, read-only packaging provenance checks; never a license verdict.

Existing acquisition/build locks are referenced by hash, not recreated. No
codec imports, process execution, extraction, downloads or input writes occur.
The pure API accepts an observation for authored tests. The CLI observes its
actual interpreter and refuses to finalize Windows inputs on another host.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from email.parser import Parser
import hashlib
from importlib import metadata
import json
import math
import os
from pathlib import Path, PurePosixPath
import platform
import re
import stat
import struct
import sys
import sysconfig
import zipfile
try:
    from .source_identity import stat_snapshot, same_domain, path_matches_descriptor
except ImportError:  # Direct CLI, whose sys.path starts with shared/.
    from source_identity import stat_snapshot, same_domain, path_matches_descriptor

MAX_JSON = 4 * 1024**2
MAX_FILE = 768 * 1024**2
MAX_EXPANDED = 2 * 1024**3
MAX_MEMBERS = 50000
MAX_ROWS = 50000
PINS = {'pyside6': '6.11.1', 'pyside6-addons': '6.11.1',
        'pyside6-essentials': '6.11.1', 'shiboken6': '6.11.1',
        'pillow': '12.3.0', 'numpy': '2.3.5', 'av': '19.0.0',
        'opencv-contrib-python-headless': '4.14.0.94', 'pypdf': '6.19.0',
        'pillow-heif': '1.8.0', 'pyinstaller': '6.22.3'}
REQUIRED_IDS = {'python', 'pyside6', 'qt', 'pdfium', 'pyav', 'ffmpeg',
                'opencv', 'pillow', 'numpy', 'pyinstaller', 'pypdf',
                'pillow-heif', 'libheif', 'heif-codecs'}
SOURCE_REQUIRED = {'LICENSE', 'platforms/windows/launcher.py',
                   'platforms/windows/bluraction/ui.py',
                   'platforms/windows/bluraction/editor.py',
                   'platforms/windows/bluraction/renderer.py',
                   'platforms/windows/requirements-dev.txt',
                   'platforms/windows/installer/requirements-packaging.txt',
                   'platforms/windows/build_package.ps1',
                   'platforms/windows/installer/build_installer.ps1',
                   'platforms/windows/verify_dependency_pins.py',
                   'scripts/verify_windows.py', 'shared/portable_project.py'}


def normalize(name):
    if type(name) is not str or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', name):
        raise ValueError('plain distribution identity required')
    return re.sub(r'[-_.]+', '-', name).lower()


@contextmanager
def stable_read(path):
    path = plain(path)
    canonical_before = str(path.resolve(strict=True))
    before = stat_snapshot(path.lstat(), domain='path')
    descriptor = os.open(path, os.O_RDONLY | getattr(os, 'O_BINARY', 0) | getattr(os, 'O_NOFOLLOW', 0))
    with os.fdopen(descriptor, 'rb') as stream:
        fd_before = stat_snapshot(os.fstat(stream.fileno()), domain='descriptor')
        if not path_matches_descriptor(before, fd_before):
            raise ValueError('opened file does not match path identity')
        yield stream
        fd_after = stat_snapshot(os.fstat(stream.fileno()), domain='descriptor')
        after_path = plain(path)
        after = stat_snapshot(after_path.lstat(), domain='path')
        if (not same_domain(before, after) or not same_domain(fd_before, fd_after) or
                not path_matches_descriptor(after, fd_after) or
                str(after_path.resolve(strict=True)) != canonical_before):
            raise ValueError('input identity changed while reading')


def sha(path):
    result = hashlib.sha256()
    with stable_read(path) as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def canonical(value):
    if type(value) is not str or not value or len(value) > 4096 or '\\' in value or '\0' in value:
        raise ValueError('bounded canonical relative path required')
    path = PurePosixPath(value)
    if path.is_absolute() or value == '.' or ':' in value or str(path) != value or '..' in path.parts or len(path.parts) > 64:
        raise ValueError('contained canonical relative path required')
    for part in path.parts:
        if (part[-1] in '. ' or any(ord(c) < 32 or c in '<>"|?*' for c in part) or
                re.fullmatch(r'(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\..*)?', part, re.I)):
            raise ValueError('Windows alias/reserved path is forbidden')
    return value


def plain(path, *, directory=False):
    path = Path(path).absolute()
    for part in (path, *path.parents):
        info = part.lstat()
        if stat.S_ISLNK(info.st_mode) or getattr(info, 'st_file_attributes', 0) & 1024:
            raise ValueError('symlink/reparse paths are forbidden')
    info = path.stat()
    if directory:
        if not stat.S_ISDIR(info.st_mode):
            raise ValueError('regular directory required')
    elif not stat.S_ISREG(info.st_mode) or info.st_size > MAX_FILE:
        raise ValueError('bounded regular file required')
    return path


def contained(root, name):
    return plain(plain(root, directory=True) / canonical(name))


def hash_value(value):
    if type(value) is not str or not re.fullmatch(r'[0-9a-f]{64}', value):
        raise ValueError('lowercase SHA-256 required')
    return value


def file_row(root, row):
    if not isinstance(row, dict) or not {'path', 'bytes', 'sha256'} <= row.keys():
        raise ValueError('file identity required')
    path = contained(root, row['path'])
    if type(row['bytes']) is not int or not 0 < row['bytes'] <= MAX_FILE:
        raise ValueError('nonempty bounded artifact required')
    if path.stat().st_size != row['bytes'] or sha(path) != hash_value(row['sha256']):
        raise ValueError('actual artifact bytes/SHA drift: ' + row['path'])
    return path


def _pairs(rows):
    result = {}
    for key, value in rows:
        if key in result:
            raise ValueError('duplicate JSON key')
        result[key] = value
    return result


def finite_float(value):
    number = float(value)
    if not math.isfinite(number):
        raise ValueError('nonfinite JSON number')
    return number


def read_json(path):
    path = plain(path)
    if not 0 < path.stat().st_size <= MAX_JSON:
        raise ValueError('bounded nonempty JSON required')
    with stable_read(path) as stream:
        data = stream.read(MAX_JSON + 1)
    if len(data) > MAX_JSON:
        raise ValueError('bounded JSON required')
    return json.loads(data.decode('utf-8-sig'), object_pairs_hook=_pairs,
                      parse_float=finite_float,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError('nonfinite JSON')))


def _rows(value, name):
    if type(value) is not list or not 0 < len(value) <= MAX_ROWS:
        raise ValueError('nonempty bounded ' + name + ' required')
    return value


def keys(value, allowed, required=()):
    if type(value) is not dict or not set(required) <= value.keys() or not value.keys() <= set(allowed):
        raise ValueError('unknown/missing receipt fields')


def zip_members(archive):
    members = archive.infolist()
    if not 0 < len(members) <= MAX_MEMBERS:
        raise ValueError('bounded zip member count required')
    result, total = {}, 0
    for member in members:
        if member.orig_filename != member.filename:
            raise ValueError('raw ZIP filename differs from decoded filename')
        name = canonical(member.filename[:-1] if member.is_dir() else member.filename)
        folded = name.lower()
        if folded in result or member.flag_bits & 1:
            raise ValueError('duplicate/encrypted zip member')
        mode = member.external_attr >> 16
        if stat.S_IFMT(mode) and not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
            raise ValueError('zip links/devices are forbidden')
        total += member.file_size
        if member.file_size < 0 or member.file_size > MAX_FILE or total > MAX_EXPANDED:
            raise ValueError('bounded expanded archive required')
        result[folded] = member
        # ZipFile.open compares local and central names, including unused files.
        if not member.is_dir():
            with archive.open(member) as stream:
                stream.read(1)
    return result


def member_sha(archive, member):
    result, size = hashlib.sha256(), 0
    with archive.open(member) as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            size += len(block)
            if size > member.file_size or size > MAX_FILE:
                raise ValueError('expanded member size drift')
            result.update(block)
    if size != member.file_size:
        raise ValueError('expanded member size drift')
    return result.hexdigest()


def wheel_identity(path, row):
    with stable_read(path) as stream, zipfile.ZipFile(stream) as archive:
        members = zip_members(archive)
        # Wheel identity belongs to the root dist-info directory. Vendored
        # packages (e.g. setuptools/_vendor) retain their own metadata, which
        # must not be mistaken for additional identities of this wheel.
        meta = [m for n, m in members.items() if n.count('/') == 1 and n.endswith('.dist-info/metadata')]
        wheel = [m for n, m in members.items() if n.count('/') == 1 and n.endswith('.dist-info/wheel')]
        if len(meta) != 1 or len(wheel) != 1 or meta[0].file_size > MAX_JSON or wheel[0].file_size > MAX_JSON:
            raise ValueError('one bounded wheel METADATA/WHEEL required')
        if meta[0].filename.rsplit('/', 1)[0] != wheel[0].filename.rsplit('/', 1)[0]:
            raise ValueError('wheel metadata directory mismatch')
        info = Parser().parsestr(archive.read(meta[0]).decode('utf-8'))
        tags = Parser().parsestr(archive.read(wheel[0]).decode('utf-8')).get_all('Tag', [])
        if len(info.get_all('Name', [])) != 1 or len(info.get_all('Version', [])) != 1:
            raise ValueError('one exact wheel name/version required')
        name = normalize(info['Name'])
        if name != normalize(row['distribution']) or info['Version'] != row['version']:
            raise ValueError('wheel name/version differs from receipt')
        if name in PINS and info['Version'] != PINS[name]:
            raise ValueError('wheel differs from declared package pin')
        if not tags or len(set(tags)) != len(tags):
            raise ValueError('unique wheel tags required')
        for tag in tags:
            parts = tag.split('-')
            if len(parts) != 3:
                raise ValueError('plain wheel tag required')
            interpreter, abi, target = parts
            compatible = ((interpreter in ('py3', 'py2.py3') and abi == 'none' and target in ('any', 'win_amd64')) or
                          (target == 'win_amd64' and ((interpreter == 'cp314' and abi == 'cp314') or
                           (abi == 'abi3' and re.fullmatch(r'cp3[0-9]+', interpreter) and
                            2 <= int(interpreter[3:]) <= 14))))
            if not compatible:
                raise ValueError('wheel not standard CPython3.14 GIL Windows x64 compatible')
        return name


def runtime_observation():
    """Metadata/file identity only; does not import or execute a codec."""
    executable = Path(sys.executable).resolve()
    distributions = {}
    for distribution in metadata.distributions():
        name = normalize(distribution.metadata['Name'])
        if name in distributions:
            raise ValueError('ambiguous installed distribution metadata')
        distributions[name] = distribution.version
    return {'host': sys.platform, 'version': platform.python_version(),
            'implementation': sys.implementation.name, 'cache_tag': sys.implementation.cache_tag,
            'architecture': platform.machine().lower(),
            'gil_disabled': bool(sysconfig.get_config_var('Py_GIL_DISABLED')),
            'executable_sha256': sha(executable),
            'distributions': distributions}


def source_identity(path, source_root=None):
    """Curated source ZIP identity, not a corresponding-source completeness verdict."""
    with stable_read(path) as stream, zipfile.ZipFile(stream) as archive:
        members = zip_members(archive)
        names = [m.filename for m in members.values() if not m.is_dir()]
        prefix = ''
        if not SOURCE_REQUIRED <= set(names):
            roots = {n.split('/')[0] for n in names}
            if len(roots) != 1:
                raise ValueError('one source root required')
            prefix = roots.pop() + '/'
        normalized = {n[len(prefix):] for n in names}
        if not SOURCE_REQUIRED <= normalized:
            raise ValueError('required Windows source inputs missing')
        declared = {}
        for requirement in ('platforms/windows/requirements-dev.txt',
                            'platforms/windows/installer/requirements-packaging.txt'):
            entry = members[(prefix + requirement).lower()]
            if entry.file_size > MAX_JSON:
                raise ValueError('bounded pinned requirements required')
            for line in archive.read(entry).decode('utf-8-sig').splitlines():
                line = line.split('#', 1)[0].strip()
                if not line:
                    continue
                match = re.fullmatch(r'([A-Za-z0-9][A-Za-z0-9._-]*)==([^\s;]+)', line)
                if not match or normalize(match[1]) in declared:
                    raise ValueError('one exact declared requirement pin required')
                declared[normalize(match[1])] = match[2]
        expected = {k: v for k, v in PINS.items() if k not in ('pyside6-addons', 'pyside6-essentials', 'shiboken6')}
        if declared != expected:
            raise ValueError('curated source requirements differ from receipt pins')
        for member in members.values():
            name = member.filename[len(prefix):]
            if member.is_dir() or not name:
                continue
            parts = PurePosixPath(name).parts
            if any(p in {'.git', '.build', '.venv', '__pycache__'} or p.startswith('qa-') or p.endswith('.app') for p in parts):
                raise ValueError('private/generated source member')
            if PurePosixPath(name).suffix.lower() in {'.dll', '.exe', '.pyd', '.dylib', '.so', '.o', '.a', '.pyc', '.lib', '.obj'}:
                raise ValueError('compiled file in source archive')
            with archive.open(member) as stream:
                head = stream.read(4)
            if head[:2] == b'MZ' or head == b'\x7fELF':
                raise ValueError('native object in source archive')
            code_input = (name in SOURCE_REQUIRED or
                          (name.startswith(('platforms/windows/bluraction/', 'shared/')) and name.endswith('.py')))
            if source_root is not None and code_input and sha(contained(source_root, name)) != member_sha(archive, member):
                raise ValueError('curated source differs from packaging checkout: ' + name)
        if source_root is not None:
            for folder in ('platforms/windows/bluraction', 'shared'):
                for file in (plain(source_root, directory=True) / folder).glob('*.py'):
                    if file.relative_to(source_root).as_posix() not in normalized:
                        raise ValueError('packaging code absent from source archive')


def tree_files(root):
    root = plain(root, directory=True)
    result = {}
    for count, path in enumerate(root.rglob('*'), 1):
        if count > MAX_ROWS:
            raise ValueError('bounded directory inventory required')
        plain(path, directory=path.is_dir())
        if path.is_file():
            name = canonical(path.relative_to(root).as_posix())
            if name.lower() in result:
                raise ValueError('Windows case-colliding files')
            result[name.lower()] = (name, path)
            if len(result) > MAX_ROWS:
                raise ValueError('bounded file inventory required')
    return result


def require_amd64(path):
    with stable_read(path) as stream:
        header = stream.read(64)
        if header[:2] != b'MZ' or len(header) != 64:
            raise ValueError('native binding is not a Windows PE')
        offset = struct.unpack_from('<I', header, 60)[0]
        if offset > min(MAX_JSON, path.stat().st_size - 6):
            raise ValueError('bounded PE header required')
        stream.seek(offset)
        if stream.read(6) != b'PE\0\0\x64\x86':
            raise ValueError('actual AMD64 native file required')


def _validate(receipt, *, mode, artifacts_root, materials_root, bundle_root,
              bundle_manifest, runtime, source_root, license_review, version, receipt_sha256):
    if type(receipt) is not dict or receipt.get('schema_version') != 1 or type(receipt['schema_version']) is not int:
        raise ValueError('receipt schema_version1 required')
    keys(receipt, ('schema_version', 'phase', 'runtime', 'artifacts', 'app_source', 'materials',
                   'bundle_manifest_sha256', 'native_bindings', 'build_evidence'))
    if receipt.get('phase') not in ('candidate-inputs', 'bundle-inputs-bound'):
        raise ValueError('explicit provenance phase required')
    observed = receipt.get('runtime')
    if not isinstance(observed, dict):
        raise ValueError('interpreter identity required')
    keys(observed, ('host', 'version', 'implementation', 'cache_tag', 'architecture',
                    'gil_disabled', 'executable_sha256'))
    if (observed.get('host') != 'win32' or observed.get('implementation') != 'cpython' or
            observed.get('cache_tag') != 'cpython-314' or observed.get('architecture') not in ('amd64', 'x86_64') or
            observed.get('gil_disabled') is not False or not re.fullmatch(r'3\.14\.[0-9]+', str(observed.get('version', '')))):
        raise ValueError('standard CPython3.14 GIL Windows x64 identity required')
    for key in ('host', 'version', 'implementation', 'cache_tag', 'architecture', 'gil_disabled', 'executable_sha256'):
        if observed.get(key) != runtime.get(key):
            raise ValueError('actual interpreter metadata differs: ' + key)
    hash_value(observed['executable_sha256'])
    selected, wheels, distributions = {}, {}, {}
    paths = set()
    for row in _rows(receipt.get('artifacts'), 'artifact census'):
        keys(row, ('id', 'kind', 'path', 'bytes', 'sha256', 'distribution', 'version', 'provider', 'evidence_ids'))
        identity = normalize(row.get('id'))
        if identity in selected or row.get('kind') not in ('wheel', 'runtime', 'evidence'):
            raise ValueError('unique artifact ID and supported kind required')
        path = file_row(artifacts_root, row)
        if row['path'].lower() in paths:
            raise ValueError('duplicate artifact path')
        paths.add(row['path'].lower())
        selected[identity] = (row, path)
        if row['kind'] == 'wheel':
            if row.get('provider') not in ('official-wheel', 'owned-build'):
                raise ValueError('explicit stock/owned wheel provider required')
            name = wheel_identity(path, row)
            if name in distributions:
                raise ValueError('one selected artifact per distribution')
            distributions[name] = row['version']
            wheels[identity] = (row, path)
    if not PINS.keys() <= distributions.keys():
        raise ValueError('complete runtime/tool/transitive wheel selection required')
    if any(runtime.get('distributions', {}).get(name) != value for name, value in distributions.items()):
        raise ValueError('selected wheel versions differ from installed metadata')
    if not any(row['kind'] == 'runtime' and row['sha256'] == observed['executable_sha256']
               for row, _ in selected.values()):
        raise ValueError('actual interpreter executable artifact absent')
    for row, _ in wheels.values():
        if row['provider'] == 'owned-build':
            for identity in _rows(row.get('evidence_ids'), 'owned source/build evidence'):
                if normalize(identity) not in selected or selected[normalize(identity)][0]['kind'] != 'evidence':
                    raise ValueError('owned wheel build evidence is absent')
    source = receipt.get('app_source')
    keys(source, ('path', 'bytes', 'sha256', 'commit', 'dirty'))
    source_path = file_row(artifacts_root, source)
    if not re.fullmatch(r'[0-9a-f]{40}', str(source.get('commit', ''))) or type(source.get('dirty')) is not bool:
        raise ValueError('explicit source commit/dirty provenance required')
    source_identity(source_path, source_root)
    materials = receipt.get('materials', {})
    keys(materials, ('inventory_sha256', 'files', 'dependency_bindings'))
    files = tree_files(materials_root)
    recorded = set()
    for row in _rows(materials.get('files'), 'material inventory'):
        keys(row, ('path', 'bytes', 'sha256'))
        file_row(materials_root, row)
        name = row['path'].lower()
        if name in recorded:
            raise ValueError('duplicate material path')
        recorded.add(name)
    if recorded != files.keys():
        raise ValueError('material inventory must cover every actual file')
    inventory_path = contained(materials_root, 'dependencies.json')
    if sha(inventory_path) != hash_value(materials.get('inventory_sha256')):
        raise ValueError('dependency inventory SHA mismatch')
    inventory = read_json(inventory_path)
    dependencies = {}
    for dependency in _rows(inventory.get('dependencies'), 'dependency census'):
        identity = normalize(dependency.get('id'))
        if identity in dependencies or not dependency.get('version') or not dependency.get('license') or not dependency.get('redistribution_review'):
            raise ValueError('unique complete dependency evidence required')
        dependencies[identity] = dependency
        for field in ('license_files', 'evidence_files'):
            for name in _rows(dependency.get(field), field):
                path = contained(materials_root, name)
                if path.stat().st_size == 0 or name.lower() not in recorded:
                    raise ValueError('nonempty inventoried material reference required')
    if not REQUIRED_IDS <= dependencies.keys() or dependencies['python']['version'] != observed['version']:
        raise ValueError('complete dependency/Python identity required')
    aliases = {'av': 'pyav', 'opencv-contrib-python-headless': 'opencv'}
    for name, value in distributions.items():
        identity = aliases.get(name, name)
        if identity in dependencies and dependencies[identity]['version'] != value:
            raise ValueError('material version differs from selected artifact')
    if mode == 'prepare':
        for row, _ in selected.values():
            file_row(artifacts_root, row)
        file_row(artifacts_root, source)
        source_identity(source_path, source_root)
        for row in materials['files']:
            file_row(materials_root, row)
        if files.keys() != tree_files(materials_root).keys():
            raise ValueError('material inventory changed during validation')
        return
    if receipt['phase'] != 'bundle-inputs-bound' or not bundle_root or not bundle_manifest:
        raise ValueError('final exact bundle binding required')
    manifest_path = plain(bundle_manifest)
    if sha(manifest_path) != hash_value(receipt.get('bundle_manifest_sha256')):
        raise ValueError('exact bundle manifest SHA mismatch')
    manifest = _rows(read_json(manifest_path), 'bundle manifest')
    actual, recorded = tree_files(bundle_root), set()
    for row in manifest:
        name = canonical(row.get('path', '').replace('\\', '/'))
        if not name.startswith('BlurAction/'):
            raise ValueError('exact BlurAction manifest root required')
        name = name[len('BlurAction/'):]
        path = contained(bundle_root, name)
        if name.lower() in recorded or sha(path) != hash_value(row.get('sha256')):
            raise ValueError('duplicate/changed bundle file')
        recorded.add(name.lower())
    if recorded != actual.keys():
        raise ValueError('unlisted/missing actual bundle file')
    for row in materials['files']:
        path = contained(bundle_root, 'licenses/' + row['path'])
        if path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
            raise ValueError('bundled materials differ from selected evidence')
    native = set()
    for name, (_, path) in actual.items():
        with stable_read(path) as stream:
            magic = stream.read(2)
        if name != 'bluraction.exe' and (Path(name).suffix.lower() in ('.dll', '.pyd', '.exe') or magic == b'MZ'):
            native.add(name)
    bound = set()
    for binding in _rows(receipt.get('native_bindings'), 'native artifact bindings'):
        keys(binding, ('path', 'artifact_id', 'member'))
        name = canonical(binding.get('path')).lower()
        identity = normalize(binding.get('artifact_id'))
        if name in bound or name not in native or identity not in selected:
            raise ValueError('unique actual native file/provider required')
        row, origin = selected[identity]
        if row['kind'] == 'wheel':
            with stable_read(origin) as stream, zipfile.ZipFile(stream) as archive:
                members = zip_members(archive)
                member = members.get(canonical(binding.get('member')).lower())
                if member is None or member.is_dir():
                    raise ValueError('actual source wheel member absent')
                expected = member_sha(archive, member)
        elif row['kind'] == 'runtime' and 'member' not in binding:
            expected = row['sha256']
        else:
            raise ValueError('native file must bind actual wheel/runtime bytes')
        path = actual[name][1]
        if sha(path) != expected:
            raise ValueError('native file differs from selected artifact member')
        require_amd64(path)
        bound.add(name)
    if native != bound:
        raise ValueError('every native DLL/PYD/helper EXE must have an exact provider binding')
    # Explicit component/provider mapping, not inferred from equal version
    # strings. Nested codec versions/configurations still need human review.
    component_wheels = {'pyside6': {'pyside6', 'shiboken6'}, 'qt': {'pyside6-essentials', 'pyside6-addons'},
        'pdfium': {'pyside6-addons'}, 'pyav': {'av'},
        'ffmpeg': {'av', 'pyside6-addons', 'opencv-contrib-python-headless'},
        'opencv': {'opencv-contrib-python-headless'}, 'pillow': {'pillow'}, 'numpy': {'numpy'},
        'pyinstaller': {'pyinstaller'}, 'pypdf': {'pypdf'}, 'pillow-heif': {'pillow-heif'},
        'libheif': {'pillow-heif'}, 'heif-codecs': {'pillow-heif'}}
    native_providers = {b['path'].lower(): normalize(b['artifact_id']) for b in receipt['native_bindings']}
    components, component_artifacts = set(), set()
    for binding in _rows(materials.get('dependency_bindings'), 'component/provider bindings'):
        keys(binding, ('id', 'version', 'artifact_ids', 'provider', 'native_paths', 'evidence_paths'))
        identity = normalize(binding.get('id'))
        if identity in components or identity not in dependencies or binding.get('version') != dependencies[identity]['version']:
            raise ValueError('unique actual material component/version binding required')
        components.add(identity)
        providers = [normalize(value) for value in _rows(binding.get('artifact_ids'), 'component artifacts')]
        if len(providers) != len(set(providers)) or not set(providers) <= selected.keys():
            raise ValueError('unique actual selected component providers required')
        component_artifacts.update(providers)
        observed_providers, names = {}, set()
        for provider in providers:
            item = selected[provider][0]
            if item['kind'] not in ('wheel', 'runtime'):
                raise ValueError('component provider must be an actual wheel/runtime')
            observed_providers[provider] = item['provider'] if item['kind'] == 'wheel' else 'runtime'
            if item['kind'] == 'wheel':
                names.add(normalize(item['distribution']))
        if binding.get('provider') != observed_providers:
            raise ValueError('stock/owned/runtime provider differs from acquired artifact')
        if identity == 'python':
            if any(selected[p][0]['kind'] != 'runtime' for p in providers) or not any(
                    selected[p][0]['sha256'] == observed['executable_sha256'] for p in providers):
                raise ValueError('Python component must include actual interpreter artifact')
        elif names != component_wheels.get(identity, {identity}):
            raise ValueError('component mapped to different wheel distribution')
        references = _rows(binding.get('evidence_paths'), 'component material evidence')
        declared_evidence = {n.lower() for n in dependencies[identity]['evidence_files']}
        if len(references) != len(set(references)) or {canonical(n).lower() for n in references} != declared_evidence:
            raise ValueError('component evidence must bind all inventoried material references')
        paths = binding.get('native_paths')
        if type(paths) is not list or len(paths) > MAX_ROWS:
            raise ValueError('bounded component native paths required')
        paths = [canonical(n).lower() for n in paths]
        if len(paths) != len(set(paths)) or any(native_providers.get(n) not in providers for n in paths):
            raise ValueError('component native path differs from actual provider binding')
        if identity in {'python', 'qt', 'pdfium', 'pyav', 'ffmpeg', 'opencv', 'pillow', 'numpy',
                        'pillow-heif', 'libheif', 'heif-codecs'} and not paths:
            raise ValueError('actual compiled component native paths are absent')
    if components != dependencies.keys():
        raise ValueError('every inventoried component must bind selected providers/evidence')
    if component_artifacts != {identity for identity, (row, _) in selected.items() if row['kind'] in ('wheel', 'runtime')}:
        raise ValueError('every selected wheel/runtime must have component material evidence')
    require_amd64(contained(bundle_root, 'BlurAction.exe'))
    build = receipt.get('build_evidence')
    keys(build, ('path', 'bytes', 'sha256'))
    build_path = file_row(artifacts_root, build)
    report = read_json(build_path)
    tool = next(row for row, _ in wheels.values() if normalize(row['distribution']) == 'pyinstaller')
    if (report.get('status') != 'pyinstaller-build-completed' or report.get('exit') != 0 or
            type(report.get('exit')) is not int or report.get('timed_out') is not False or
            report.get('source_archive_sha256') != source['sha256'] or
            report.get('python_executable_sha256') != observed['executable_sha256'] or
            report.get('pyinstaller_wheel_sha256') != tool['sha256'] or
            report.get('executable_sha256') != sha(contained(bundle_root, 'BlurAction.exe'))):
        raise ValueError('generated app build evidence does not bind selected inputs/output')
    for row, _ in selected.values():
        file_row(artifacts_root, row)
    file_row(artifacts_root, source)
    source_identity(source_path, source_root)
    file_row(artifacts_root, build)
    for row in materials['files']:
        file_row(materials_root, row)
    if files.keys() != tree_files(materials_root).keys() or actual.keys() != tree_files(bundle_root).keys():
        raise ValueError('file census changed during validation')
    if sha(manifest_path) != receipt['bundle_manifest_sha256']:
        raise ValueError('bundle manifest changed during validation')
    for row in manifest:
        name = row['path'].replace('\\', '/')[len('BlurAction/'):]
        if sha(contained(bundle_root, name)) != row['sha256']:
            raise ValueError('bundle bytes changed during validation')
    if license_review is None or not version:
        raise ValueError('exact external license review/version required for finalization')
    review = read_json(license_review)
    for field in ('reviewed_by', 'reviewed_at'):
        value = review.get(field)
        if type(value) is not str or not value.strip() or len(value) > 512:
            raise ValueError('reviewer/date must be bounded nonblank strings')
    if (review.get('status') != 'reviewed' or review.get('version') != version or
            review.get('bundle_manifest_sha256') != receipt['bundle_manifest_sha256'] or
            review.get('input_receipt_sha256') != hash_value(receipt_sha256) or
            not review.get('reviewed_by') or not review.get('reviewed_at') or
            type(review.get('dependencies')) is not list or not review['dependencies']):
        raise ValueError('review must bind exact version/manifest/receipt with reviewer findings')
    # This checks a complete, evidence-linked record, not the legal accuracy of
    # its author's findings. Never promote it to redistribution certification.
    reviewed = set()
    for finding in _rows(review['dependencies'], 'dependency review findings'):
        keys(finding, ('id', 'version', 'status', 'findings', 'evidence_files'),
             ('id', 'version', 'status', 'findings', 'evidence_files'))
        identity = normalize(finding['id'])
        if identity in reviewed or identity not in dependencies:
            raise ValueError('unique inventoried dependency review ID required')
        reviewed.add(identity)
        if (type(finding['version']) is not str or not finding['version'].strip() or
                finding['version'] != dependencies[identity]['version'] or
                finding['status'] != 'reviewed'):
            raise ValueError('exact dependency version and reviewed status required')
        details = finding['findings']
        if type(details) is not str or not details.strip() or len(details) > 8192:
            raise ValueError('bounded nonblank dependency findings required')
        references = [canonical(name).lower() for name in
                      _rows(finding['evidence_files'], 'review evidence references')]
        expected = {canonical(name).lower() for name in dependencies[identity]['evidence_files']}
        if len(references) != len(set(references)) or set(references) != expected:
            raise ValueError('review must reference all exact inventoried dependency evidence')
    if reviewed != dependencies.keys():
        raise ValueError('review findings must cover every inventoried dependency')


def validate_receipt(receipt, *, artifacts_root, materials_root, bundle_root=None,
                     bundle_manifest=None, runtime_observation=None, source_root=None, mode='prepare',
                     license_review=None, version=None, receipt_sha256=None):
    result = {'ok': False, 'mode': mode, 'host': sys.platform, 'errors': [],
              'native_codec_execution': False, 'redistribution_approved': False,
              'component_versions_certified': False}
    try:
        if mode not in ('prepare', 'finalize'):
            raise ValueError('prepare or finalize mode required')
        runtime = globals()['runtime_observation']() if runtime_observation is None else runtime_observation
        review_hash = sha(plain(license_review)) if mode == 'finalize' and license_review is not None else None
        _validate(receipt, mode=mode, artifacts_root=artifacts_root, materials_root=materials_root,
                  bundle_root=bundle_root, bundle_manifest=bundle_manifest, runtime=runtime,
                  source_root=source_root, license_review=license_review, version=version,
                  receipt_sha256=receipt_sha256)
        if review_hash is not None:
            if sha(plain(license_review)) != review_hash:
                raise ValueError('license review changed during validation')
            result['license_review_sha256'] = review_hash
        result['ok'] = True
    except (OSError, ValueError, TypeError, KeyError, AttributeError, UnicodeError,
            zipfile.BadZipFile, RuntimeError, NotImplementedError, RecursionError, metadata.PackageNotFoundError) as error:
        result['errors'].append(str(error))
    return result


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode', choices=('prepare', 'finalize'), required=True)
    parser.add_argument('--receipt', required=True)
    parser.add_argument('--artifacts-root', required=True)
    parser.add_argument('--materials-root', required=True)
    parser.add_argument('--source-root', required=True)
    parser.add_argument('--bundle')
    parser.add_argument('--bundle-manifest')
    parser.add_argument('--license-review')
    parser.add_argument('--version')
    args = parser.parse_args(arguments)
    try:
        if sys.platform != 'win32':
            raise ValueError('CLI requires actual Windows interpreter; authored tests are separate')
        path = plain(args.receipt)
        if args.bundle:
            bundle = plain(args.bundle, directory=True)
            for external in (path, plain(args.artifacts_root, directory=True)):
                if external == bundle or bundle in external.parents:
                    raise ValueError('receipt/acquisition artifacts must be external sidecars, outside bundle')
        before = sha(path)
        result = validate_receipt(read_json(path), artifacts_root=args.artifacts_root,
            materials_root=args.materials_root, bundle_root=args.bundle,
            bundle_manifest=args.bundle_manifest, source_root=args.source_root, mode=args.mode,
            license_review=args.license_review, version=args.version, receipt_sha256=before)
        if sha(path) != before:
            raise ValueError('receipt changed during validation')
        result['receipt_sha256'] = before
    except (OSError, ValueError, UnicodeError, RecursionError) as error:
        result = {'ok': False, 'host': sys.platform, 'errors': [str(error)],
                  'native_codec_execution': False, 'redistribution_approved': False}
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0 if result['ok'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
