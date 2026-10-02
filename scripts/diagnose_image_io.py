#!/usr/bin/env python3
"""Run51 authored ImageIO comparisons with owned process deadlines.

Exit0:51 readable encodes;3:observed encode failure;1:incomplete diagnostics.
No installation or OS input automation.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import uuid

ROOT = Path(__file__).absolute().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command, stdout, stderr, timeout):
    with stdout.open('xb') as output, stderr.open('xb') as error:
        child = subprocess.Popen(command, cwd=ROOT, stdout=output, stderr=error, start_new_session=True)
        try:
            return child.wait(timeout=timeout), False
        except subprocess.TimeoutExpired:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()
            return child.returncode, True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--timeout', type=float, default=90)
    options = parser.parse_args()
    if sys.platform != 'darwin' or not math.isfinite(options.timeout) or not 1 <= options.timeout <= 180:
        parser.error('Requires macOS and a bounded1..180-second deadline')
    out = ROOT / '.build' / ('image-io-diagnostic-' + str(uuid.uuid4()))
    out.mkdir(parents=True)
    source = ROOT / 'scripts/diagnose_image_io.swift'
    inputs = {str(source.relative_to(ROOT)): sha(source),
              str(Path(__file__).absolute().relative_to(ROOT)): sha(Path(__file__))}
    record = dict(diagnosticOnly=True, OSInput=False, installs=False, inputs=inputs,
                  status='incomplete', nativeExit=None, timeoutSeconds=options.timeout)
    try:
        binary = out / 'diagnose_image_io'
        code, expired = run(['xcrun', 'swiftc', '-parse-as-library',
                             '-module-cache-path', str(ROOT / '.build/clang-cache'),
                             str(source), '-o', str(binary)],
                            out / 'compile.stdout', out / 'compile.stderr', options.timeout)
        record.update(compileExit=code, compileTimedOut=expired)
        if code != 0 or expired:
            raise RuntimeError('Diagnostic compilation incomplete')
        record['binarySHA256'] = sha(binary)
        code, expired = run([str(binary), '--output-parent', str(out), '--cleanup'],
                            out / 'native.json', out / 'native.stderr', options.timeout)
        record.update(nativeExit=code, nativeTimedOut=expired)
        if expired or code not in (0, 3):
            raise RuntimeError('Diagnostic execution/cleanup incomplete')
        raw = out / 'native.json'
        if not 0 < raw.stat().st_size <= 1024 * 1024:
            raise RuntimeError('Diagnostic JSON missing or outside bounded size')
        native = json.loads(raw.read_text(encoding='utf-8'))
        if native.get('attemptCount') != 51 or not native.get('sourcesPreserved') or not native.get('cleanupSucceeded'):
            raise RuntimeError('Missing complete51 observations/source preservation/cleanup')
        if (code == 0) != (native.get('failedAttemptCount') == 0):
            raise RuntimeError('Diagnostic exit disagrees with failure observations')
        record.update(status='complete-observations', failedAttemptCount=native['failedAttemptCount'],
                      nativeReportSHA256=sha(raw), binaryUnchanged=sha(binary) == record['binarySHA256'])
        if not record['binaryUnchanged']:
            raise RuntimeError('Diagnostic executable changed')
    except Exception as error:
        record.update(status='incomplete', error=type(error).__name__ + ': ' + str(error))
    record['inputsUnchanged'] = all(sha(ROOT / name) == digest for name, digest in inputs.items())
    if not record['inputsUnchanged']:
        record['status'] = 'incomplete'
    record['logs'] = {p.name: sha(p) for p in out.iterdir() if p.is_file() and p.name != 'diagnose_image_io'}
    (out / 'execution.json').write_text(json.dumps(record, indent=2), encoding='utf-8')
    print(json.dumps(dict(report=str(out / 'execution.json'), status=record['status'],
                          nativeExit=record['nativeExit'], failedAttemptCount=record.get('failedAttemptCount'))))
    return record['nativeExit'] if record['status'] == 'complete-observations' else 1


if __name__ == '__main__':
    raise SystemExit(main())
