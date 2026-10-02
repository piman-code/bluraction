#!/usr/bin/env python3
"""Observe all 51 synthetic ImageIO attempts in individually owned processes.

Exit 0: 51 readable encodes; 3: complete encode-failure/crash observations;
1: timeout/missing evidence/cleanup or preservation failure. No install/OS input.
Crash does not prove unsupported format and never becomes a successful encode.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
SIZES = ((48, 32), (96, 64), (256, 128))
VARIANTS = ('direct-source', 'default-CI', 'explicit-RGBA8-sRGB', 'software-RGBA8-sRGB')
TYPES = ('public.png', 'public.jpeg', 'public.heic', 'public.tiff')
FATAL_SIGNALS = {int(getattr(signal, name)) for name in
                 ('SIGSEGV', 'SIGBUS', 'SIGABRT', 'SIGILL', 'SIGFPE') if hasattr(signal, name)}


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def identity(path):
    info = Path(path).lstat()
    return (info.st_dev, info.st_ino, info.st_mode, info.st_nlink,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def authored_rgba(width, height):
    colors = (bytes((255, 0, 0, 255)), bytes((0, 255, 0, 255)), bytes((0, 0, 255, 255)),
              bytes((0, 255, 255, 255)), bytes((255, 0, 255, 255)), bytes((255, 255, 0, 255)))
    return b''.join(colors[min(2, x * 3 // width) + (0 if y < height // 2 else 3)]
                    for y in range(height) for x in range(width))


def descriptor(index):
    width, height = SIZES[index // 17]
    slot = index % 17
    return dict(attemptIndex=index, width=width, height=height,
                variant='software-writeHEIFRepresentation' if slot == 16 else VARIANTS[slot // 4],
                type='public.heic' if slot == 16 else TYPES[slot % 4])


def supervisor_cancelled(_signal, _frame):
    # Installed only by this program's entrypoint. Imports do not alter the
    # caller's process signal handlers or state.
    raise KeyboardInterrupt('Supervisor cancelled the owned ImageIO diagnostic')


def run(command, stdout, stderr, timeout):
    """One new private PG; reaping/draining also occurs on ordinary exit/crash."""
    with Path(stdout).open('xb') as output, Path(stderr).open('xb') as error:
        child = subprocess.Popen(command, cwd=ROOT, stdin=subprocess.DEVNULL,
                                 stdout=output, stderr=error, start_new_session=True)
        expired = False
        try:
            try:
                child.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                expired = True
        finally:
            primary = sys.exception()
            try:
                try: os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError: pass
                child.wait(timeout=10)
                end = time.monotonic() + 5
                while True:
                    try: os.killpg(child.pid, 0)
                    except ProcessLookupError: break
                    if time.monotonic() >= end: raise RuntimeError('Owned native process group did not drain')
                    time.sleep(.01)
            except BaseException as cleanup:
                if primary is None: raise
                if cleanup is not primary: primary.add_note('Owned process cleanup also failed: ' + type(cleanup).__name__)
                raise primary
        return child.returncode, expired


def checkpoints(path):
    if Path(path).stat().st_size > 4 * 1024 * 1024:
        raise ValueError('Native stderr exceeded bounded checkpoint size')
    result = []
    for line in Path(path).read_text(encoding='utf-8', errors='replace').splitlines():
        try: row = json.loads(line)
        except ValueError: continue  # native crash text is retained in the original log
        if isinstance(row, dict) and isinstance(row.get('diagnosticStage'), str): result.append(row)
    return result


def cleanup_output(folder, captured):
    """Only the new 0700 attempt output subtree; no input/log deletion."""
    folder = Path(folder)
    current = identity(folder)
    if current[:2] != captured[:2] or not stat.S_ISDIR(current[2]) or folder.resolve() != folder:
        raise ValueError('Owned native output directory identity changed')
    count = total = 0
    for parent, dirs, files in os.walk(folder, followlinks=False):
        if len(Path(parent).relative_to(folder).parts) > 2: raise ValueError('Unexpected native output depth')
        for name in dirs + files:
            path = Path(parent) / name; info = path.lstat(); count += 1
            if count > 128 or path.resolve() != path or not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
                raise ValueError('Unexpected/linked native output member')
            if stat.S_ISREG(info.st_mode):
                total += info.st_size
                if info.st_size > 16 * 1024 * 1024 or total > 32 * 1024 * 1024:
                    raise ValueError('Native output byte ceiling exceeded')
    if identity(folder)[:2] != captured[:2]: raise ValueError('Owned output retargeted before cleanup')
    shutil.rmtree(folder)
    if folder.exists() or folder.is_symlink(): raise ValueError('Owned native output cleanup incomplete')


def observe_attempt(binary, parent, index, timeout, runner=run):
    row = descriptor(index)
    attempt = Path(parent) / ('attempt-%02d' % index); attempt.mkdir(mode=0o700)
    output = attempt / 'native-output'; output.mkdir(mode=0o700)
    output_identity = identity(output)
    source = attempt / 'input.rgba'
    with source.open('xb') as stream: stream.write(authored_rgba(row['width'], row['height']))
    source_before, source_sha = identity(source), sha(source)
    stdout, stderr = attempt / 'native.json', attempt / 'native.stderr'
    row.update(status='incomplete', succeeded=False, sourceSHA256=source_sha,
               nativeMemoryPreservationVerified=None, cleanupSucceeded=False)
    try:
        code, expired = runner([str(binary), '--attempt-index', str(index), '--input-rgba', str(source),
                               '--output-parent', str(output), '--cleanup'], stdout, stderr, timeout)
        row.update(nativeExit=code, timedOut=expired)
        observed = checkpoints(stderr)
        row['checkpoints'] = observed
        row['lastCheckpoint'] = observed[-1] if observed else None
        ready = [p for p in observed if p.get('diagnosticStage') == 'source-ready']
        if (len(ready) != 1 or ready[0].get('attemptIndex') != index or
                ready[0].get('width') != row['width'] or ready[0].get('height') != row['height'] or
                ready[0].get('authoredRGBA8SHA256') != source_sha or ready[0].get('inputFileSHA256') != source_sha):
            raise ValueError('Missing exact authored-source checkpoint')
        if expired:
            raise RuntimeError('Native attempt timed out; capability remains unverified')
        if code in {-int(s) for s in FATAL_SIGNALS}:
            row.update(status='native-process-crash-observed', crashSignal=-code,
                       nativeMemoryPreservationVerified=None,
                       limitation='Native source after-hash unavailable after process crash; disk input independently preserved')
        else:
            if code not in (0, 3) or not 0 < stdout.stat().st_size <= 1024 * 1024:
                raise ValueError('Native attempt lacks a complete bounded report')
            native = json.loads(stdout.read_text(encoding='utf-8'))
            results, sources = native.get('results'), native.get('sources')
            if (native.get('schemaVersion') != 2 or native.get('attemptIndex') != index or
                    native.get('attemptCount') != 1 or native.get('cleanupSucceeded') is not True or
                    native.get('sourcesPreserved') is not True or not isinstance(results, list) or len(results) != 1 or
                    not isinstance(sources, list) or len(sources) != 1 or
                    sources[0].get('authoredRGBA8SHA256') != source_sha or sources[0].get('sourcePreserved') is not True or
                    results[0].get('variant') != row['variant'] or results[0].get('type') != row['type'] or
                    native.get('width') != row['width'] or native.get('height') != row['height']):
                raise ValueError('Incomplete attempt identity/source/cleanup evidence')
            succeeded = results[0].get('succeeded') is True
            if (code == 0) != succeeded or native.get('failedAttemptCount') != (0 if succeeded else 1):
                raise ValueError('Native exit disagrees with encode observations')
            row.update(status='encode-readable' if succeeded else 'encode-failure-observed',
                       succeeded=succeeded, nativeReport=native, nativeMemoryPreservationVerified=True)
    except BaseException as error:
        row.update(status='incomplete', error=type(error).__name__ + ': ' + str(error))
        if not isinstance(error, Exception): raise
    finally:
        try:
            row['sourcePreserved'] = identity(source) == source_before and sha(source) == source_sha
            if not row['sourcePreserved']: raise ValueError('Authored input file changed')
        except Exception as error:
            row.update(status='incomplete', preservationError=type(error).__name__ + ': ' + str(error))
        try:
            cleanup_output(output, output_identity)
            row['cleanupSucceeded'] = True
        except Exception as error:
            row.update(status='incomplete', cleanupError=type(error).__name__ + ': ' + str(error))
        primary = sys.exception()
        try:
            row['logs'] = {p.name: sha(p) for p in (stdout, stderr) if p.is_file()}
            with (attempt / 'observation.json').open('x', encoding='utf-8') as stream:
                json.dump(row, stream, indent=2)
        except BaseException as evidence_error:
            if primary is None: raise
            if evidence_error is not primary:
                primary.add_note('Owned attempt evidence also failed: ' + type(evidence_error).__name__)
    return row


def observe_all(binary, parent, timeout, runner=run):
    # No native capability failure short-circuits later formats/variants/sizes.
    rows = []
    for index in range(51):
        try: rows.append(observe_attempt(binary, parent, index, timeout, runner))
        except Exception as error:
            rows.append(dict(descriptor(index), status='incomplete', succeeded=False,
                             sourcePreserved=False, cleanupSucceeded=False,
                             error=type(error).__name__ + ': ' + str(error)))
    return rows


def verdict(rows):
    complete = (len(rows) == 51 and [r.get('attemptIndex') for r in rows] == list(range(51)) and
                all(r.get('status') in ('encode-readable', 'encode-failure-observed', 'native-process-crash-observed') and
                    r.get('sourcePreserved') is True and r.get('cleanupSucceeded') is True for r in rows))
    return (0 if all(r.get('succeeded') is True for r in rows) else 3) if complete else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--timeout', type=float, default=90, help='Per-attempt deadline, 1..180 seconds')
    options = parser.parse_args()
    if sys.platform != 'darwin' or not math.isfinite(options.timeout) or not 1 <= options.timeout <= 180:
        parser.error('Requires macOS and a bounded 1..180-second per-child deadline')
    out = ROOT / '.build' / ('image-io-diagnostic-' + str(uuid.uuid4()))
    out.mkdir(mode=0o700, parents=True)
    source = ROOT / 'scripts/diagnose_image_io.swift'
    inputs = {str(source.relative_to(ROOT)): sha(source), str(Path(__file__).resolve().relative_to(ROOT)): sha(__file__)}
    record = dict(schemaVersion=2, diagnosticOnly=True, OSInput=False, installs=False, inputs=inputs,
                  status='incomplete', nativeExit=None, timeoutSeconds=options.timeout,
                  sourcePreservationScope='External exact authored RGBA input files; native after-hash separately recorded per attempt')
    try:
        binary = out / 'diagnose_image_io'
        code, expired = run(['/usr/bin/xcrun', 'swiftc', '-parse-as-library', '-module-cache-path',
                             str(ROOT / '.build/clang-cache'), str(source), '-o', str(binary)],
                            out / 'compile.stdout', out / 'compile.stderr', options.timeout)
        record.update(compileExit=code, compileTimedOut=expired)
        if code != 0 or expired: raise RuntimeError('Diagnostic compilation incomplete')
        record['binarySHA256'] = sha(binary)
        rows = observe_all(binary, out, options.timeout)
        code = verdict(rows)
        native = dict(schemaVersion=2, attemptCount=len(rows), results=rows,
                      failedAttemptCount=sum(r.get('succeeded') is not True for r in rows),
                      incompleteAttemptCount=sum(r.get('status') == 'incomplete' for r in rows),
                      nativeCrashCount=sum(r.get('status') == 'native-process-crash-observed' for r in rows),
                      sourcesPreserved=all(r.get('sourcePreserved') is True for r in rows),
                      cleanupSucceeded=all(r.get('cleanupSucceeded') is True for r in rows),
                      nativeMemoryPreservationVerified=all(r.get('nativeMemoryPreservationVerified') is True for r in rows))
        raw = out / 'native.json'; raw.write_text(json.dumps(native, indent=2), encoding='utf-8')
        record.update(nativeExit=code, status='complete-observations' if code in (0, 3) else 'incomplete',
                      failedAttemptCount=native['failedAttemptCount'], nativeCrashCount=native['nativeCrashCount'],
                      nativeReportSHA256=sha(raw), binaryUnchanged=sha(binary) == record['binarySHA256'])
        if not record['binaryUnchanged']: raise RuntimeError('Diagnostic executable changed')
    except BaseException as error:
        record.update(status='incomplete', error=type(error).__name__ + ': ' + str(error))
    record['inputsUnchanged'] = all(sha(ROOT / name) == digest for name, digest in inputs.items())
    if not record['inputsUnchanged']: record['status'] = 'incomplete'
    record['logs'] = {p.relative_to(out).as_posix(): sha(p) for p in out.rglob('*')
                      if p.is_file() and p != out / 'diagnose_image_io'}
    (out / 'execution.json').write_text(json.dumps(record, indent=2), encoding='utf-8')
    print(json.dumps(dict(report=str(out / 'execution.json'), status=record['status'], nativeExit=record['nativeExit'],
                          failedAttemptCount=record.get('failedAttemptCount'), nativeCrashCount=record.get('nativeCrashCount'))))
    return record['nativeExit'] if record['status'] == 'complete-observations' else 1


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, supervisor_cancelled)
    raise SystemExit(main())
