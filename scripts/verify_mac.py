#!/usr/bin/env python3
"""Run native Swift suites separately; exit zero without a summary is failure.

No install, app launch or OS input automation. Artifacts stay in .build by
default. A failed, timed out or incomplete suite retains its log and report.
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
import uuid

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def completed_count(output, suite, exit_code):
    # Swift Testing102 has no suite count in its final summary. It still must
    # finish exactly the selected suite and the complete positive test run.
    finals = re.findall(r'Test run with (\d+) tests?(?: in (\d+) suites?)? passed after', output)
    suite_ends = re.findall(r'Suite ([^\n]+?) passed after', output)
    if exit_code != 0 or len(finals) != 1 or suite_ends != [suite]:
        return None
    count, suite_count = finals[0]
    if suite_count:
        return int(count) if int(count) > 0 and int(suite_count) == 1 else None
    suite_starts = re.findall(r'Suite ([^\n]+?) started\.', output)
    return int(count) if int(count) > 0 and suite_starts == [suite] else None


def source_inputs():
    paths = [ROOT / '.gitattributes', ROOT / 'Package.swift', ROOT / 'Resources/Info.plist',
             ROOT / 'scripts/test.sh', Path(__file__).resolve()]
    paths += sorted((ROOT / 'Sources/BlurAction').glob('*.swift'))
    paths += sorted(path for path in (ROOT / 'Sources/BlurActionMediaSafety').rglob('*') if path.is_file())
    paths += sorted((ROOT / 'Tests/BlurActionTests').glob('*.swift'))
    return {path.relative_to(ROOT).as_posix(): sha(path) for path in paths}


def native_suites():
    result = []
    for path in sorted((ROOT / 'Tests/BlurActionTests').glob('*Tests.swift')):
        # Existing top-level Swift Testing suite declarations. Unknown or
        # ambiguous new structure must be reviewed instead of silently skipped.
        found = re.findall(r'^(?:final\s+)?(?:class|struct)\s+(\w+Tests)\s*\{',
                           path.read_text(encoding='utf-8'), re.MULTILINE)
        if len(found) != 1:
            raise ValueError(f'Cannot establish exactly one suite for {path.name}')
        result += found
    if not result or len(result) != len(set(result)):
        raise ValueError('No suites or duplicate suite declarations')
    return result


def run_native_command(command, log, timeout):
    """Own a Unix process group so timeout stops Swift and its test children."""
    child = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                             start_new_session=True,
                             env=dict(os.environ, CLANG_MODULE_CACHE_PATH=str(ROOT / '.build/clang-cache')))
    try:
        return child.wait(timeout=timeout), False
    except subprocess.TimeoutExpired:
        # Kill the entire private group before reaping its leader or hashing
        # logs; terminating only bash leaves swift/test grandchildren running.
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait()
        return None, True


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--suite', action='append', help='Exact suite; repeat to select several')
    parser.add_argument('--timeout', type=float, default=300, help='Seconds per child process')
    parser.add_argument('--output', type=Path, help='New directory; must not exist')
    options = parser.parse_args(argv)
    known = native_suites()
    suites = options.suite or known
    if (not math.isfinite(options.timeout) or options.timeout <= 0 or options.timeout > 3600 or
            len(suites) != len(set(suites)) or any(s not in known for s in suites)):
        parser.error('Require unique existing suites and timeout in (0, 3600]')
    destination = options.output or ROOT / '.build' / ('mac-verification-' + str(uuid.uuid4()))
    destination = destination.absolute()
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.mkdir()  # Exclusive: preserve every prior result.
    before = source_inputs()
    report = {'status': 'running', 'syntheticOnly': True, 'OSInput': False,
              'requestedSuites': suites, 'inputs': before, 'suites': [],
              'limitations': ['Native API tests; not Finder/panels/install/user acceptance.']}
    for suite in suites:
        path = destination / (suite + '.log')
        with path.open('w') as log:
            exit_code, timed_out = run_native_command(
                ['bash', str(ROOT / 'scripts/test.sh'), '--filter', suite], log, options.timeout)
        count = completed_count(path.read_text(encoding='utf-8', errors='replace'), suite, exit_code)
        row = {'suite': suite, 'exit': exit_code, 'timedOut': timed_out,
               'status': 'pass' if count is not None else 'failed-or-incomplete',
               'testCount': count or 0, 'log': str(path), 'logSHA256': sha(path)}
        report['suites'].append(row)
        print(json.dumps(row), flush=True)
        if count is None:
            break
    report['inputsUnchanged'] = source_inputs() == before
    report['testCount'] = sum(row['testCount'] for row in report['suites'])
    passed = (report['inputsUnchanged'] and len(report['suites']) == len(suites) and
              all(row['status'] == 'pass' for row in report['suites']))
    report['status'] = 'source-linked-regression-pass' if passed else 'failed-or-incomplete'
    target = destination / 'report.json'
    target.write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(target, flush=True)
    return 0 if passed else 1


if __name__ == '__main__':
    sys.exit(main())
