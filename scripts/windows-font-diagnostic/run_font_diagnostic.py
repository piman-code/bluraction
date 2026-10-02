"""Unexecuted QA: new Windows-only no-window QPA children with private Job deadlines."""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--repository', type=Path, required=True)
parser.add_argument('--timeout', type=int, default=30, choices=range(5, 91))
args = parser.parse_args()
if sys.platform != 'win32': raise SystemExit('Actual Windows required')
repo = args.repository.resolve()
runner = repo / 'scripts/verify_windows.py'
expected = '312931a76abaeddc322f7a53a3802cd3fdac2f40685b1d5b53d3457720b8e276'
if hashlib.sha256(runner.read_bytes()).hexdigest() != expected:
    raise SystemExit('Private process-tree runner changed; review before execution')
spec = importlib.util.spec_from_file_location('owned_font_runner', runner)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
source = Path(__file__).resolve().with_name('observe_fonts.py')
source.relative_to(repo)
if source.is_symlink(): raise SystemExit('Plain reviewed diagnostic source required')
build = repo / '.build'
build.mkdir(exist_ok=True)
if build.is_symlink() or build.resolve() != build:
    raise SystemExit('Plain repository build parent required')
directory = build / ('windows-font-diagnostic-' + str(uuid.uuid4()))
directory.mkdir(parents=False, exist_ok=False)
baseline = {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in (source, Path(__file__).resolve(), runner,
                repo/'platforms/windows/bluraction/renderer.py', repo/'platforms/windows/bluraction/ui.py',
                repo/'Tests/WindowsAppTests/test_ui.py')}
rows = []
status = 0
for platform in ('offscreen', 'offscreen-system-fonts'):
    output, log = directory/(platform+'.json'), directory/(platform+'.log')
    bootstrap = "import sys,subprocess\nif sys.stdin.buffer.read(1)!=b'G': raise SystemExit(125)\nraise SystemExit(subprocess.call(sys.argv[1:]))\n"
    argv = [sys.executable, '-c', bootstrap, sys.executable, str(source),
            '--repository', str(repo), '--output', str(output), '--platform', platform]
    entry = {'platform': platform, 'timeoutSeconds': args.timeout}
    try:
        with log.open('xb') as stream:
            exit_code, timed_out = module.run_command(argv, stream, args.timeout)
        entry.update(exitCode=exit_code, timedOut=timed_out,
                     logSHA256=hashlib.sha256(log.read_bytes()).hexdigest())
        if output.is_file():
            report = json.loads(output.read_text(encoding='utf-8'))
            entry.update(reportSHA256=hashlib.sha256(output.read_bytes()).hexdigest(),
                         status=report.get('status'), sourcesPreserved=report.get('sourcesPreserved'))
            if (report.get('status') != 'observations-complete-not-product-pass' or
                    report.get('sourcesPreserved') is not True or report.get('actualPlatform') != ('offscreen' if platform == 'offscreen-system-fonts' else platform)):
                status = 1
        else: status = 1; entry['status'] = 'missing-complete-report'
        if exit_code != 0 or timed_out: status = 1
    except BaseException as error:
        entry.update(status='failed-or-incomplete', errorType=type(error).__name__, error=str(error)); status = 1
    rows.append(entry)
after = {path: hashlib.sha256((repo/path).read_bytes()).hexdigest() for path in baseline}
if baseline != after: status = 1
report = {'status': 'observations-complete' if status == 0 else 'failed-or-incomplete',
          'actualWindows': True, 'OSInput': False, 'windowShown': False,
          'children': rows, 'sourceBefore': baseline, 'sourceAfter': after,
          'sourcesPreserved': baseline == after, 'fontDefectClosed': False, 'fullGoalComplete': False}
with (directory/'report.json').open('x', encoding='utf-8') as stream:
    json.dump(report, stream, ensure_ascii=False, sort_keys=True, indent=2); stream.write('\n')
print(json.dumps({'report': str(directory/'report.json'), 'status': report['status']}, sort_keys=True))
raise SystemExit(status)
