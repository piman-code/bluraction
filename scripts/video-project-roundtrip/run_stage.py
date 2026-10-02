#!/usr/bin/env python3
"""Required native Mac → Windows → Mac stages with owned process-tree bounds.

Only payload/ is transferable. Logs, source snapshots and failure reports stay
inside the private .build attempt. This is not installation or release QA.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import sys
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
from contract import ROOT, fixture_bytes, owned, packet, read, require, sha, tree, write_new
sys.path.insert(0, str(ROOT))
from scripts.verify_windows import run_command, source_inputs as windows_inputs
from scripts.verify_mac import completed_count, source_inputs as mac_inputs

SUITE = 'VideoProjectCrossPlatformRoundTripTests'


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
                  sourceInputs=before, limitations=['Separate required roundtrip gate; no installer, export, HDR, audio-device or generic-format completion proof.'])
    log = destination / 'stage.log'
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
            argv = ['bash', str(ROOT / 'scripts/test.sh'), '--filter', SUITE]
        with log.open('x', encoding='utf-8') as stream:
            exit_code, timed_out = run_command(argv, stream, 180)
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
            if not report['sourceInputsPreserved'] or not report['inputPreserved']:
                report['status'] = 'failed-or-incomplete'
            if log.exists(): report['logSHA256'] = sha(read(log))
        except Exception as error:
            report.update(status='failed-or-incomplete', preservationError=type(error).__name__ + ': ' + str(error))
        write_new(destination / 'report.json', json.dumps(report, ensure_ascii=False, sort_keys=True, indent=2).encode('utf-8'))
    require(report['status'] == 'completed' and report['sourceInputsPreserved'] and report['inputPreserved'], 'Native stage was not fully validated')
    print(json.dumps({'status': report['status'], 'stage': args.stage, 'host': host, 'testCount': 1}, sort_keys=True))


if __name__ == '__main__':
    main()
