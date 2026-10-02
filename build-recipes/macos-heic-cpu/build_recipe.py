#!/usr/bin/env python3
"""Root-run-only disposable source build. No global installation/public upload.

Requires independently acquired CMake>=3.25 and pkg-config with exact executable
hashes supplied by the root. These tool bytes are NOT represented as pinned by
this source recipe; tool/compiler source correspondence remains an explicit gate.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import signal
import subprocess
import sys
import tarfile
from owned_process import finish_owned_group

HERE = Path(__file__).resolve().parent


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def new_json(path, value):
    with path.open('x', encoding='utf-8') as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write('\n')


def run(root, stem, arguments, environment, timeout=900):
    # Each child/process group belongs to this new attempt. Root supervises this
    # driver too; these bounds are NOT native codec in-process cancellation.
    with (root / 'logs' / (stem + '.stdout')).open('xb') as stdout, \
            (root / 'logs' / (stem + '.stderr')).open('xb') as stderr:
        child = subprocess.Popen(arguments, cwd=root, env=environment,
                                 stdout=stdout, stderr=stderr, start_new_session=True)
        try:
            code = child.wait(timeout=timeout)
        except BaseException:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()
            raise
        finally:
            finish_owned_group(child)
    if code:
        raise RuntimeError(f'{stem} failed: exit {code}; owned logs retained')


def extract(archive, destination, expected_directory):
    # Validate all metadata before any extraction; no archive links/devices or
    # outside paths. Resource ceiling is a source acquisition limit, not scope.
    with tarfile.open(archive) as source:
        members = source.getmembers()
        if len(members) > 50000 or sum(m.size for m in members) > 512 * 1024**2:
            raise ValueError('source archive resource limit')
        names = set()
        for member in members:
            name = PurePosixPath(member.name)
            if (name.is_absolute() or '..' in name.parts or not name.parts or
                    name.parts[0] != expected_directory or member.name in names or
                    not (member.isdir() or member.isfile())):
                raise ValueError('unexpected source member; no extraction performed')
            names.add(member.name)
            tarfile.data_filter(member, str(destination))
        source.extractall(destination, members=members, filter='data')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--cmake', required=True, type=Path)
    parser.add_argument('--cmake-sha256', required=True)
    parser.add_argument('--pkg-config', required=True, type=Path)
    parser.add_argument('--pkg-config-sha256', required=True)
    args = parser.parse_args()
    if sys.platform != 'darwin' or platform.machine() not in ('arm64', 'x86_64'):
        raise ValueError('actual Mac build host required')
    root = args.root.absolute()
    if root.exists() or root.parent.resolve() != root.parent:
        raise ValueError('new plain root under approved existing parent required')
    tool_rows = []
    for name, path, expected in [('cmake', args.cmake, args.cmake_sha256),
                                 ('pkg-config', args.pkg_config, args.pkg_config_sha256)]:
        if (not re.fullmatch('[0-9a-f]{64}', expected) or not path.is_absolute() or
                not path.is_file() or sha(path) != expected):
            raise ValueError('actual supplied tool SHA mismatch')
        tool_rows.append({'name': name, 'path': str(path), 'sha256': expected})
    root.mkdir(mode=0o700)
    for name in ('sources', 'archives', 'logs', 'reports', 'licenses', 'build', 'prefix'):
        (root / name).mkdir(mode=0o700)
    environment = dict(os.environ)
    # No external codec/pkg-config/Homebrew discovery; only owned dependencies.
    for name in ('DYLD_LIBRARY_PATH', 'DYLD_INSERT_LIBRARIES', 'LIBHEIF_PLUGIN_PATH',
                 'CMAKE_PREFIX_PATH', 'CMAKE_LIBRARY_PATH', 'CMAKE_INCLUDE_PATH',
                 'CPATH', 'LIBRARY_PATH', 'PKG_CONFIG_PATH', 'PKG_CONFIG_LIBDIR'):
        environment.pop(name, None)
    prefix = root / 'prefix'
    environment['PKG_CONFIG_LIBDIR'] = str(prefix / 'lib/pkgconfig')
    pins = json.loads((HERE / 'pins.json').read_text())
    records = []
    try:
        run(root, 'cmake-version', [str(args.cmake), '--version'], environment, 10)
        version = (root / 'logs/cmake-version.stdout').read_text().splitlines()[0]
        match = re.fullmatch(r'cmake version (\d+)\.(\d+)\.(\d+)(?:[-.].*)?', version)
        if not match or tuple(map(int, match.groups())) < (3, 25, 0):
            raise ValueError('CMake>=3.25 required by pinned Kvazaar')
        run(root, 'pkg-config-version', [str(args.pkg_config), '--version'], environment, 10)
        for row in pins['sources']:
            archive = root / 'archives' / row['filename']
            # --disable ignores .curlrc; no certificate relaxation. Redirects
            # may only remain HTTPS; fixed upstream URL plus content SHA binds.
            run(root, 'download-' + row['name'], ['/usr/bin/curl', '--disable',
                '--fail', '--location', '--proto', '=https', '--proto-redir', '=https',
                '--connect-timeout', '10', '--max-time', '60', '--max-filesize', '16777216',
                '--output', str(archive), row['url']], environment, 70)
            if sha(archive) != row['sha256']:
                raise ValueError('official source digest mismatch')
            extract(archive, root / 'sources', row['directory'])
            directory = root / 'sources' / row['directory']
            notices = []
            for path in sorted(directory.rglob('*')):
                if path.is_file() and (path.name.startswith(('COPYING', 'LICENSE')) or path.name == 'CREDITS'):
                    target = root / 'licenses' / row['name'] / path.relative_to(directory)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with target.open('xb') as stream:
                        stream.write(path.read_bytes())
                    notices.append({'sourceMember': str(path.relative_to(directory)),
                                    'sha256': sha(target), 'bytes': target.stat().st_size})
            if not notices:
                raise ValueError('actual source license materials absent')
            records.append(dict(row, actualSHA256=sha(archive), notices=notices))
        new_json(root / 'reports/acquisition.json', {'sources': records,
            'pinsSHA256': sha(HERE / 'pins.json'), 'tools': tool_rows,
            'releaseApproved': False, 'toolchainCorrespondenceComplete': False})
        common = ['-G', 'Unix Makefiles', '-DCMAKE_BUILD_TYPE=Release',
                  '-DBUILD_SHARED_LIBS=ON', '-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0',
                  '-DCMAKE_OSX_ARCHITECTURES=' + platform.machine(),
                  '-DCMAKE_INSTALL_PREFIX=' + str(prefix),
                  '-DCMAKE_PREFIX_PATH=' + str(prefix),
                  '-DPKG_CONFIG_EXECUTABLE=' + str(args.pkg_config),
                  '-DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF',
                  '-DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF']
        for name, directory, flags in [
                ('kvazaar', 'kvazaar-2.3.2', ['-DBUILD_TESTS=OFF', '-DBUILD_KVAZAAR_BINARY=OFF', '-DUSE_CRYPTO=OFF']),
                ('libde265', 'libde265-1.1.3', ['-DENABLE_DECODER=OFF', '-DENABLE_ENCODER=OFF',
                    '-DENABLE_SDL=OFF', '-DENABLE_INTERNAL_DEVELOPMENT_TOOLS=OFF', '-DWITH_FUZZERS=OFF'])]:
            build = root / 'build' / name
            run(root, name + '-configure', [str(args.cmake), '-S', str(root / 'sources' / directory),
                '-B', str(build)] + common + flags, environment)
            run(root, name + '-build', [str(args.cmake), '--build', str(build), '--parallel', '2'], environment)
            run(root, name + '-install', [str(args.cmake), '--install', str(build)], environment)
        heif_source = root / 'sources/libheif-1.23.5'
        cmakelists = (heif_source / 'CMakeLists.txt').read_text()
        codecs = re.findall(r'^plugin_option\(\s*(\w+)\s', cmakelists, re.MULTILINE)
        if not {'KVAZAAR', 'LIBDE265', 'X265', 'X264'} <= set(codecs):
            raise ValueError('pinned codec configuration changed')
        flags = ['-DWITH_' + codec + '=' + ('ON' if codec in ('KVAZAAR', 'LIBDE265') else 'OFF') for codec in codecs]
        flags += ['-DWITH_KVAZAAR_PLUGIN=OFF', '-DWITH_LIBDE265_PLUGIN=OFF',
                  '-DENABLE_PLUGIN_LOADING=OFF', '-DWITH_LIBSHARPYUV=OFF',
                  '-DWITH_HEADER_COMPRESSION=OFF', '-DWITH_UNCOMPRESSED_CODEC=OFF',
                  '-DWITH_WEBCODECS=OFF', '-DWITH_EXAMPLES=OFF', '-DWITH_GDK_PIXBUF=OFF',
                  '-DBUILD_TESTING=OFF', '-DBUILD_DOCUMENTATION=OFF',
                  '-DENABLE_MULTITHREADING_SUPPORT=OFF', '-DENABLE_PARALLEL_TILE_DECODING=OFF']
        build = root / 'build/libheif'
        run(root, 'libheif-configure', [str(args.cmake), '-S', str(heif_source), '-B', str(build)] + common + flags, environment)
        summary = (root / 'logs/libheif-configure.stdout').read_text() + (root / 'logs/libheif-configure.stderr').read_text()
        for codec in ('Kvazaar HEVC encoder', 'libde265 HEVC decoder'):
            if not re.search(re.escape(codec) + r'\s*:\s*\+ built-in', summary):
                raise ValueError('actual required built-in codec unavailable')
        run(root, 'libheif-build', [str(args.cmake), '--build', str(build), '--parallel', '2'], environment)
        run(root, 'libheif-install', [str(args.cmake), '--install', str(build)], environment)
        run(root, 'helper-build', ['/usr/bin/xcrun', 'clang++', '-std=c++20', '-O2',
            '-mmacosx-version-min=14.0', '-I' + str(prefix / 'include'),
            str(HERE / 'heic_cpu_candidate.cpp'), '-L' + str(prefix / 'lib'), '-lheif',
            '-Wl,-rpath,' + str(prefix / 'lib'), '-o', str(root / 'heic_cpu_candidate')], environment)
        for name in ('heic_cpu_candidate', 'prefix/lib/libheif.dylib', 'prefix/lib/libkvazaar.dylib', 'prefix/lib/libde265.dylib'):
            run(root, 'otool-' + Path(name).name, ['/usr/bin/otool', '-L', str(root / name)], environment, 10)
        # Preserve real bytes, license trees, configured flags and dependencies;
        # no claim of notarization/relink-complete/public redistribution readiness.
        inventory = [{'path': str(path.relative_to(root)), 'bytes': path.stat().st_size, 'sha256': sha(path)}
                     for path in sorted(root.rglob('*')) if path.is_file() and not path.is_symlink()]
        new_json(root / 'reports/build.json', {'status': 'source-build-complete-unverified-codec',
            'files': inventory, 'codecFlags': flags, 'tools': tool_rows,
            'helperSHA256': sha(HERE / 'heic_cpu_candidate.cpp'),
            'actualMac14EncodeVerified': False, 'bundleSourceAndRelinkComplete': False,
            'HDRVerified': False, 'releaseApproved': False})
    finally:
        for row in tool_rows:
            if sha(Path(row['path'])) != row['sha256']:
                raise ValueError('build tool changed during attempt')


if __name__ == '__main__':
    def terminate(_signum, _frame):
        raise KeyboardInterrupt('supervisor cancelled owned build')
    signal.signal(signal.SIGTERM, terminate)
    main()
