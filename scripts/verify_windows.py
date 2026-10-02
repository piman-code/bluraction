#!/usr/bin/env python3
"""Isolate each Qt/media test family and require explicit completed evidence.

Standard library only; no installation, OS input, or operating app control.
Windows children enter a private kill-on-close Job Object before the stdin gate
opens. A macOS/Linux execution reports that host, never Windows verification.
Portable historical fixture checks remain in their separate portable test job.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
TESTS = ROOT / 'Tests/WindowsAppTests'
PREFIX = 'BLURACTION_FAMILY_COMPLETE '
BACKENDS = {'test_pdf_legacy_geometry': 'ActualPDFMetadataTests',
            'test_heif_codec': 'ActualHeifCodecTests'}
SYMLINK_SKIPS = {
    'test_media_safety.MediaSafetyTests.test_symlink_leaf_is_rejected_and_no_follow_flag_is_used_when_available': 'This host cannot create synthetic symlinks: ',
    'test_media_safety.MediaSafetyTests.test_parent_symlink_retarget_during_read_is_rejected': 'This host cannot create synthetic symlinks: ',
    'test_media_safety.MediaSafetyTests.test_cache_retarget_and_snapshot_captured_identity_are_preserved': 'This host cannot create synthetic symlinks: ',
    'test_asset_timeline.AssetTimelineTests.test_file_replacement_and_leaf_symlink_fail_without_deleting_rival': 'Host cannot create a test-only symlink',
    'test_asset_timeline.AssetTimelineTests.test_parent_symlink_retarget_and_missing_path_are_generic_read_failures': 'Host cannot create a test-only directory symlink',
}
# Only this bootstrap executes before the parent assigns the Windows Job Object.
# Tests/native imports start after assignment, not merely after Popen creation.
CHILD = r'''
import sys
if sys.stdin.buffer.read(1) != b'G':
    raise SystemExit('Private child gate was not released')
import json, unittest
name, family = sys.argv[1:3]
suite = unittest.defaultTestLoader.loadTestsFromName(name)
collected = suite.countTestCases()
result = unittest.TextTestRunner(verbosity=2).run(suite)
row = dict(family=family, collected=collected, testsRun=result.testsRun,
           failures=len(result.failures), errors=len(result.errors),
           expectedFailures=len(result.expectedFailures),
           unexpectedSuccesses=len(result.unexpectedSuccesses),
           skips=[dict(testID=test.id(), reason=str(reason)) for test, reason in result.skipped])
print('BLURACTION_FAMILY_COMPLETE ' + json.dumps(row, sort_keys=True), flush=True)
raise SystemExit(0 if result.wasSuccessful() else 1)
'''


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def families(directory=TESTS):
    paths = sorted(directory.glob('test_*.py'))
    names = [p.stem for p in paths]
    if not names or len(names) != len(set(names)) or any(not re.fullmatch(r'test_[a-zA-Z0-9_]+', n) for n in names):
        raise ValueError('Missing, ambiguous or invalid Windows test family inventory')
    if any(not p.is_file() or p.is_symlink() for p in paths):
        raise ValueError('Test families must be regular source files')
    return names


def command(family, backend_only=False, python=sys.executable):
    name = 'Tests.WindowsAppTests.' + family
    if backend_only:
        name += '.' + BACKENDS[family]
    return [python, '-c', CHILD, name, family]


def completed_result(output, family, exit_code, *, backend_only=False):
    """Require one native unittest end and one exact, positive JSON completion."""
    result = {'status': 'failed-or-incomplete', 'testCount': 0, 'skips': []}
    lines = [line[len(PREFIX):] for line in output.splitlines() if line.startswith(PREFIX)]
    summaries = re.findall(r'^Ran (\d+) tests? in [^\r\n]+$', output, re.MULTILINE)
    endings = re.findall(r'^(?:OK(?: \([^\r\n]*\))?|FAILED \([^\r\n]*\))$', output, re.MULTILINE)
    if len(lines) != 1 or len(summaries) != 1 or len(endings) != 1:
        return result
    try:
        row = json.loads(lines[0])
        numeric = ('collected', 'testsRun', 'failures', 'errors', 'expectedFailures', 'unexpectedSuccesses')
        if (not isinstance(row, dict) or row.get('family') != family or
                any(type(row.get(k)) is not int or row[k] < 0 for k in numeric) or
                not isinstance(row.get('skips'), list)):
            return result
        skips = row['skips']
        if any(not isinstance(s, dict) or set(s) != {'testID', 'reason'} or
               not isinstance(s['testID'], str) or not isinstance(s['reason'], str) for s in skips):
            return result
        result['skips'] = skips
        result['completion'] = row
        result['testCount'] = row['testsRun']
        allowed = []
        for skip in skips:
            key = skip['testID'].removeprefix('Tests.WindowsAppTests.')
            reason = SYMLINK_SKIPS.get(key)
            allowed.append(not backend_only and reason is not None and
                           skip['testID'].startswith('Tests.WindowsAppTests.' + family + '.') and
                           (skip['reason'].startswith(reason) if reason.endswith(': ') else skip['reason'] == reason))
        if len({s['testID'] for s in skips}) != len(skips):
            return result
        expected_end = 'OK' if not skips else f'OK (skipped={len(skips)})'
        # Class-level skips run zero tests and fail here even when exit is zero.
        if (exit_code == 0 and row['testsRun'] > 0 and row['collected'] == row['testsRun'] and
                int(summaries[0]) == row['testsRun'] and endings[0] == expected_end and
                not any(row[k] for k in numeric[2:]) and len(skips) <= row['testsRun'] and all(allowed)):
            result['status'] = 'pass-with-host-skips' if skips else 'pass'
    except (ValueError, TypeError, KeyError):
        pass
    return result


class WindowsJob:
    """Own only the gated Popen child and its descendants (kernel32, no shell)."""
    def __init__(self):
        import ctypes
        from ctypes import wintypes as w
        self.c = ctypes
        self.api = ctypes.WinDLL('kernel32', use_last_error=True)
        class BASIC(ctypes.Structure):
            _fields_ = [('PerProcessUserTimeLimit', ctypes.c_int64), ('PerJobUserTimeLimit', ctypes.c_int64),
                        ('LimitFlags', w.DWORD), ('MinimumWorkingSetSize', ctypes.c_size_t),
                        ('MaximumWorkingSetSize', ctypes.c_size_t), ('ActiveProcessLimit', w.DWORD),
                        ('Affinity', ctypes.c_size_t), ('PriorityClass', w.DWORD), ('SchedulingClass', w.DWORD)]
        class IO(ctypes.Structure):
            _fields_ = [(n, ctypes.c_uint64) for n in ('ReadOperationCount', 'WriteOperationCount',
                        'OtherOperationCount', 'ReadTransferCount', 'WriteTransferCount', 'OtherTransferCount')]
        class EXTENDED(ctypes.Structure):
            _fields_ = [('BasicLimitInformation', BASIC), ('IoInfo', IO), ('ProcessMemoryLimit', ctypes.c_size_t),
                        ('JobMemoryLimit', ctypes.c_size_t), ('PeakProcessMemoryUsed', ctypes.c_size_t),
                        ('PeakJobMemoryUsed', ctypes.c_size_t)]
        self.api.CreateJobObjectW.argtypes = [ctypes.c_void_p, w.LPCWSTR]
        self.api.CreateJobObjectW.restype = w.HANDLE
        self.api.SetInformationJobObject.argtypes = [w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD]
        self.api.SetInformationJobObject.restype = w.BOOL
        self.api.AssignProcessToJobObject.argtypes = [w.HANDLE, w.HANDLE]
        self.api.AssignProcessToJobObject.restype = w.BOOL
        self.api.TerminateJobObject.argtypes = [w.HANDLE, w.UINT]
        self.api.TerminateJobObject.restype = w.BOOL
        class ACCOUNTING(ctypes.Structure):
            _fields_ = [(n, ctypes.c_int64) for n in ('TotalUserTime', 'TotalKernelTime',
                        'ThisPeriodTotalUserTime', 'ThisPeriodTotalKernelTime')] + [
                        (n, w.DWORD) for n in ('TotalPageFaultCount', 'TotalProcesses',
                        'ActiveProcesses', 'TotalTerminatedProcesses')]
        self.accounting_type = ACCOUNTING
        self.api.QueryInformationJobObject.argtypes = [w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD, ctypes.c_void_p]
        self.api.QueryInformationJobObject.restype = w.BOOL
        self.api.CloseHandle.argtypes = [w.HANDLE]
        self.api.CloseHandle.restype = w.BOOL
        self.handle = self.api.CreateJobObjectW(None, None)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())
        info = EXTENDED()
        info.BasicLimitInformation.LimitFlags = 0x00002000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not self.api.SetInformationJobObject(self.handle, 9, ctypes.byref(info), ctypes.sizeof(info)):
            error = ctypes.WinError(ctypes.get_last_error()); self.close(); raise error

    def assign(self, child):
        # subprocess keeps the real process HANDLE, not a guessed/reused PID.
        if not self.api.AssignProcessToJobObject(self.handle, int(child._handle)):
            raise self.c.WinError(self.c.get_last_error())

    def terminate(self):
        if not self.api.TerminateJobObject(self.handle, 1):
            raise self.c.WinError(self.c.get_last_error())

    def drain(self):
        # Termination is asynchronous: wait for ActiveProcesses==0 before any
        # log/source hash, including descendants of an exited-zero leader.
        self.terminate()
        deadline = time.monotonic() + 10
        while True:
            info = self.accounting_type()
            if not self.api.QueryInformationJobObject(self.handle, 1, self.c.byref(info), self.c.sizeof(info), None):
                raise self.c.WinError(self.c.get_last_error())
            if not info.ActiveProcesses:
                return
            if time.monotonic() >= deadline:
                raise TimeoutError('Private Windows job descendants did not terminate')
            time.sleep(.01)

    def close(self):
        if self.handle:
            handle, self.handle = self.handle, None
            if not self.api.CloseHandle(handle):
                raise self.c.WinError(self.c.get_last_error())


def run_command(argv, log, timeout):
    """Gated private tree; even an exit-zero parent cannot leave grandchildren."""
    env = dict(os.environ, QT_QPA_PLATFORM='offscreen', PYTHONUNBUFFERED='1', PYTHONUTF8='1')
    job = WindowsJob() if os.name == 'nt' else None
    child = None
    try:
        child = subprocess.Popen(argv, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                 stdin=subprocess.PIPE, env=env,
                                 start_new_session=os.name != 'nt')
        if job is not None:
            job.assign(child)
        child.stdin.write(b'G'); child.stdin.flush(); child.stdin.close()
        try:
            return child.wait(timeout=timeout), False
        except subprocess.TimeoutExpired:
            if job is not None:
                job.terminate()
            else:
                try: os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError: pass
            child.wait(timeout=10)
            return None, True
    finally:
        # Close also kills descendants left behind after an apparently completed
        # leader. The log is hashed only after this private tree cleanup.
        if job is not None:
            try:
                job.drain()
            finally:
                try:
                    job.close()
                finally:
                    if child is not None and child.poll() is None:
                        child.kill(); child.wait(timeout=10)
        elif child is not None:
            try: os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            if child.poll() is None:
                child.wait(timeout=10)
        if child is not None and child.stdin is not None and not child.stdin.closed:
            child.stdin.close()


def source_inputs():
    paths = [Path(__file__).resolve(), ROOT / '.gitattributes', ROOT / 'platforms/windows/build_package.ps1',
             ROOT / 'platforms/windows/requirements-dev.txt']
    for folder in ('shared', 'platforms/windows/bluraction', 'Tests/WindowsAppTests', 'Tests/PortableProjectTests', 'Tests/VerificationRunnerTests'):
        paths += sorted((ROOT / folder).glob('*.py'))
    paths += sorted((ROOT / 'shared').glob('*.json'))
    paths += sorted((ROOT / 'shared/fixtures').rglob('*'))
    regular = [p for p in paths if p.is_file()]
    if any(p.is_symlink() for p in regular):
        raise ValueError('Verification inputs must be regular nonsymlink source or synthetic fixture files')
    return {p.relative_to(ROOT).as_posix(): sha(p) for p in regular}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--family', action='append', help='Exact file stem; repeat for selected families')
    parser.add_argument('--required-backends-only', action='store_true')
    parser.add_argument('--timeout', type=float, default=300, help='Deadline seconds per family, at most 900')
    parser.add_argument('--output', type=Path, help='Fresh output directory, never overwritten')
    args = parser.parse_args(argv)
    known = families()
    selected = sorted(BACKENDS) if args.required_backends_only else args.family or known
    if (args.required_backends_only and args.family or not math.isfinite(args.timeout) or
            not 0 < args.timeout <= 900 or len(selected) != len(set(selected)) or any(f not in known for f in selected)):
        parser.error('Require unique known families, bounded timeout, and a separate backend-only mode')
    destination = (args.output or ROOT / '.build' / ('windows-verification-' + str(uuid.uuid4()))).absolute()
    destination.parent.mkdir(parents=True, exist_ok=True); destination.mkdir()
    before = source_inputs()
    report = dict(status='running', host=sys.platform, OSInput=False, installs=False,
                  actualWindows=sys.platform == 'win32', requestedFamilies=selected,
                  inventory=known, backendOnly=args.required_backends_only,
                  fullInventoryRequested=not args.family and not args.required_backends_only,
                  inputs=before, families=[], limitations=['Synthetic native API tests; not desktop/install/user acceptance.'])
    for family in selected:
        path = destination / (family + '.log')
        with path.open('x', encoding='utf-8') as log:
            try:
                exit_code, timeout = run_command(command(family, args.required_backends_only), log, args.timeout)
                row = completed_result(path.read_text(encoding='utf-8', errors='replace'), family, exit_code,
                                       backend_only=args.required_backends_only)
                if timeout:
                    row['status'] = 'failed-or-incomplete'
                row.update(exit=exit_code, timedOut=timeout)
            except Exception as error:
                row = dict(status='failed-or-incomplete', testCount=0, skips=[], exit=None,
                           timedOut=False, runnerError=type(error).__name__ + ': ' + str(error))
        row.update(family=family, log=str(path), logSHA256=sha(path))
        report['families'].append(row); print(json.dumps(row), flush=True)
        if row['status'] not in ('pass', 'pass-with-host-skips'): break
    report['inputsUnchanged'] = source_inputs() == before
    report['testCount'] = sum(r['testCount'] for r in report['families'])
    passed = (report['inputsUnchanged'] and len(report['families']) == len(selected) and
              all(r['status'] in ('pass', 'pass-with-host-skips') for r in report['families']))
    report['status'] = 'source-linked-families-pass' if passed else 'failed-or-incomplete'
    target = destination / 'report.json'
    target.write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(target, flush=True)
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
