"""Read an already installed VsDevCmd environment in an owned Windows Job.

No compiler installation, guessed PATH, global environment write or compiler
fallback. The fixed ASCII wrapper name removes PowerShell/native CMD quoting
from the command string; paths are supplied through child-only environment.
Actual stdout/stderr and exit status are retained even on failure. Pure tests
of this helper are not actual Windows/MSVC execution evidence.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PureWindowsPath
import stat
import subprocess
import sys

RUNNER_SHA256 = '312931a76abaeddc322f7a53a3802cd3fdac2f40685b1d5b53d3457720b8e276'
REPOSITORY = Path(__file__).resolve().parents[2]
IS_WINDOWS = os.name == 'nt'
ENVIRONMENT_NAMES = ('PATH', 'INCLUDE', 'LIB', 'LIBPATH', 'VCToolsInstallDir',
    'VCToolsVersion', 'VCINSTALLDIR', 'WindowsSdkDir', 'WindowsSDKVersion',
    'MSYSTEM', 'MSYS2_PATH_TYPE', 'PIP_CONFIG_FILE', 'PYTHONUTF8',
    'PYTHONUNBUFFERED', 'DISTUTILS_USE_SDK', 'MSSdk')
REQUIRED_NAMES = ('PATH', 'INCLUDE', 'LIB', 'LIBPATH', 'VCToolsInstallDir',
    'VCToolsVersion', 'VCINSTALLDIR', 'WindowsSdkDir', 'WindowsSDKVersion')
ARCHITECTURE_NAMES = ('VSCMD_ARG_HOST_ARCH', 'VSCMD_ARG_TGT_ARCH', 'VSCMD_VER')
CONTROL_NAMES = ('BLURACTION_MSVC_DEVCMD', 'BLURACTION_MSVC_PYTHON',
                 'BLURACTION_MSVC_CAPTURE', 'BLURACTION_MSVC_ENVIRONMENT')
BOOTSTRAP = "import sys,subprocess\nif sys.stdin.buffer.read(1)!=b'G': raise SystemExit(125)\nraise SystemExit(subprocess.call(sys.argv[1:]))\n"
WRAPPER = (
    '@echo off\r\n'
    'setlocal DisableDelayedExpansion\r\n'
    'call "%BLURACTION_MSVC_DEVCMD%" -no_logo -arch=x64 -host_arch=x64\r\n'
    'if not "%errorlevel%"=="0" exit /b %errorlevel%\r\n'
    '"%BLURACTION_MSVC_PYTHON%" "%BLURACTION_MSVC_CAPTURE%" emit --output "%BLURACTION_MSVC_ENVIRONMENT%"\r\n'
    'exit /b %errorlevel%\r\n'
)


def guarded_file(value):
    path = Path(value).absolute()
    if path.resolve(strict=True) != path:
        raise ValueError('plain existing file required')
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or getattr(before, 'st_file_attributes', 0) & 0x400:
        raise ValueError('regular non-reparse file required')
    identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
    with path.open('rb') as stream:
        fd = os.fstat(stream.fileno())
        # Windows path/FD ctime domains differ: compare common fields here,
        # then compare path/path and FD/FD independently after the read.
        common = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns)
        if common(before) != common(fd):
            raise ValueError('file changed before read')
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        if identity(os.fstat(stream.fileno())) != identity(fd):
            raise ValueError('file changed during read')
    if path.resolve(strict=True) != path or identity(path.lstat()) != identity(before):
        raise ValueError('pathname changed during read')
    return {'sha256': digest, 'bytes': before.st_size, 'identity': identity(before)}


def validate_control_path(value):
    """CALL reparses percent expansion; reject ambiguous control characters."""
    text = str(value)
    if not text or any(c in text for c in ('%', '!', '"', '\r', '\n', '\0')):
        raise ValueError('batch control path cannot contain expansion/control characters')
    return text


def environment_document(environment):
    values = {name: environment.get(name) for name in ENVIRONMENT_NAMES}
    if any(type(values[name]) is not str or not values[name].strip() or
           any(c in values[name] for c in ('\r', '\n', '\0')) for name in REQUIRED_NAMES):
        raise ValueError('actual installed MSVC/SDK environment is incomplete')
    architecture = {name: environment.get(name) for name in ARCHITECTURE_NAMES}
    if (architecture['VSCMD_ARG_HOST_ARCH'] != 'x64' or
            architecture['VSCMD_ARG_TGT_ARCH'] != 'x64' or
            type(architecture['VSCMD_VER']) is not str or not architecture['VSCMD_VER'].strip()):
        raise ValueError('actual x64 host/target VsDevCmd result required')
    for name in ('VCToolsInstallDir', 'VCINSTALLDIR', 'WindowsSdkDir'):
        if not PureWindowsPath(values[name]).is_absolute():
            raise ValueError('actual absolute installed compiler/SDK roots required')
    return {'schemaVersion': 1, 'status': 'installed-vsdevcmd-x64-environment',
            'environment': values, 'architecture': architecture,
            'compilerExecuted': False, 'historicalVendorCompilerProven': False}


def write_json_new(path, document):
    with Path(path).open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(document, stream, indent=2, sort_keys=True); stream.write('\n')
        stream.flush(); os.fsync(stream.fileno())


def emit_environment(output):
    # Select explicit keys; never dump SET/full process environment or secrets.
    write_json_new(output, environment_document(os.environ))


def job_class():
    runner = REPOSITORY / 'scripts/verify_windows.py'
    if guarded_file(runner)['sha256'] != RUNNER_SHA256:
        raise ValueError('reviewed Windows Job implementation changed')
    spec = importlib.util.spec_from_file_location('_msvc_owned_process_scope', runner)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module.WindowsJob


def capture(root, devcmd, comspec, *, process_factory=subprocess.Popen, job_factory=None):
    if not IS_WINDOWS:
        raise ValueError('actual Windows environment capture required')
    root = Path(root).absolute()
    if root.resolve(strict=True) != root or not (root / 'owned.json').is_file():
        raise ValueError('existing attempt-owned plain root required')
    if (root / 'reports').resolve(strict=True) != root / 'reports' or not (root / 'reports').is_dir():
        raise ValueError('plain owned report directory required')
    paths = {'devcmd': Path(devcmd).absolute(), 'comspec': Path(comspec).absolute(),
             'python': Path(sys.executable).absolute(), 'capture': Path(__file__).resolve()}
    if paths['devcmd'].name.lower() != 'vsdevcmd.bat' or paths['comspec'].name.lower() != 'cmd.exe':
        raise ValueError('installed VsDevCmd and actual cmd.exe required')
    guards = {name: guarded_file(path) for name, path in paths.items()}
    for path in paths.values(): validate_control_path(path)
    folder = root / 'msvc-environment'
    folder.mkdir()  # New exclusive owned artifacts, never reuse failed attempts.
    wrapper = folder / 'msvc-environment.cmd'
    with wrapper.open('xb') as stream: stream.write(WRAPPER.encode('ascii'))
    result_path = folder / 'environment.json'
    validate_control_path(result_path)
    environment = os.environ.copy()
    environment.update(dict(zip(CONTROL_NAMES, (str(paths['devcmd']), str(paths['python']),
                                               str(paths['capture']), str(result_path)))))
    # Fail closed if a no-op/degraded DevCmd merely inherits a previous prompt.
    for name in REQUIRED_NAMES + ARCHITECTURE_NAMES:
        if name != 'PATH': environment.pop(name, None)
    argv = [str(paths['comspec']), '/d', '/s', '/v:off', '/c', wrapper.name]
    job = (job_factory or job_class())(); child = None; primary = None
    report = {'schemaVersion': 1, 'status': 'failed-or-incomplete', 'exitCode': None,
              'timedOut': False, 'privateTreeDrained': False, 'timeoutSeconds': 120,
              'commandArguments': ['/d', '/s', '/v:off', '/c', wrapper.name],
              'inputs': {k: {'sha256': v['sha256'], 'bytes': v['bytes']} for k,v in guards.items()},
              'wrapperSHA256': guarded_file(wrapper)['sha256'],
              'releaseApproved': False, 'compilerExecuted': False}
    try:
        with (folder / 'stdout.txt').open('xb') as stdout, (folder / 'stderr.txt').open('xb') as stderr:
            child = process_factory([str(paths['python']), '-c', BOOTSTRAP, *argv], cwd=folder,
                env=environment, stdin=subprocess.PIPE, stdout=stdout, stderr=stderr)
            job.assign(child)
            child.stdin.write(b'G'); child.stdin.flush(); child.stdin.close()
            try:
                report['exitCode'] = child.wait(timeout=120)
            except subprocess.TimeoutExpired:
                report['timedOut'] = True
                job.terminate(); report['exitCode'] = child.wait(timeout=10)
            job.drain(); report['privateTreeDrained'] = True
        if report['exitCode'] != 0 or report['timedOut']:
            raise ValueError('VsDevCmd failed; see retained owned stdout/stderr/exit report')
        result_guard = guarded_file(result_path)
        if result_guard['bytes'] > 4 * 1024**2:
            raise ValueError('bounded selected environment output required')
        data = result_path.read_bytes()
        if (hashlib.sha256(data).hexdigest() != result_guard['sha256'] or
                guarded_file(result_path) != result_guard):
            raise ValueError('selected environment changed during adoption')
        document = json.loads(data)
        if document != environment_document(document['environment'] | document['architecture']):
            raise ValueError('selected environment document differs from strict contract')
        if any(guarded_file(path) != guards[name] for name, path in paths.items()):
            raise ValueError('installed MSVC capture inputs changed')
        report.update(status='installed-msvc-environment-captured',
                      environmentSHA256=result_guard['sha256'])
    except BaseException as error:
        primary = error; report['errorType'] = type(error).__name__
    finally:
        try:
            job.drain(); report['privateTreeDrained'] = True
        except BaseException as cleanup:
            report.update(status='failed-or-incomplete', privateTreeDrained=False,
                          cleanupErrorType=type(cleanup).__name__)
            if primary is None: primary = cleanup
            elif cleanup is not primary: primary.add_note('owned MSVC job drain also failed')
        finally:
            try: job.close()
            except BaseException as cleanup:
                report['status'] = 'failed-or-incomplete'
                if primary is None: primary = cleanup
                elif cleanup is not primary: primary.add_note('owned MSVC job close also failed')
        if child is not None and child.poll() is None:
            try: child.kill(); child.wait(timeout=10)
            except BaseException as cleanup:
                report['status'] = 'failed-or-incomplete'
                if primary is None: primary = cleanup
                elif cleanup is not primary: primary.add_note('owned MSVC direct child reap also failed')
        if child is not None and child.stdin is not None and not child.stdin.closed:
            try: child.stdin.close()
            except BaseException as cleanup:
                report['status'] = 'failed-or-incomplete'
                if primary is None: primary = cleanup
                elif cleanup is not primary: primary.add_note('owned MSVC stdin close also failed')
        for name in ('stdout.txt', 'stderr.txt'):
            path = folder / name
            try:
                if path.is_file():
                    row = guarded_file(path)
                    report[name] = {'sha256': row['sha256'], 'bytes': row['bytes']}
                    if row['bytes'] > 4 * 1024**2: raise ValueError('MSVC diagnostic output limit exceeded')
            except BaseException as cleanup:
                report['status'] = 'failed-or-incomplete'
                if primary is None: primary = cleanup
                elif cleanup is not primary: primary.add_note('owned MSVC diagnostic readback also failed')
        try: write_json_new(root / 'reports/msvc-environment-capture.json', report)
        except BaseException as cleanup:
            if primary is None: primary = cleanup
            elif cleanup is not primary: primary.add_note('owned MSVC capture report also failed')
    if primary is not None: raise primary
    return report


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest='command', required=True)
    emission = commands.add_parser('emit'); emission.add_argument('--output', type=Path, required=True)
    acquire = commands.add_parser('capture')
    for name in ('root', 'devcmd', 'comspec'): acquire.add_argument('--'+name, type=Path, required=True)
    args = parser.parse_args()
    if args.command == 'emit': emit_environment(args.output)
    else: capture(args.root, args.devcmd, args.comspec)


if __name__ == '__main__': main()
