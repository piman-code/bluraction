"""Run an actual frozen candidate in an isolated working directory and owned job."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import sys

if __package__ in (None, ''):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts.verify_windows import run_command
from shared import windows_package_receipt as files


# The owner assigns this waiting wrapper to its private Windows Job before G.
# The frozen child and its descendants inherit that job and its total deadline.
WRAPPER = r'''
import os, subprocess, sys
if sys.stdin.buffer.read(1) != b'G': raise SystemExit(2)
exe, output, working = sys.argv[1:]
env = {key.upper(): value for key, value in os.environ.items()}
for key in list(env):
    if key.upper().startswith(('PYTHON', 'QT_', 'PYSIDE', 'VIRTUAL_ENV')):
        del env[key]
system = env.get('SYSTEMROOT')
if not system:
    raise ValueError('Required Windows system root is missing')
env['PATH'] = os.pathsep.join((os.path.join(system, 'System32'), system))
env['QT_QPA_PLATFORM'] = 'offscreen'
env['QT_QPA_FONTDIR'] = os.path.join(system, 'Fonts')
result = subprocess.run([exe, '--candidate-smoke', '--output', output],
                        cwd=working, env=env, stdin=subprocess.DEVNULL)
raise SystemExit(result.returncode)
'''


def census(root):
    return {name: files.sha(path) for name, path in files.tree_files(root).values()}


def verify(bundle, output):
    if sys.platform != 'win32':
        raise ValueError('Actual Windows required for frozen candidate verification')
    bundle = files.plain(Path(bundle).absolute(), directory=True)
    exe = files.plain(bundle / 'BlurAction.exe')
    files.require_amd64(exe)
    output = Path(output).absolute()
    files.plain(output.parent, directory=True)
    if output.is_relative_to(bundle) or bundle.is_relative_to(output):
        raise ValueError('Verification output must be separate from the bundle')
    output.mkdir()  # exclusive: no previous result is overwritten
    working = output / 'empty-working-directory'
    working.mkdir()
    before = census(bundle)
    report = {'status': 'failed-or-incomplete', 'actualWindows': True,
              'OSInput': False, 'installerVerified': False,
              'userAcceptanceVerified': False, 'redistributionApproved': False,
              'executableSHA256': files.sha(exe)}
    report['bundleSHA256'] = hashlib.sha256(
        json.dumps(before, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    log = output / 'execution.log'
    stage = 'process-execution'
    try:
        with log.open('x', encoding='utf-8') as stream:
            code, timed_out = run_command(
                [sys.executable, '-c', WRAPPER, str(exe), str(output / 'smoke'), str(working)],
                stream, 180)
        report.update(exit=code, timedOut=timed_out)
        # Preserve a launch/child failure instead of replacing it with a missing
        # smoke-report exception. No native-success inference from exit alone.
        if code != 0 or timed_out:
            raise ValueError('Frozen smoke did not positively complete')
        stage = 'smoke-report-read'
        smoke_path = output / 'smoke/report.json'
        smoke = files.read_json(smoke_path)
        report['smokeReportSHA256'] = files.sha(smoke_path)
        stage = 'smoke-report-validation'
        required = ('actualWindows', 'frozenExecutionVerified')
        excluded = ('installerVerified', 'userAcceptanceVerified', 'redistributionApproved')
        checks = smoke.get('checks', {})
        documents = checks.get('documents', {})
        decoder = checks.get('production-decoder', {})
        if (code != 0 or timed_out or smoke.get('status') != 'pass' or
                any(smoke.get(key) is not True for key in required) or
                any(smoke.get(key) is not False for key in excluded) or
                documents.get('pages') != 3 or
                any(documents.get(key) is not True for key in
                    ('projectStateRoundtrip', 'outputPixelsChecked', 'originalsUnchanged')) or
                any(decoder.get(key) is not True for key in
                    ('productionWorkerHandshake', 'decodedFrame', 'ownedChildClosed'))):
            raise ValueError('Frozen smoke did not positively complete')
        report['status'] = 'frozen-smoke-pass'
    except Exception as error:
        # Arbitrary exception text may contain paths or environment values.
        report['failure'] = {'stage': stage, 'type': type(error).__name__[:80]}
        raise
    finally:
        report['bundleUnchanged'] = census(bundle) == before
        if not report['bundleUnchanged']:
            report['status'] = 'failed-or-incomplete'
        if log.exists():
            report['logSHA256'] = files.sha(log)
        with (output / 'execution.json').open('x', encoding='utf-8') as stream:
            json.dump(report, stream, indent=2)
    if report['status'] != 'frozen-smoke-pass':
        raise ValueError('Frozen candidate verification incomplete')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.bundle, args.output)))


if __name__ == '__main__':
    main()
