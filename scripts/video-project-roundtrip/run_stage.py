#!/usr/bin/env python3
"""Required native Mac → Windows → Mac stages with owned process-tree bounds.

Only payload/ is transferable. Logs, source snapshots and failure reports stay
inside the private .build attempt. This is not installation or release QA.
Mac builds app/tests in a fresh scratch directory under a separate 600s bound;
the linked skip-build suite and the unchanged Windows stage each retain 180s.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
from contract import ROOT, fixture_bytes, owned, packet, read, require, sha, tree, write_new
sys.path.insert(0, str(ROOT))
from scripts.verify_windows import run_command, source_inputs as windows_inputs
from scripts.verify_mac import completed_count, source_inputs as mac_inputs

SUITE = 'VideoProjectCrossPlatformRoundTripTests'
MAC_BUILD_DEADLINE = 600
STAGE_DEADLINE = 180


def run_phase(name, argv, deadline, log, report):
    """Record only after run_command has reaped/drained its private tree."""
    row = dict(phase=name, argv=argv, deadlineSeconds=deadline,
               startedAt=datetime.now(timezone.utc).isoformat(), log=log.name)
    report['phases'].append(row)
    started = time.monotonic()
    try:
        with log.open('x', encoding='utf-8') as stream:
            code, timed_out = run_command(argv, stream, deadline)
        row.update(exit=code, timedOut=timed_out, processTreeCleanupCompleted=True)
        return code, timed_out
    except BaseException as error:
        row.update(error=type(error).__name__ + ': ' + str(error), processTreeCleanupCompleted=False)
        raise
    finally:
        row.update(finishedAt=datetime.now(timezone.utc).isoformat(), elapsedSeconds=time.monotonic() - started)
        if log.exists(): row['logSHA256'] = sha(read(log))


def mac_binary_inputs(scratch):
    """Bind skip-build to the app and XCTest bundle in this fresh attempt only."""
    require(scratch.is_dir() and not scratch.is_symlink(), 'Missing owned Swift build directory')
    # SwiftPM's legacy runner and Apple's current build system name the test
    # bundle differently. Require one known product, never a guessed stale one.
    bundles = list(scratch.rglob('*.xctest'))
    require(len(bundles) == 1, 'Require exactly one freshly built XCTest bundle')
    bundle = bundles[0]
    require(bundle.name in ('BlurActionPackageTests.xctest', 'BlurActionTests.xctest'),
            'Unknown native test product')
    require(bundle.is_dir() and not bundle.is_symlink(), 'XCTest bundle must be a regular directory')
    executable = bundle / 'Contents/MacOS' / bundle.stem
    app = bundle.parent / 'BlurAction'
    paths = sorted(bundle.rglob('*')) + [app]
    require(executable.is_file() and os.access(executable, os.X_OK) and
            app.is_file() and os.access(app, os.X_OK), 'Missing executable app or XCTest binary')
    result = {}
    for path in paths:
        require(not path.is_symlink() and path.resolve().is_relative_to(scratch.resolve()),
                'Generated binary inputs must remain inside the owned build')
        if path.is_dir(): continue
        require(path.is_file(), 'Generated binary input must be a regular file')
        digest = hashlib.sha256()
        with path.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''): digest.update(chunk)
        result[path.relative_to(scratch).as_posix()] = dict(SHA256=digest.hexdigest(), bytes=path.stat().st_size)
    return result


def inputs():
    # read-only source/fixture SHA capture; no product modules are imported.
    result = windows_inputs()
    if sys.platform == 'darwin': result.update(mac_inputs())
    for path in sorted(Path(__file__).parent.iterdir()):
        if path.is_file():
            require(not path.is_symlink(), 'Harness source must not be a symlink')
            result[path.relative_to(ROOT).as_posix()] = sha(read(path))
    harness = ROOT / 'Tests/BlurActionTests/VideoProjectCrossPlatformRoundTripHarness.swift'
    result[harness.relative_to(ROOT).as_posix()] = sha(read(harness))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage', required=True, choices=('mac-emit', 'windows-edit', 'mac-verify'))
    parser.add_argument('--input', type=Path)
    parser.add_argument('--output', type=Path, help='Fresh owned attempt below .build, never overwritten')
    args = parser.parse_args()
    host = 'windows' if sys.platform == 'win32' else 'macos' if sys.platform == 'darwin' else 'unsupported'
    require(host == ('windows' if args.stage == 'windows-edit' else 'macos'), 'Required stage is on the wrong actual OS')
    require((args.input is not None) == (args.stage != 'mac-emit'), 'Required stage input is missing or unexpected')
    build = ROOT / '.build'
    require(build.is_dir() and not build.is_symlink(), 'Repository .build must exist as an owned regular directory')
    destination = (args.output or build / ('video-project-roundtrip-' + str(uuid.uuid4()))).absolute()
    require(not destination.exists() and not destination.is_symlink(), 'Attempt output already exists')
    parent = destination.parent.resolve(strict=True)
    require(parent == build.resolve() or parent.is_relative_to(build.resolve()), 'Attempt must be below repository .build')
    source = owned(args.input) if args.input else None
    if source:
        require(not destination.is_relative_to(source) and not source.is_relative_to(destination), 'Input and output must be separate owned attempts')
        packet(source, 'mac-emit' if args.stage == 'windows-edit' else 'windows-edit')
    fixture_bytes()
    destination.mkdir(mode=0o700)
    payload = destination / 'payload'; payload.mkdir(mode=0o700)
    before = inputs()
    input_before = {p.name: sha(read(p)) for p in source.iterdir()} if source else None
    report = dict(schemaVersion=1, stage=args.stage, host=host, status='running', OSInput=False, installs=False,
                  sourceInputs=before, phases=[],
                  deadlinePolicy=dict(macBuildSeconds=MAC_BUILD_DEADLINE, nativeStageSeconds=STAGE_DEADLINE),
                  limitations=['Separate required roundtrip gate; no installer, export, HDR, audio-device or generic-format completion proof.'])
    log = destination / 'stage.log'
    scratch = destination / 'swift-build'
    binary_before = None
    changed_env = {
        'BLURACTION_V3_ROUNDTRIP_STAGE': 'emit' if args.stage == 'mac-emit' else 'verify',
        'BLURACTION_V3_ROUNDTRIP_OUTPUT': str(payload),
        'BLURACTION_V3_ROUNDTRIP_OWNED_CHILD': '1',
    }
    if source: changed_env['BLURACTION_V3_ROUNDTRIP_INPUT'] = str(source)
    prior_env = {key: os.environ.get(key) for key in changed_env}
    try:
        os.environ.update(changed_env)
        if args.stage == 'windows-edit':
            child = Path(__file__).parent / 'windows_host.py'
            # run_command assigns its private Windows Job before releasing G;
            # no decoder/native imports occur before this bootstrap consumes it.
            bootstrap = "import sys,runpy; gate=sys.stdin.buffer.read(1)\nif gate!=b'G': raise SystemExit('Missing private Job release gate')\ntarget=sys.argv.pop(1); sys.argv[0]=target; runpy.run_path(target,run_name='__main__')"
            argv = [sys.executable, '-c', bootstrap, str(child), '--input', str(source), '--output', str(payload)]
        else:
            # A fresh scratch path prevents stale .build binaries from satisfying
            # --skip-build. Both phases use identical wrapper/cache/plugin flags.
            require(not scratch.exists() and not scratch.is_symlink(), 'Swift build path must be fresh')
            build_argv = ['bash', str(ROOT / 'scripts/test.sh'), '--build-only', '--scratch-path', str(scratch)]
            build_log = destination / 'build.log'
            build_exit, build_timeout = run_phase('mac-build', build_argv, MAC_BUILD_DEADLINE, build_log, report)
            report.update(buildExit=build_exit, buildTimedOut=build_timeout)
            require(build_exit == 0 and not build_timeout, 'Native test build failed or exceeded its owned process-tree deadline')
            require(len(re.findall(r'^Build complete! ', read(build_log).decode('utf-8', errors='replace'), re.MULTILINE)) == 1,
                    'Missing positive native test build completion')
            require(inputs() == before, 'Source or fixture inputs changed during native build')
            fixture_bytes()
            binary_before = mac_binary_inputs(scratch)
            report.update(buildSourceInputsPreserved=True, buildBinaryInputs=binary_before,
                          buildSourceInputsSHA256=sha(json.dumps(before, sort_keys=True).encode('utf-8')))
            argv = ['bash', str(ROOT / 'scripts/test.sh'), '--scratch-path', str(scratch), '--skip-build', '--filter', SUITE]
        exit_code, timed_out = run_phase('native-stage', argv, STAGE_DEADLINE, log, report)
        output = read(log).decode('utf-8', errors='replace')
        report.update(exit=exit_code, timedOut=timed_out, logSHA256=sha(read(log)))
        require(exit_code == 0 and not timed_out, 'Native stage failed or exceeded its owned process-tree deadline')
        if args.stage == 'windows-edit':
            require(len(re.findall(r'^Ran 1 test in ', output, re.MULTILINE)) == 1 and
                    len(re.findall(r'^OK$', output, re.MULTILINE)) == 1 and
                    'skipped=' not in output, 'Missing positive unskipped native Windows completion')
        else:
            require(completed_count(output, SUITE, exit_code) == 1, 'Missing exact positive native Swift suite completion')
        result = packet(payload, args.stage)
        if source:
            require({p.name: sha(read(p)) for p in source.iterdir()} == input_before, 'Stage modified its incoming payload')
        fixture_bytes()
        require(inputs() == before, 'Stage modified source or fixture inputs')
        report.update(status='completed', inputPreserved=True, sourceInputsPreserved=True, testCount=1, packet=result)
    except BaseException as error:
        report.update(status='failed-or-incomplete', error=type(error).__name__ + ': ' + str(error))
        raise
    finally:
        for key, value in prior_env.items():
            if value is None: os.environ.pop(key, None)
            else: os.environ[key] = value
        try:
            report['sourceInputsPreserved'] = inputs() == before
            report['inputPreserved'] = (source is None or {p.name: sha(read(p)) for p in source.iterdir()} == input_before)
            if binary_before is not None:
                report['finalBinaryInputs'] = mac_binary_inputs(scratch)
                report['buildBinaryInputsPreserved'] = report['finalBinaryInputs'] == binary_before
                if not report['buildBinaryInputsPreserved']: report['status'] = 'failed-or-incomplete'
            if not report['sourceInputsPreserved'] or not report['inputPreserved']:
                report['status'] = 'failed-or-incomplete'
            if log.exists(): report['logSHA256'] = sha(read(log))
        except Exception as error:
            report.update(status='failed-or-incomplete', preservationError=type(error).__name__ + ': ' + str(error))
        write_new(destination / 'report.json', json.dumps(report, ensure_ascii=False, sort_keys=True, indent=2).encode('utf-8'))
    require(report['status'] == 'completed' and report['sourceInputsPreserved'] and report['inputPreserved'] and
            (args.stage == 'windows-edit' or report.get('buildBinaryInputsPreserved') is True),
            'Native stage was not fully validated')
    print(json.dumps({'status': report['status'], 'stage': args.stage, 'host': host, 'testCount': 1}, sort_keys=True))


if __name__ == '__main__':
    main()
