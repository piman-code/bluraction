"""Bounded owned decode census; Windows private Job / POSIX private process group."""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import uuid

RUNNER_SHA = '312931a76abaeddc322f7a53a3802cd3fdac2f40685b1d5b53d3457720b8e276'
KINDS = ('gap0-vfr', 'nonzero-origin', 'audio-earlier-gap', 'audio-later-gap',
         'video0-audio-negative-quarter', 'video-negative-twelfth-audio0',
         'video-negative-twelfth-audio-negative-quarter', 'video-negative-twelfth-noaudio')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repository', type=Path, required=True)
    args = parser.parse_args()
    repo = args.repository.resolve(strict=True)
    if repo != Path(__file__).resolve().parents[2]:
        raise ValueError('This reviewed repository only')
    runner = repo / 'scripts/verify_windows.py'
    observer = Path(__file__).resolve().with_name('observe_video.py')
    manifest = repo / 'shared/fixtures/video-timelines/manifest.json'
    source_paths = [runner, observer, Path(__file__).resolve(), observer.with_name('README.md'), manifest,
        repo / 'platforms/windows/bluraction/local_decoder.py',
        repo / 'platforms/windows/bluraction/frame_inventory.py', repo / 'shared/source_identity.py',
        repo / 'shared/video_timeline.py', repo / 'platforms/windows/bluraction/video.py',
        repo / 'platforms/windows/bluraction/canonical_video.py',
        repo / 'Tests/WindowsAppTests/test_canonical_video_fixtures.py']
    source_paths += [repo / 'shared/fixtures/video-timelines' / (kind + '.mov') for kind in KINDS]
    def snapshot():
        result = {}
        for path in source_paths:
            if path.is_symlink() or not path.is_file():
                raise ValueError('Plain reviewed diagnostic inputs required')
            digest = hashlib.sha256()
            with path.open('rb') as stream:
                while block := stream.read(65536): digest.update(block)
            result[path.relative_to(repo).as_posix()] = digest.hexdigest()
        return result
    before = snapshot()
    if before['scripts/verify_windows.py'] != RUNNER_SHA:
        raise ValueError('Private process-tree runner changed; review before execution')
    spec = importlib.util.spec_from_file_location('owned_video_diagnostic_runner', runner)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    build = repo / '.build'
    build.mkdir(mode=0o700, exist_ok=True)
    if build.is_symlink() or build.resolve(strict=True) != build:
        raise ValueError('Plain owned build parent required')
    directory = build / ('video-decoder-diagnostic-' + str(uuid.uuid4()))
    directory.mkdir(mode=0o700, exist_ok=False)
    output = directory / 'observations'
    bootstrap = "import sys,subprocess\nif sys.stdin.buffer.read(1)!=b'G': raise SystemExit(125)\nraise SystemExit(subprocess.call(sys.argv[1:]))\n"
    argv = [sys.executable, '-c', bootstrap, sys.executable, str(observer),
            '--repository', str(repo), '--output-directory', str(output)]
    row = {'actualHost': sys.platform, 'actualWindows': os.name == 'nt',
           'ownership': 'private-Windows-Job' if os.name == 'nt' else 'private-POSIX-process-group',
           'deadlineSeconds': 60, 'status': 'failed-or-incomplete', 'fullGoalComplete': False}
    status = 1
    try:
        with (directory / 'child.log').open('xb') as stream:
            code, timed_out = module.run_command(argv, stream, 60)
        row.update(exitCode=code, timedOut=timed_out,
                   logSHA256=hashlib.sha256((directory / 'child.log').read_bytes()).hexdigest())
        report_path = output / 'report.json'
        if report_path.is_file():
            report = json.loads(report_path.read_text(encoding='utf-8'))
            row['childReportSHA256'] = hashlib.sha256(report_path.read_bytes()).hexdigest()
            if (code == 0 and not timed_out and report.get('status') == 'observations-complete-not-product-pass'
                    and report.get('sourcesPreserved') is True and report.get('actualHost') == sys.platform
                    and len(report.get('cases', [])) == 8
                    and all(c.get('completeEOF') is True and c.get('nativeCloseCompleted') is True
                            and c.get('sourcePreserved') is True for c in report['cases'])):
                status = 0
    except BaseException as error:
        row['errorType'] = type(error).__name__
    finally:
        try:
            after = snapshot()
            row.update(sourceBefore=before, sourceAfter=after, sourcesPreserved=before == after)
            if before != after: status = 1
        except BaseException as error:
            row.update(sourcesPreserved=False, sourceCheckErrorType=type(error).__name__)
            status = 1
        row['status'] = 'observations-complete-not-product-pass' if status == 0 else 'failed-or-incomplete'
        with (directory / 'report.json').open('x', encoding='utf-8') as stream:
            json.dump(row, stream, ensure_ascii=False, sort_keys=True, indent=2)
            stream.write('\n')
    print(json.dumps({'report': str(directory / 'report.json'), 'status': row['status']}))
    return status


if __name__ == '__main__':
    raise SystemExit(main())
